module Daemon.Topology.FanIn where

import Data.Text (Text)
import Daemon.Pulsar
import Daemon.Topology.Types

data FanIn = FanIn
  { fanInName :: !Text,
    fanInInputTopics :: ![TopicName],
    fanInOutputTopic :: !TopicName,
    fanInSubscriptionName :: !SubscriptionName,
    fanInSubscriptionMode :: !SubscriptionMode
  }
  deriving stock (Eq, Show)

fanIn :: Text -> [TopicName] -> TopicName -> SubscriptionName -> FanIn
fanIn name inputs output subscription =
  FanIn name inputs output subscription Shared

toTopology :: FanIn -> Topology
toTopology topology =
  Topology
    { topologyName = fanInName topology,
      topologyTopics = TopologyTopic <$> (fanInInputTopics topology <> [fanInOutputTopic topology]),
      topologySubscriptions =
        [ TopologySubscription
            { topologySubscriptionTopic = topic,
              topologySubscriptionName = fanInSubscriptionName topology,
              topologySubscriptionMode = fanInSubscriptionMode topology
            }
        | topic <- fanInInputTopics topology
        ]
    }
