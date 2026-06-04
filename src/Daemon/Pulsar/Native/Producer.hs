module Daemon.Pulsar.Native.Producer where

import Data.Function ((&))
import qualified Data.Map.Strict as Map
import Data.ProtoLens (defMessage)
import Data.Text (Text)
import Data.Word (Word64)
import Daemon.Pulsar (ProducerMessage, TopicName)
import qualified Daemon.Pulsar as Pulsar
import qualified Daemon.Proto.PulsarApi as Api
import Lens.Family2 ((.~))

newtype ProducerId = ProducerId {unProducerId :: Int}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

data ProducerRegistration = ProducerRegistration
  { producerRegistrationId :: ProducerId,
    producerRegistrationTopic :: TopicName
  }
  deriving stock (Eq, Show)

producerCommand :: TopicName -> ProducerId -> Word64 -> Api.BaseCommand
producerCommand topic producerId requestId =
  defMessage
    & Api.type' .~ Api.BaseCommand'PRODUCER
    & Api.producer
      .~ ( defMessage
             & Api.topic .~ Pulsar.unTopicName topic
             & Api.producerId .~ producerIdWord producerId
             & Api.requestId .~ requestId
         )

sendCommand :: ProducerId -> Word64 -> Api.BaseCommand
sendCommand producerId sequenceId =
  defMessage
    & Api.type' .~ Api.BaseCommand'SEND
    & Api.send
      .~ ( defMessage
             & Api.producerId .~ producerIdWord producerId
             & Api.sequenceId .~ sequenceId
         )

messageMetadata :: Text -> Word64 -> Word64 -> ProducerMessage -> Api.MessageMetadata
messageMetadata producerName sequenceId publishTime message =
  withPartitionKey
    ( defMessage
        & Api.producerName .~ producerName
        & Api.sequenceId .~ sequenceId
        & Api.publishTime .~ publishTime
        & Api.properties .~ metadataProperties message
    )
  where
    withPartitionKey metadata =
      case Pulsar.producerKey message of
        Nothing -> metadata
        Just key -> metadata & Api.partitionKey .~ key

metadataProperties :: ProducerMessage -> [Api.KeyValue]
metadataProperties message =
  fmap keyValue (Map.toList (Pulsar.producerProperties message) <> dedupProperty)
  where
    dedupProperty =
      case Pulsar.producerDeduplicationKey message of
        Nothing -> []
        Just key -> [("daemon-substrate.deduplication-key", key)]

keyValue :: (Text, Text) -> Api.KeyValue
keyValue (key, value) =
  defMessage
    & Api.key .~ key
    & Api.value .~ value

producerIdWord :: ProducerId -> Word64
producerIdWord = fromIntegral . unProducerId
