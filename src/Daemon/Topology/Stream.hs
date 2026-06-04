module Daemon.Topology.Stream where

import Data.Text (Text)
import Daemon.Pulsar
import Daemon.Topology.Types

data Stream = Stream
  { streamName :: !Text,
    streamTopic :: !TopicName,
    streamSubscription :: !SubscriptionName,
    streamSubscriptionMode :: !SubscriptionMode
  }
  deriving stock (Eq, Show)

stream :: Text -> TopicName -> SubscriptionName -> Stream
stream name topic subscription =
  Stream name topic subscription Shared

toTopology :: Stream -> Topology
toTopology topology =
  Topology
    { topologyName = streamName topology,
      topologyTopics = [TopologyTopic (streamTopic topology)],
      topologySubscriptions =
        [ TopologySubscription
            { topologySubscriptionTopic = streamTopic topology,
              topologySubscriptionName = streamSubscription topology,
              topologySubscriptionMode = streamSubscriptionMode topology
            }
        ]
    }
