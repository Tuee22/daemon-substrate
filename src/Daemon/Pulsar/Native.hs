{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module Daemon.Pulsar.Native
  ( NativePulsar (..),
    NativePulsarT (..),
    runNativePulsarT,
    module Daemon.Pulsar.Native.Connection,
    module Daemon.Pulsar.Native.Consumer,
    module Daemon.Pulsar.Native.Frame,
    module Daemon.Pulsar.Native.Lookup,
    module Daemon.Pulsar.Native.Producer,
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar, swapMVar)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime)
import Data.Word (Word64)
import Daemon.Pulsar
import Daemon.Pulsar.Native.Connection
import Daemon.Pulsar.Native.Consumer
import Daemon.Pulsar.Native.Frame
import Daemon.Pulsar.Native.Lookup
import Daemon.Pulsar.Native.Producer
import qualified Daemon.Proto.PulsarApi as Api
import Lens.Family2 ((^.))
import qualified Network.Socket as Socket
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Process (getProcessID)

data NativePulsar = NativePulsar
  { nativePulsarServiceUrl :: Text,
    nativePulsarOperationTimeoutMicros :: Int
  }
  deriving stock (Eq, Show)

newtype NativePulsarT m a = NativePulsarT
  {unNativePulsarT :: ReaderT NativePulsar m a}
  deriving newtype (Functor, Applicative, Monad, MonadIO)

runNativePulsarT :: NativePulsar -> NativePulsarT m a -> m a
runNativePulsarT config action = runReaderT (unNativePulsarT action) config

type NativeSessionKey = (Text, Int, Subscription)

data NativeConsumerSession = NativeConsumerSession
  { nativeConsumerSessionConnection :: !NativeConnection,
    nativeConsumerSessionConsumerId :: !ConsumerId,
    nativeConsumerSessionActive :: !(MVar (Maybe Bool))
  }

