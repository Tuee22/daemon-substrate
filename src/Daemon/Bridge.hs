module Daemon.Bridge where

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Daemon.Pulsar

data BridgeOptions = BridgeOptions
  { bridgeSourceTopic :: !TopicName,
    bridgeSubscriptionName :: !SubscriptionName,
    bridgeSubscriptionMode :: !SubscriptionMode
  }
  deriving stock (Eq, Show)

data BridgeOutput = BridgeOutput
  { bridgeOutputTopic :: !TopicName,
    bridgeOutputPayload :: !ByteString,
    bridgeOutputKey :: !(Maybe Text),
    bridgeOutputProperties :: !(Map Text Text),
    bridgeOutputDeduplicationKey :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data BridgeStepResult
  = BridgeNoMessage
  | BridgeForwarded !MessageId !MessageId !TopicName
  deriving stock (Eq, Show)

data BridgeError
  = BridgePulsarError !PulsarError
  | BridgeTransformError !Text
  deriving stock (Eq, Show)

type BridgeTransform m = PulsarMessage -> m (Either BridgeError BridgeOutput)

bridgeOptions :: TopicName -> SubscriptionName -> BridgeOptions
bridgeOptions sourceTopic subscriptionName =
  BridgeOptions
    { bridgeSourceTopic = sourceTopic,
      bridgeSubscriptionName = subscriptionName,
      bridgeSubscriptionMode = Shared
    }

runBridge ::
  (HasPulsar m) =>
  BridgeOptions ->
  BridgeTransform m ->
  m (Either BridgeError BridgeStepResult)
runBridge options transform = do
  subscribed <-
    pulsarSubscribe
      (bridgeSourceTopic options)
      (bridgeSubscriptionName options)
      (bridgeSubscriptionMode options)
  case subscribed of
    Left err -> pure (Left (BridgePulsarError err))
    Right subscription -> bridgeStep transform subscription

bridgeStep ::
  (HasPulsar m) =>
  BridgeTransform m ->
  Subscription ->
  m (Either BridgeError BridgeStepResult)
bridgeStep transform subscription = do
  consumed <- pulsarConsume subscription
  case consumed of
    Left err -> pure (Left (BridgePulsarError err))
    Right Nothing -> pure (Right BridgeNoMessage)
    Right (Just message) -> do
      transformed <- transform message
      case transformed of
        Left err -> nack message err
        Right output -> do
          published <- pulsarPublish (bridgeOutputTopic output) (bridgeProducerMessage output)
          case published of
            Left err -> nack message (BridgePulsarError err)
            Right targetId -> ack message (BridgeForwarded (pulsarMessageId message) targetId (bridgeOutputTopic output))
  where
    ack message result = do
      acknowledged <- pulsarAcknowledge subscription (pulsarMessageId message)
      pure case acknowledged of
        Left err -> Left (BridgePulsarError err)
        Right () -> Right result
    nack message err = do
      nacked <- pulsarNegativeAcknowledge subscription (pulsarMessageId message)
      pure case nacked of
        Left pulsarErr -> Left (BridgePulsarError pulsarErr)
        Right () -> Left err

identityBridge :: (Monad m) => TopicName -> BridgeTransform m
identityBridge targetTopic message =
  pure (Right (bridgeOutputFromMessage targetTopic message))

mapPayloadBridge ::
  (Monad m) =>
  TopicName ->
  (ByteString -> ByteString) ->
  BridgeTransform m
mapPayloadBridge targetTopic transform message =
  pure
    ( Right
        (bridgeOutputFromMessage targetTopic message)
          { bridgeOutputPayload = transform (pulsarMessagePayload message)
          }
    )

routeBridge ::
  (Monad m) =>
  (PulsarMessage -> Either BridgeError TopicName) ->
  BridgeTransform m
routeBridge chooseTopic message =
  pure do
    targetTopic <- chooseTopic message
    Right (bridgeOutputFromMessage targetTopic message)

bridgeOutputFromMessage :: TopicName -> PulsarMessage -> BridgeOutput
bridgeOutputFromMessage targetTopic message =
  BridgeOutput
    { bridgeOutputTopic = targetTopic,
      bridgeOutputPayload = pulsarMessagePayload message,
      bridgeOutputKey = pulsarMessageKey message,
      bridgeOutputProperties = pulsarMessageProperties message,
      bridgeOutputDeduplicationKey = Nothing
    }

bridgeProducerMessage :: BridgeOutput -> ProducerMessage
bridgeProducerMessage output =
  ProducerMessage
    { producerKey = bridgeOutputKey output,
      producerPayload = bridgeOutputPayload output,
      producerProperties = bridgeOutputProperties output,
      producerDeduplicationKey = bridgeOutputDeduplicationKey output
    }
