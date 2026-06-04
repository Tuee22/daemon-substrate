module Daemon.Pulsar where

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (UTCTime)

newtype TopicName = TopicName {unTopicName :: Text}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

newtype SubscriptionName = SubscriptionName {unSubscriptionName :: Text}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

data SubscriptionMode
  = Shared
  | KeyShared
  | Exclusive
  | Failover
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data MessageId = MessageId
  { messageLedgerId :: !Int,
    messageEntryId :: !Int
  }
  deriving stock (Eq, Ord, Show)

data ProducerMessage = ProducerMessage
  { producerKey :: Maybe Text,
    producerPayload :: ByteString,
    producerProperties :: Map Text Text,
    producerDeduplicationKey :: Maybe Text
  }
  deriving stock (Eq, Show)

data PulsarMessage = PulsarMessage
  { pulsarMessageTopic :: TopicName,
    pulsarMessageId :: MessageId,
    pulsarMessageKey :: Maybe Text,
    pulsarMessagePayload :: ByteString,
    pulsarMessageProperties :: Map Text Text,
    pulsarMessagePublishedAt :: UTCTime
  }
  deriving stock (Eq, Show)

data Subscription = Subscription
  { subscriptionTopic :: TopicName,
    subscriptionName :: SubscriptionName,
    subscriptionMode :: SubscriptionMode
  }
  deriving stock (Eq, Ord, Show)

data SeekTarget
  = SeekEarliest
  | SeekLatest
  | SeekMessageId MessageId
  deriving stock (Eq, Show)

data PulsarError
  = TopicNotFound TopicName
  | SubscriptionNotFound Subscription
  | ExclusiveSubscriptionAlreadyActive TopicName SubscriptionName
  | MessageNotFound MessageId
  | PulsarBackendUnavailable Text
  deriving stock (Eq, Show)

class (Monad m) => HasPulsar m where
  pulsarPublish :: TopicName -> ProducerMessage -> m (Either PulsarError MessageId)
  pulsarSubscribe :: TopicName -> SubscriptionName -> SubscriptionMode -> m (Either PulsarError Subscription)
  pulsarWaitActive :: Subscription -> m (Either PulsarError Bool)
  pulsarWaitActive _subscription = pure (Right True)
  pulsarConsume :: Subscription -> m (Either PulsarError (Maybe PulsarMessage))
  pulsarAcknowledge :: Subscription -> MessageId -> m (Either PulsarError ())
  pulsarNegativeAcknowledge :: Subscription -> MessageId -> m (Either PulsarError ())
  pulsarSeek :: Subscription -> SeekTarget -> m (Either PulsarError ())

simpleProducerMessage :: ByteString -> ProducerMessage
simpleProducerMessage payload =
  ProducerMessage
    { producerKey = Nothing,
      producerPayload = payload,
      producerProperties = mempty,
      producerDeduplicationKey = Nothing
    }
