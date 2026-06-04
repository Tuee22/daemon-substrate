module Daemon.Pulsar.Native.Lookup where

import Data.Function ((&))
import Data.ProtoLens (defMessage)
import Data.Word (Word64)
import Daemon.Pulsar (TopicName)
import qualified Daemon.Pulsar as Pulsar
import Daemon.Pulsar.Native.Connection (BrokerAddress)
import qualified Daemon.Proto.PulsarApi as Api
import Lens.Family2 ((.~))

data LookupResult = LookupResult
  { lookupTopic :: TopicName,
    lookupBroker :: BrokerAddress,
    lookupPartitions :: Int
  }
  deriving stock (Eq, Show)

lookupCommand :: TopicName -> Word64 -> Bool -> Api.BaseCommand
lookupCommand topic requestId authoritative =
  defMessage
    & Api.type' .~ Api.BaseCommand'LOOKUP
    & Api.lookupTopic
      .~ ( defMessage
             & Api.topic .~ Pulsar.unTopicName topic
             & Api.requestId .~ requestId
             & Api.authoritative .~ authoritative
         )
