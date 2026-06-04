module Daemon.Topology.FanOut where

import Data.Text (Text)
import Daemon.Pulsar
import Daemon.Topology.Types

data FanOut = FanOut
  { fanOutName :: !Text,
    fanOutInputTopic :: !TopicName,
    fanOutOutputTopics :: ![TopicName],
    fanOutSubscription :: !SubscriptionName,
    fanOutSubscriptionMode :: !SubscriptionMode
  }
  deriving stock (Eq, Show)

fanOut :: Text -> TopicName -> [TopicName] -> SubscriptionName -> FanOut
fanOut name input outputs subscription =
  FanOut name input outputs subscription Shared

toTopology :: FanOut -> Topology
toTopology topology =
  Topology
    { topologyName = fanOutName topology,
      topologyTopics = TopologyTopic <$> (fanOutInputTopic topology : fanOutOutputTopics topology),
      topologySubscriptions =
        [ TopologySubscription
            { topologySubscriptionTopic = fanOutInputTopic topology,
              topologySubscriptionName = fanOutSubscription topology,
              topologySubscriptionMode = fanOutSubscriptionMode topology
            }
        ]
    }
