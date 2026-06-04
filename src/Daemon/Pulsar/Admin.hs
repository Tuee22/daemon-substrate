module Daemon.Pulsar.Admin where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Daemon.Pulsar (TopicName)

data RetentionPolicy = RetentionPolicy
  { retentionSizeBytes :: Maybe Int,
    retentionTimeSeconds :: Maybe Int
  }
  deriving stock (Eq, Show)

newtype CompactionPolicy = CompactionPolicy
  { compactionThresholdBytes :: Int
  }
  deriving stock (Eq, Show)

newtype DedupWindow = DedupWindow
  { dedupWindowSeconds :: Int
  }
  deriving stock (Eq, Show)

data TopicConfig = TopicConfig
  { topicRetention :: Maybe RetentionPolicy,
    topicCompaction :: Maybe CompactionPolicy,
    topicDedupWindow :: Maybe DedupWindow
  }
  deriving stock (Eq, Show)

emptyTopicConfig :: TopicConfig
emptyTopicConfig =
  TopicConfig
    { topicRetention = Nothing,
      topicCompaction = Nothing,
      topicDedupWindow = Nothing
    }

data AdminActionResult = AdminActionResult
  { adminActionChanged :: Bool,
    adminActionDetail :: Text
  }
  deriving stock (Eq, Show)

data PulsarAdminError
  = PulsarAdminTopicNotFound TopicName
  | PulsarAdminBackendUnavailable Text
  deriving stock (Eq, Show)

class (Monad m) => HasPulsarAdmin m where
  createTopic :: TopicName -> m (Either PulsarAdminError AdminActionResult)
  deleteTopic :: TopicName -> m (Either PulsarAdminError AdminActionResult)
  terminateTopic :: TopicName -> m (Either PulsarAdminError AdminActionResult)
  setRetention :: TopicName -> RetentionPolicy -> m (Either PulsarAdminError AdminActionResult)
  setCompaction :: TopicName -> CompactionPolicy -> m (Either PulsarAdminError AdminActionResult)
  setDedupWindow :: TopicName -> DedupWindow -> m (Either PulsarAdminError AdminActionResult)
  listTopics :: m (Either PulsarAdminError [TopicName])
  exportTopicToObject :: TopicName -> Text -> m (Either PulsarAdminError AdminActionResult)
  importTopicFromObject :: TopicName -> Text -> m (Either PulsarAdminError AdminActionResult)

type TopicConfigMap = Map TopicName TopicConfig
