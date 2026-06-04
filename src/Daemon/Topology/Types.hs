module Daemon.Topology.Types where

import Data.Text (Text)
import Daemon.Pulsar

data TopologyTopic = TopologyTopic
  { topologyTopicName :: !TopicName
  }
  deriving stock (Eq, Ord, Show)

data TopologySubscription = TopologySubscription
  { topologySubscriptionTopic :: !TopicName,
    topologySubscriptionName :: !SubscriptionName,
    topologySubscriptionMode :: !SubscriptionMode
  }
  deriving stock (Eq, Ord, Show)

data Topology = Topology
  { topologyName :: !Text,
    topologyTopics :: ![TopologyTopic],
    topologySubscriptions :: ![TopologySubscription]
  }
  deriving stock (Eq, Show)

mergeTopologies :: Text -> [Topology] -> Topology
mergeTopologies name topologies =
  Topology
    { topologyName = name,
      topologyTopics = concatMap topologyTopics topologies,
      topologySubscriptions = concatMap topologySubscriptions topologies
    }
