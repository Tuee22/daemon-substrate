module Daemon.Topology.RequestResponse where

import Data.Text (Text)
import Daemon.Pulsar
import Daemon.Topology.Types

data RequestResponse = RequestResponse
  { requestResponseName :: !Text,
    requestTopic :: !TopicName,
    responseTopic :: !TopicName,
    requestSubscription :: !SubscriptionName,
    requestSubscriptionMode :: !SubscriptionMode
  }
  deriving stock (Eq, Show)

requestResponse :: Text -> TopicName -> TopicName -> SubscriptionName -> RequestResponse
requestResponse name request response subscription =
  RequestResponse name request response subscription Shared

toTopology :: RequestResponse -> Topology
toTopology topology =
  Topology
    { topologyName = requestResponseName topology,
      topologyTopics = TopologyTopic <$> [requestTopic topology, responseTopic topology],
      topologySubscriptions =
        [ TopologySubscription
            { topologySubscriptionTopic = requestTopic topology,
              topologySubscriptionName = requestSubscription topology,
              topologySubscriptionMode = requestSubscriptionMode topology
            }
        ]
    }
