{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module Daemon.Test.FilesystemPulsar where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import Data.Foldable (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Daemon.Pulsar
import Daemon.Pulsar.Admin

newtype FilesystemPulsar a = FilesystemPulsar
  {unFilesystemPulsar :: ReaderT FilesystemPulsarHandle IO a}
  deriving newtype (Functor, Applicative, Monad, MonadFail, MonadIO)

newtype FilesystemPulsarHandle = FilesystemPulsarHandle
  {filesystemPulsarState :: TVar Ledger}

data Ledger = Ledger
  { ledgerTopics :: Map TopicName [PulsarMessage],
    ledgerSubscriptions :: Map SubscriptionKey SubscriptionState,
    ledgerDedup :: Map TopicName (Map Text MessageId),
    ledgerTopicConfigs :: Map TopicName TopicConfig,
    ledgerTerminatedTopics :: Set TopicName,
    ledgerTopicExports :: Map TopicName Text
  }

type SubscriptionKey = (TopicName, SubscriptionName)

data SubscriptionState = SubscriptionState
  { subscriptionStateMode :: SubscriptionMode,
    subscriptionCursor :: Int,
    subscriptionAcknowledged :: Set MessageId,
    subscriptionRedelivery :: [MessageId],
    subscriptionActiveConsumers :: Int
  }

emptyLedger :: Ledger
emptyLedger =
  Ledger
    { ledgerTopics = mempty,
      ledgerSubscriptions = mempty,
      ledgerDedup = mempty,
      ledgerTopicConfigs = mempty,
      ledgerTerminatedTopics = mempty,
      ledgerTopicExports = mempty
    }

newFilesystemPulsarHandle :: IO FilesystemPulsarHandle
newFilesystemPulsarHandle = FilesystemPulsarHandle <$> newTVarIO emptyLedger

runFilesystemPulsar :: FilesystemPulsarHandle -> FilesystemPulsar a -> IO a
runFilesystemPulsar handle action = runReaderT (unFilesystemPulsar action) handle

withFilesystemPulsar :: FilesystemPulsar a -> IO a
withFilesystemPulsar action = do
  handle <- newFilesystemPulsarHandle
  runFilesystemPulsar handle action

instance HasPulsar FilesystemPulsar where
  pulsarPublish topic message = do
    now <- liftIO getCurrentTime
    stateVar <- askState
    liftIO (atomically do
      ledger <- readTVar stateVar
      case producerDeduplicationKey message >>= lookupDedup topic ledger of
        Just existing -> pure (Right existing)
        Nothing -> do
          let topicMessages = Map.findWithDefault [] topic (ledgerTopics ledger)
              messageId = MessageId 0 (length topicMessages)
              stored =
                PulsarMessage
                  { pulsarMessageTopic = topic,
                    pulsarMessageId = messageId,
                    pulsarMessageKey = producerKey message,
                    pulsarMessagePayload = producerPayload message,
                    pulsarMessageProperties = producerProperties message,
                    pulsarMessagePublishedAt = now
                  }
              ledger' =
                ledger
                  { ledgerTopics = Map.insert topic (topicMessages <> [stored]) (ledgerTopics ledger),
                    ledgerDedup = insertDedup topic message messageId (ledgerDedup ledger)
                  }
          writeTVar stateVar ledger'
          pure (Right messageId)
      )

  pulsarSubscribe topic name mode = do
    stateVar <- askState
    liftIO (atomically do
      ledger <- readTVar stateVar
      let key = (topic, name)
          existing = Map.lookup key (ledgerSubscriptions ledger)
      case existing of
        Just subState
          | subscriptionStateMode subState == Exclusive ->
              pure (Left (ExclusiveSubscriptionAlreadyActive topic name))
          | otherwise -> do
              let subState' =
                    subState
                      { subscriptionActiveConsumers = subscriptionActiveConsumers subState + 1
                      }
              writeTVar stateVar ledger {ledgerSubscriptions = Map.insert key subState' (ledgerSubscriptions ledger)}
              pure (Right (Subscription topic name mode))
        Nothing -> do
          let subState =
                SubscriptionState
                  { subscriptionStateMode = mode,
                    subscriptionCursor = 0,
                    subscriptionAcknowledged = mempty,
                    subscriptionRedelivery = [],
                    subscriptionActiveConsumers = 1
                  }
          writeTVar stateVar ledger {ledgerSubscriptions = Map.insert key subState (ledgerSubscriptions ledger)}
          pure (Right (Subscription topic name mode))
      )

  pulsarConsume subscription = do
    stateVar <- askState
    liftIO (atomically do
      ledger <- readTVar stateVar
      case Map.lookup (subscriptionKey subscription) (ledgerSubscriptions ledger) of
        Nothing -> pure (Left (SubscriptionNotFound subscription))
        Just subState ->
          case nextRedelivery ledger subState of
            Just (message, subState') -> do
              writeSubscription stateVar ledger subscription subState'
              pure (Right (Just message))
            Nothing -> do
              let messages = Map.findWithDefault [] (subscriptionTopic subscription) (ledgerTopics ledger)
                  cursor = subscriptionCursor subState
              if cursor >= length messages
                then pure (Right Nothing)
                else do
                  let message = messages !! cursor
                      subState' = subState {subscriptionCursor = cursor + 1}
                  writeSubscription stateVar ledger subscription subState'
                  pure (Right (Just message))
      )

  pulsarAcknowledge subscription messageId = do
    stateVar <- askState
    liftIO (atomically do
      ledger <- readTVar stateVar
      case Map.lookup (subscriptionKey subscription) (ledgerSubscriptions ledger) of
        Nothing -> pure (Left (SubscriptionNotFound subscription))
        Just subState -> do
          let subState' =
                subState
                  { subscriptionAcknowledged = Set.insert messageId (subscriptionAcknowledged subState),
                    subscriptionRedelivery = filter (/= messageId) (subscriptionRedelivery subState)
                  }
          writeSubscription stateVar ledger subscription subState'
          pure (Right ())
      )

  pulsarNegativeAcknowledge subscription messageId = do
    stateVar <- askState
    liftIO (atomically do
      ledger <- readTVar stateVar
      case Map.lookup (subscriptionKey subscription) (ledgerSubscriptions ledger) of
        Nothing -> pure (Left (SubscriptionNotFound subscription))
        Just subState ->
          if messageExists (subscriptionTopic subscription) messageId ledger
            then do
              let subState' =
                    subState
                      { subscriptionRedelivery =
                          subscriptionRedelivery subState <> [messageId]
                      }
              writeSubscription stateVar ledger subscription subState'
              pure (Right ())
            else pure (Left (MessageNotFound messageId))
      )

  pulsarSeek subscription target = do
    stateVar <- askState
    liftIO (atomically do
      ledger <- readTVar stateVar
      case Map.lookup (subscriptionKey subscription) (ledgerSubscriptions ledger) of
        Nothing -> pure (Left (SubscriptionNotFound subscription))
        Just subState -> do
          let messages = Map.findWithDefault [] (subscriptionTopic subscription) (ledgerTopics ledger)
              cursor =
                case target of
                  SeekEarliest -> 0
                  SeekLatest -> length messages
                  SeekMessageId messageId -> messageEntryId messageId
              subState' =
                subState
                  { subscriptionCursor = max 0 (min cursor (length messages)),
                    subscriptionRedelivery = []
                  }
          writeSubscription stateVar ledger subscription subState'
          pure (Right ())
      )

instance HasPulsarAdmin FilesystemPulsar where
  createTopic topic = do
    stateVar <- askState
    atomicallyLift do
      ledger <- readTVar stateVar
      let existed = Map.member topic (ledgerTopics ledger)
          ledger' =
            ledger
              { ledgerTopics = Map.insertWith (<>) topic [] (ledgerTopics ledger),
                ledgerTopicConfigs = Map.insertWith keepExisting topic emptyTopicConfig (ledgerTopicConfigs ledger)
              }
      writeTVar stateVar ledger'
      pure (Right (AdminActionResult (not existed) "topic created"))

  deleteTopic topic = do
    stateVar <- askState
    atomicallyLift do
      ledger <- readTVar stateVar
      let existed = Map.member topic (ledgerTopics ledger)
          ledger' =
            ledger
              { ledgerTopics = Map.delete topic (ledgerTopics ledger),
                ledgerTopicConfigs = Map.delete topic (ledgerTopicConfigs ledger),
                ledgerTerminatedTopics = Set.delete topic (ledgerTerminatedTopics ledger),
                ledgerTopicExports = Map.delete topic (ledgerTopicExports ledger)
              }
      writeTVar stateVar ledger'
      pure (Right (AdminActionResult existed "topic deleted"))

  terminateTopic topic = do
    stateVar <- askState
    atomicallyLift do
      ledger <- readTVar stateVar
      if Map.member topic (ledgerTopics ledger)
        then do
          let changed = not (Set.member topic (ledgerTerminatedTopics ledger))
          writeTVar stateVar ledger {ledgerTerminatedTopics = Set.insert topic (ledgerTerminatedTopics ledger)}
          pure (Right (AdminActionResult changed "topic terminated"))
        else pure (Left (PulsarAdminTopicNotFound topic))

  setRetention topic policy =
    updateTopicConfig topic \config -> config {topicRetention = Just policy}

  setCompaction topic policy =
    updateTopicConfig topic \config -> config {topicCompaction = Just policy}

  setDedupWindow topic window =
    updateTopicConfig topic \config -> config {topicDedupWindow = Just window}

  listTopics = do
    stateVar <- askState
    atomicallyLift do
      ledger <- readTVar stateVar
      pure (Right (Map.keys (ledgerTopics ledger)))

  exportTopicToObject topic objectRef = do
    stateVar <- askState
    atomicallyLift do
      ledger <- readTVar stateVar
      if Map.member topic (ledgerTopics ledger)
        then do
          let changed = Map.lookup topic (ledgerTopicExports ledger) /= Just objectRef
          writeTVar stateVar ledger {ledgerTopicExports = Map.insert topic objectRef (ledgerTopicExports ledger)}
          pure (Right (AdminActionResult changed "topic exported"))
        else pure (Left (PulsarAdminTopicNotFound topic))

  importTopicFromObject topic objectRef = do
    stateVar <- askState
    atomicallyLift do
      ledger <- readTVar stateVar
      let changed = Map.lookup topic (ledgerTopicExports ledger) /= Just objectRef
          ledger' =
            ledger
              { ledgerTopics = Map.insertWith (<>) topic [] (ledgerTopics ledger),
                ledgerTopicConfigs = Map.insertWith keepExisting topic emptyTopicConfig (ledgerTopicConfigs ledger),
                ledgerTopicExports = Map.insert topic objectRef (ledgerTopicExports ledger)
              }
      writeTVar stateVar ledger'
      pure (Right (AdminActionResult changed "topic imported"))

updateTopicConfig :: TopicName -> (TopicConfig -> TopicConfig) -> FilesystemPulsar (Either PulsarAdminError AdminActionResult)
updateTopicConfig topic update = do
  stateVar <- askState
  atomicallyLift do
    ledger <- readTVar stateVar
    if Map.member topic (ledgerTopics ledger)
      then do
        let before = Map.findWithDefault emptyTopicConfig topic (ledgerTopicConfigs ledger)
            after = update before
            changed = before /= after
        writeTVar stateVar ledger {ledgerTopicConfigs = Map.insert topic after (ledgerTopicConfigs ledger)}
        pure (Right (AdminActionResult changed "topic configured"))
      else pure (Left (PulsarAdminTopicNotFound topic))

lookupDedup :: TopicName -> Ledger -> Text -> Maybe MessageId
lookupDedup topic ledger key = Map.lookup topic (ledgerDedup ledger) >>= Map.lookup key

insertDedup :: TopicName -> ProducerMessage -> MessageId -> Map TopicName (Map Text MessageId) -> Map TopicName (Map Text MessageId)
insertDedup topic message messageId =
  case producerDeduplicationKey message of
    Nothing -> id
    Just key -> Map.insertWith (<>) topic (Map.singleton key messageId)

subscriptionKey :: Subscription -> SubscriptionKey
subscriptionKey subscription = (subscriptionTopic subscription, subscriptionName subscription)

writeSubscription :: TVar Ledger -> Ledger -> Subscription -> SubscriptionState -> STM ()
writeSubscription stateVar ledger subscription subState =
  writeTVar
    stateVar
    ledger
      { ledgerSubscriptions =
          Map.insert (subscriptionKey subscription) subState (ledgerSubscriptions ledger)
      }

keepExisting :: a -> a -> a
keepExisting _new existing =
  existing

nextRedelivery :: Ledger -> SubscriptionState -> Maybe (PulsarMessage, SubscriptionState)
nextRedelivery ledger subState =
  case subscriptionRedelivery subState of
    [] -> Nothing
    messageId : rest -> do
      message <- findMessage messageId ledger
      pure (message, subState {subscriptionRedelivery = rest})

messageExists :: TopicName -> MessageId -> Ledger -> Bool
messageExists topic messageId ledger =
  any ((== messageId) . pulsarMessageId) (Map.findWithDefault [] topic (ledgerTopics ledger))

findMessage :: MessageId -> Ledger -> Maybe PulsarMessage
findMessage messageId ledger =
  find ((== messageId) . pulsarMessageId) (concat (Map.elems (ledgerTopics ledger)))

askState :: FilesystemPulsar (TVar Ledger)
askState = filesystemPulsarState <$> FilesystemPulsar ask

atomicallyLift :: (MonadIO m) => STM a -> m a
atomicallyLift = liftIO . atomically