{-# NOINLINE nativeConsumerSessions #-}
nativeConsumerSessions :: MVar (Map.Map NativeSessionKey NativeConsumerSession)
nativeConsumerSessions =
  unsafePerformIO (newMVar Map.empty)

instance (MonadIO m) => HasPulsar (NativePulsarT m) where
  pulsarPublish topic message =
    runNativeTopicOperation topic \connection -> do
      let producerId = ProducerId 1
          requestId = 1
          sequenceId = 1
      bindNative (establishProducer connection topic producerId requestId) \() -> do
        publishTime <- currentTimeMillis
        let metadata =
              messageMetadata
                "daemon-substrate-native"
                sequenceId
                publishTime
                message
            payload =
              encodePulsarPayload
                PulsarPayload
                  { pulsarPayloadMetadata = metadata,
                    pulsarPayloadBytes = producerPayload message
                  }
        bindNative (writeNative connection (sendCommand producerId sequenceId) (Just payload)) \() -> do
          bindNative (expectNative connection [Api.BaseCommand'SEND_RECEIPT, Api.BaseCommand'SEND_ERROR]) \response ->
            case pulsarFrameCommand response ^. Api.type' of
              Api.BaseCommand'SEND_RECEIPT -> do
                let receipt = pulsarFrameCommand response ^. Api.sendReceipt
                pure (Right (messageIdFromData (receipt ^. Api.messageId)))
              Api.BaseCommand'SEND_ERROR -> do
                let sendError = pulsarFrameCommand response ^. Api.sendError
                failNative (sendError ^. Api.message)
              other ->
                failNative ("unexpected publish response: " <> Text.pack (show other))

  pulsarSubscribe topic name mode =
    let subscription = Subscription topic name mode
     in runNativeConsumerOperation subscription \_session ->
          pure (Right subscription)

  pulsarWaitActive subscription
    | subscriptionMode subscription /= Failover =
        pure (Right True)
    | otherwise = do
        config <- NativePulsarT ask
        result <- liftIO (withNativeConsumerSession config subscription waitForConsumerActive)
        pure case result of
          Left err -> Left (nativeErrorToPulsar err)
          Right active -> Right active

  pulsarConsume subscription =
    runNativeConsumerConsumeOperation subscription \session -> do
      let connection = nativeConsumerSessionConnection session
          consumerId = nativeConsumerSessionConsumerId session
      bindNative (writeNative connection (flowCommand consumerId 1) Nothing) \() ->
        bindNative (expectConsumerNative session [Api.BaseCommand'MESSAGE]) \response -> do
          let commandMessage = pulsarFrameCommand response ^. Api.message
              payloadBytes = fromMaybe mempty (pulsarFramePayload response)
          case decodePulsarPayload payloadBytes of
            Left err -> failNative ("failed to decode Pulsar message payload: " <> Text.pack (show err))
            Right payload ->
              pure
                ( Right
                    PulsarMessage
                      { pulsarMessageTopic = subscriptionTopic subscription,
                        pulsarMessageId = messageIdFromData (commandMessage ^. Api.messageId),
                        pulsarMessageKey = payloadPartitionKey (pulsarPayloadMetadata payload),
                        pulsarMessagePayload = pulsarPayloadBytes payload,
                        pulsarMessageProperties = payloadProperties (pulsarPayloadMetadata payload),
                        pulsarMessagePublishedAt = millisToUTCTime (pulsarPayloadMetadata payload ^. Api.publishTime)
                      }
                )

  pulsarAcknowledge subscription messageId =
    runNativeConsumerOperation subscription \session -> do
      let connection = nativeConsumerSessionConnection session
          consumerId = nativeConsumerSessionConsumerId session
      writeNative connection (ackCommand consumerId messageId) Nothing

  pulsarNegativeAcknowledge subscription messageId =
    runNativeConsumerOperation subscription \session -> do
      let connection = nativeConsumerSessionConnection session
          consumerId = nativeConsumerSessionConsumerId session
      writeNative connection (redeliverCommand consumerId [messageId]) Nothing

  pulsarSeek subscription target =
    do
      config <- NativePulsarT ask
      result <-
        liftIO
          ( withNativeConsumerSession config subscription \session -> do
              let connection = nativeConsumerSessionConnection session
                  consumerId = nativeConsumerSessionConsumerId session
              command <-
                case target of
                  SeekEarliest -> pure (seekPublishTimeCommand consumerId 2 0)
                  SeekLatest -> seekPublishTimeCommand consumerId 2 <$> currentTimeMillis
                  SeekMessageId messageId -> pure (seekMessageIdCommand consumerId 2 messageId)
              written <- writeNative connection command Nothing
              case written of
                Left err -> pure (Left err)
                Right () -> do
                  response <- expectConsumerNative session [Api.BaseCommand'SUCCESS]
                  case response of
                    Left NativeConnectionClosed -> do
                      invalidateConsumerSession config subscription
                      pure (Right ())
                    Left err -> pure (Left err)
                    Right _ -> pure (Right ())
          )
      pure case result of
        Left err -> Left (nativeErrorToPulsar err)
        Right value -> Right value

runNativeConsumerOperation ::
  (MonadIO m) =>
  Subscription ->
  (NativeConsumerSession -> IO (Either NativeConnectionError a)) ->
  NativePulsarT m (Either PulsarError a)
runNativeConsumerOperation subscription action = do
  config <- NativePulsarT ask
  result <- liftIO (withNativeConsumerSession config subscription action)
  pure case result of
    Left err -> Left (nativeErrorToPulsar err)
    Right value -> Right value

runNativeConsumerConsumeOperation ::
  (MonadIO m) =>
  Subscription ->
  (NativeConsumerSession -> IO (Either NativeConnectionError PulsarMessage)) ->
  NativePulsarT m (Either PulsarError (Maybe PulsarMessage))
runNativeConsumerConsumeOperation subscription action = do
  config <- NativePulsarT ask
  result <- liftIO (withNativeConsumerSession config subscription action)
  pure case result of
    Left (NativeOperationTimedOut _) -> Right Nothing
    Left (NativeSocketUnavailable "<<timeout>>") -> Right Nothing
    Left err -> Left (nativeErrorToPulsar err)
    Right message -> Right (Just message)

withNativeConsumerSession ::
  NativePulsar ->
  Subscription ->
  (NativeConsumerSession -> IO (Either NativeConnectionError a)) ->
  IO (Either NativeConnectionError a)
withNativeConsumerSession config subscription action = do
  sessionResult <- getOrCreateConsumerSession config subscription
  case sessionResult of
    Left err -> pure (Left err)
    Right session -> do
      result <- action session
      case result of
        Left err
          | invalidatesConsumerSession err -> do
              invalidateConsumerSession config subscription
              pure (Left err)
        _ -> pure result

getOrCreateConsumerSession ::
  NativePulsar ->
  Subscription ->
  IO (Either NativeConnectionError NativeConsumerSession)
getOrCreateConsumerSession config subscription =
  modifyMVar nativeConsumerSessions \sessions ->
    case Map.lookup key sessions of
      Just session ->
        pure (sessions, Right session)
      Nothing -> do
        created <- createConsumerSession config subscription
        pure case created of
          Left err -> (sessions, Left err)
          Right session -> (Map.insert key session sessions, Right session)
  where
    key = nativeSessionKey config subscription

createConsumerSession ::
  NativePulsar ->
  Subscription ->
  IO (Either NativeConnectionError NativeConsumerSession)
createConsumerSession config subscription = do
  owner <- resolveNativeOwner config (subscriptionTopic subscription)
  case owner of
    Left err -> pure (Left err)
    Right broker -> do
      opened <- openSocket broker
      case opened of
        Left err -> pure (Left err)
        Right socket -> do
          let connection =
                NativeConnection
                  { nativeConnectionAddress = broker,
                    nativeConnectionSocket = socket,
                    nativeConnectionTimeoutMicros = nativePulsarOperationTimeoutMicros config
                  }
              consumerId = ConsumerId 1
          connected <- connectHandshake connection nativeClientVersion
          case connected of
            Left err -> closeWithError socket err
            Right () -> do
              active <- newMVar Nothing
              let session =
                    NativeConsumerSession
                      { nativeConsumerSessionConnection = connection,
                        nativeConsumerSessionConsumerId = consumerId,
                        nativeConsumerSessionActive = active
                      }
              consumerName <- nativeConsumerName subscription consumerId
              subscribed <- establishSubscription connection subscription consumerId consumerName 1
              case subscribed of
                Left err -> closeWithError socket err
                Right () -> pure (Right session)

resolveNativeOwner ::
  NativePulsar ->
  TopicName ->
  IO (Either NativeConnectionError BrokerAddress)
resolveNativeOwner config topic =
  withNativeConnection
    (nativePulsarServiceUrl config)
    (nativePulsarOperationTimeoutMicros config)
    \bootstrapConnection ->
      bindNative (connectHandshake bootstrapConnection nativeClientVersion) \() ->
        lookupNativeOwner bootstrapConnection topic

invalidateConsumerSession :: NativePulsar -> Subscription -> IO ()
invalidateConsumerSession config subscription =
  modifyMVar_ nativeConsumerSessions \sessions -> do
    case Map.lookup key sessions of
      Nothing -> pure ()
      Just session -> Socket.close (nativeConnectionSocket (nativeConsumerSessionConnection session))
    pure (Map.delete key sessions)
  where
    key = nativeSessionKey config subscription

nativeSessionKey :: NativePulsar -> Subscription -> NativeSessionKey
nativeSessionKey config subscription =
  (nativePulsarServiceUrl config, nativePulsarOperationTimeoutMicros config, subscription)

invalidatesConsumerSession :: NativeConnectionError -> Bool
invalidatesConsumerSession err =
  case err of
    NativeConnectionClosed -> True
    NativeSocketUnavailable _ -> True
    _ -> False

closeWithError :: Socket.Socket -> NativeConnectionError -> IO (Either NativeConnectionError a)
closeWithError socket err = do
  Socket.close socket
  pure (Left err)

waitForConsumerActive :: NativeConsumerSession -> IO (Either NativeConnectionError Bool)
waitForConsumerActive session = do
  frame <- expectConsumerNative session [Api.BaseCommand'ACTIVE_CONSUMER_CHANGE]
  case frame of
    Left err
      | nativeLeadershipPollTimedOut err -> do
          active <- readMVar (nativeConsumerSessionActive session)
          pure (Right (active == Just True))
    Left err -> pure (Left err)
    Right decoded -> pure (Right (activeConsumerFrameIsActive session decoded))

nativeLeadershipPollTimedOut :: NativeConnectionError -> Bool
nativeLeadershipPollTimedOut err =
  case err of
    NativeOperationTimedOut _ -> True
    NativeSocketUnavailable "<<timeout>>" -> True
    _ -> False

expectConsumerNative :: NativeConsumerSession -> [Api.BaseCommand'Type] -> IO (Either NativeConnectionError PulsarFrame)
expectConsumerNative session expected = loop
  where
    connection = nativeConsumerSessionConnection session
    loop = do
      frame <- readFrame connection
      case frame of
        Left err -> pure (Left err)
        Right decoded ->
          case commandType decoded of
            Api.BaseCommand'PING -> do
              pongWritten <- writeCommand connection pongCommand Nothing
              case pongWritten of
                Left err -> pure (Left err)
                Right () -> loop
            Api.BaseCommand'ERROR ->
              pure (Left (NativeBrokerError (brokerErrorMessage (pulsarFrameCommand decoded))))
            Api.BaseCommand'ACTIVE_CONSUMER_CHANGE -> do
              matches <- recordActiveConsumerChange session decoded
              if matches && Api.BaseCommand'ACTIVE_CONSUMER_CHANGE `elem` expected
                then pure (Right decoded)
                else loop
            Api.BaseCommand'CLOSE_CONSUMER ->
              if closeConsumerMatches session decoded
                then pure (Left NativeConnectionClosed)
                else loop
            actual
              | actual `elem` expected -> pure (Right decoded)
              | otherwise -> pure (Left (NativeUnexpectedCommand actual))

recordActiveConsumerChange :: NativeConsumerSession -> PulsarFrame -> IO Bool
recordActiveConsumerChange session frame = do
  let change = pulsarFrameCommand frame ^. Api.activeConsumerChange
      matches = change ^. Api.consumerId == consumerIdWord (nativeConsumerSessionConsumerId session)
      active = change ^. Api.isActive
  if matches
    then do
      _ <- swapMVar (nativeConsumerSessionActive session) (Just active)
      pure True
    else pure False

activeConsumerFrameIsActive :: NativeConsumerSession -> PulsarFrame -> Bool
activeConsumerFrameIsActive session frame =
  let change = pulsarFrameCommand frame ^. Api.activeConsumerChange
   in change ^. Api.consumerId == consumerIdWord (nativeConsumerSessionConsumerId session)
        && change ^. Api.isActive

closeConsumerMatches :: NativeConsumerSession -> PulsarFrame -> Bool
closeConsumerMatches session frame =
  let close = pulsarFrameCommand frame ^. Api.closeConsumer
   in close ^. Api.consumerId == consumerIdWord (nativeConsumerSessionConsumerId session)

runNativeTopicOperation ::
  (MonadIO m) =>
  TopicName ->
  (NativeConnection -> IO (Either NativeConnectionError a)) ->
  NativePulsarT m (Either PulsarError a)
runNativeTopicOperation topic action = do
  config <- NativePulsarT ask
  let timeoutMicros = nativePulsarOperationTimeoutMicros config
  result <-
    liftIO
      ( withNativeConnection
          (nativePulsarServiceUrl config)
          timeoutMicros
          \bootstrapConnection -> do
            connected <- connectHandshake bootstrapConnection nativeClientVersion
            case connected of
              Left err -> pure (Left err)
              Right () -> do
                owner <- lookupNativeOwner bootstrapConnection topic
                case owner of
                  Left err -> pure (Left err)
                  Right broker
                    | broker == nativeConnectionAddress bootstrapConnection ->
                        action bootstrapConnection
                    | otherwise ->
                        withNativeBrokerAddress broker timeoutMicros \ownerConnection -> do
                          ownerConnected <- connectHandshake ownerConnection nativeClientVersion
                          case ownerConnected of
                            Left err -> pure (Left err)
                            Right () -> action ownerConnection
      )
  pure case result of
    Left err -> Left (nativeErrorToPulsar err)
    Right value -> Right value

establishProducer :: NativeConnection -> TopicName -> ProducerId -> Word64 -> IO (Either NativeConnectionError ())
establishProducer connection topic producerId requestId = do
  written <- writeCommand connection (producerCommand topic producerId requestId) Nothing
  case written of
    Left err -> pure (Left err)
    Right () -> do
      response <- awaitCommand connection [Api.BaseCommand'PRODUCER_SUCCESS]
      pure (() <$ response)

establishSubscription :: NativeConnection -> Subscription -> ConsumerId -> Text -> Word64 -> IO (Either NativeConnectionError ())
establishSubscription connection subscription consumerId consumerName requestId = do
  written <- writeCommand connection (subscribeCommand subscription consumerId consumerName requestId) Nothing
  case written of
    Left err -> pure (Left err)
    Right () -> do
      response <- awaitCommand connection [Api.BaseCommand'SUCCESS]
      pure (() <$ response)

nativeConsumerName :: Subscription -> ConsumerId -> IO Text
nativeConsumerName subscription consumerId = do
  host <- fmap Text.pack <$> lookupEnv "HOSTNAME"
  pid <- getProcessID
  millis <- currentTimeMillis
  pure
    ( Text.intercalate
        "-"
        [ "daemon-substrate-native",
          sanitizeConsumerName (unSubscriptionName (subscriptionName subscription)),
          sanitizeConsumerName (fromMaybe "unknown-host" host),
          Text.pack (show pid),
          Text.pack (show (consumerIdWord consumerId)),
          Text.pack (show millis)
        ]
    )
  where
    sanitizeConsumerName =
      Text.map \character ->
        if character == '/' || character == ':' || character == ' '
          then '-'
          else character

lookupNativeOwner :: NativeConnection -> TopicName -> IO (Either NativeConnectionError BrokerAddress)
lookupNativeOwner connection topic =
  bindNative (writeCommand connection (lookupCommand topic 99 False) Nothing) \() ->
    bindNative (awaitCommand connection [Api.BaseCommand'LOOKUP_RESPONSE]) \response -> do
      let lookupResponse = pulsarFrameCommand response ^. Api.lookupTopicResponse
          lookupType = lookupResponse ^. Api.response
      case lookupType of
        Api.CommandLookupTopicResponse'Failed ->
          failNative
            ( fromMaybe
                "Pulsar topic lookup failed"
                (lookupResponse ^. Api.maybe'message)
            )
        Api.CommandLookupTopicResponse'Connect ->
          parseLookupBroker connection lookupResponse
        Api.CommandLookupTopicResponse'Redirect ->
          parseLookupBroker connection lookupResponse

writeNative :: NativeConnection -> Api.BaseCommand -> Maybe ByteString -> IO (Either NativeConnectionError ())
writeNative = writeCommand

expectNative :: NativeConnection -> [Api.BaseCommand'Type] -> IO (Either NativeConnectionError PulsarFrame)
expectNative = awaitCommand

failNative :: Text -> IO (Either NativeConnectionError a)
failNative = pure . Left . NativeBrokerError

parseLookupBroker :: NativeConnection -> Api.CommandLookupTopicResponse -> IO (Either NativeConnectionError BrokerAddress)
parseLookupBroker connection lookupResponse =
  if loopbackBrokerAddress (nativeConnectionAddress connection)
    then pure (Right (nativeConnectionAddress connection))
    else
      case lookupResponse ^. Api.maybe'brokerServiceUrl of
        Nothing -> pure (Right (nativeConnectionAddress connection))
        Just serviceUrl ->
          pure case parseBrokerAddress serviceUrl of
            Left err -> Left (NativeInvalidServiceUrl err)
            Right broker -> Right broker

loopbackBrokerAddress :: BrokerAddress -> Bool
loopbackBrokerAddress address =
  brokerHost address `elem` ["localhost", "127.0.0.1", "::1"]

bindNative ::
  IO (Either NativeConnectionError a) ->
  (a -> IO (Either NativeConnectionError b)) ->
  IO (Either NativeConnectionError b)
bindNative action next = do
  result <- action
  case result of
    Left err -> pure (Left err)
    Right value -> next value

nativeUnavailableReason :: Text -> Text
nativeUnavailableReason "<<timeout>>" = "native-timeout: socket operation"
nativeUnavailableReason msg = "native socket unavailable: " <> msg

nativeErrorToPulsar :: NativeConnectionError -> PulsarError
nativeErrorToPulsar err =
  PulsarBackendUnavailable case err of
    NativeInvalidServiceUrl msg -> "invalid Pulsar service URL: " <> msg
    NativeSocketUnavailable msg -> nativeUnavailableReason msg
    NativeOperationTimedOut label -> "native-timeout: " <> label
    NativeConnectionClosed -> "native Pulsar connection closed"
    NativeFrameError frameErr -> "native Pulsar frame error: " <> Text.pack (show frameErr)
    NativeUnexpectedCommand command -> "native Pulsar unexpected command: " <> Text.pack (show command)
    NativeBrokerError msg -> "native Pulsar broker error: " <> msg

payloadPartitionKey :: Api.MessageMetadata -> Maybe Text
payloadPartitionKey metadata = metadata ^. Api.maybe'partitionKey

payloadProperties :: Api.MessageMetadata -> Map.Map Text Text
payloadProperties metadata =
  Map.fromList
    [ (entry ^. Api.key, entry ^. Api.value)
      | entry <- metadata ^. Api.properties
    ]

currentTimeMillis :: IO Word64
currentTimeMillis = floor . (* 1000) <$> getPOSIXTime

millisToUTCTime :: Word64 -> UTCTime
millisToUTCTime millis =
  posixSecondsToUTCTime (fromIntegral millis / 1000)

nativeClientVersion :: Text
nativeClientVersion = "daemon-substrate-native/0.1"
