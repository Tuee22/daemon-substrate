module Daemon.Pulsar.Native.Consumer where

import Data.Function ((&))
import Data.ProtoLens (defMessage)
import Data.Text (Text)
import Data.Word (Word64)
import Daemon.Pulsar (MessageId, Subscription, SubscriptionMode)
import qualified Daemon.Pulsar as Pulsar
import qualified Daemon.Proto.PulsarApi as Api
import Lens.Family2 ((.~), (^.))

newtype ConsumerId = ConsumerId {unConsumerId :: Int}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

data ConsumerRegistration = ConsumerRegistration
  { consumerRegistrationId :: ConsumerId,
    consumerRegistrationSubscription :: Subscription
  }
  deriving stock (Eq, Show)

subscribeCommand :: Subscription -> ConsumerId -> Text -> Word64 -> Api.BaseCommand
subscribeCommand subscription consumerId consumerName requestId =
  defMessage
    & Api.type' .~ Api.BaseCommand'SUBSCRIBE
    & Api.subscribe
      .~ ( defMessage
             & Api.topic .~ Pulsar.unTopicName (Pulsar.subscriptionTopic subscription)
             & Api.subscription .~ Pulsar.unSubscriptionName (Pulsar.subscriptionName subscription)
             & Api.subType .~ subscriptionModeType (Pulsar.subscriptionMode subscription)
             & Api.consumerId .~ consumerIdWord consumerId
             & Api.consumerName .~ consumerName
             & Api.requestId .~ requestId
         )

flowCommand :: ConsumerId -> Word64 -> Api.BaseCommand
flowCommand consumerId permits =
  defMessage
    & Api.type' .~ Api.BaseCommand'FLOW
    & Api.flow
      .~ ( defMessage
             & Api.consumerId .~ consumerIdWord consumerId
             & Api.messagePermits .~ fromIntegral permits
         )

ackCommand :: ConsumerId -> MessageId -> Api.BaseCommand
ackCommand consumerId messageId =
  defMessage
    & Api.type' .~ Api.BaseCommand'ACK
    & Api.ack
      .~ ( defMessage
             & Api.consumerId .~ consumerIdWord consumerId
             & Api.ackType .~ Api.CommandAck'Individual
             & Api.messageId .~ [messageIdData messageId]
         )

redeliverCommand :: ConsumerId -> [MessageId] -> Api.BaseCommand
redeliverCommand consumerId messageIds =
  defMessage
    & Api.type' .~ Api.BaseCommand'REDELIVER_UNACKNOWLEDGED_MESSAGES
    & Api.redeliverUnacknowledgedMessages
      .~ ( defMessage
             & Api.consumerId .~ consumerIdWord consumerId
             & Api.messageIds .~ fmap messageIdData messageIds
         )

seekMessageIdCommand :: ConsumerId -> Word64 -> MessageId -> Api.BaseCommand
seekMessageIdCommand consumerId requestId messageId =
  defMessage
    & Api.type' .~ Api.BaseCommand'SEEK
    & Api.seek
      .~ ( defMessage
             & Api.consumerId .~ consumerIdWord consumerId
             & Api.requestId .~ requestId
             & Api.messageId .~ messageIdData messageId
         )

seekPublishTimeCommand :: ConsumerId -> Word64 -> Word64 -> Api.BaseCommand
seekPublishTimeCommand consumerId requestId publishTime =
  defMessage
    & Api.type' .~ Api.BaseCommand'SEEK
    & Api.seek
      .~ ( defMessage
             & Api.consumerId .~ consumerIdWord consumerId
             & Api.requestId .~ requestId
             & Api.messagePublishTime .~ publishTime
         )

messageIdData :: MessageId -> Api.MessageIdData
messageIdData messageId =
  defMessage
    & Api.ledgerId .~ nonNegativeWord (Pulsar.messageLedgerId messageId)
    & Api.entryId .~ nonNegativeWord (Pulsar.messageEntryId messageId)

messageIdFromData :: Api.MessageIdData -> MessageId
messageIdFromData messageId =
  Pulsar.MessageId
    { Pulsar.messageLedgerId = fromIntegral (messageId ^. Api.ledgerId),
      Pulsar.messageEntryId = fromIntegral (messageId ^. Api.entryId)
    }

subscriptionModeType :: SubscriptionMode -> Api.CommandSubscribe'SubType
subscriptionModeType Pulsar.Shared = Api.CommandSubscribe'Shared
subscriptionModeType Pulsar.KeyShared = Api.CommandSubscribe'Key_Shared
subscriptionModeType Pulsar.Exclusive = Api.CommandSubscribe'Exclusive
subscriptionModeType Pulsar.Failover = Api.CommandSubscribe'Failover

consumerIdWord :: ConsumerId -> Word64
consumerIdWord = fromIntegral . unConsumerId

nonNegativeWord :: Int -> Word64
nonNegativeWord = fromIntegral . max 0
