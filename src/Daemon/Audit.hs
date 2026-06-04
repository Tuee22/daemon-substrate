module Daemon.Audit where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.ProtoLens (defMessage)
import Data.ProtoLens.Encoding (decodeMessage, encodeMessage)
import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.Pulsar
import qualified Daemon.Proto.Audit as Audit
import Lens.Family2 ((&), (.~), (^.))

data AuditError
  = AuditPulsarError !PulsarError
  | AuditDecodeError !Text
  deriving stock (Eq, Show)

auditPublish ::
  (HasPulsar m) =>
  TopicName ->
  Audit.ResourceRef ->
  Audit.ReconcileAction ->
  m (Either AuditError ())
auditPublish topic resource action =
  auditPublishEvent topic (auditEvent resource action)

auditPublishEvent ::
  (HasPulsar m) =>
  TopicName ->
  Audit.AuditEvent ->
  m (Either AuditError ())
auditPublishEvent topic event = do
  published <-
    pulsarPublish
      topic
      ProducerMessage
        { producerKey = Just (auditResourceKey (event ^. Audit.resource)),
          producerPayload = encodeMessage event,
          producerProperties = mempty,
          producerDeduplicationKey = Nothing
        }
  pure case published of
    Left err -> Left (AuditPulsarError err)
    Right _ -> Right ()

auditReplay ::
  (HasPulsar m) =>
  TopicName ->
  m (Either AuditError (Map Audit.ResourceRef Audit.ReconcileAction))
auditReplay topic = do
  subscribed <- pulsarSubscribe topic replaySubscription Failover
  case subscribed of
    Left err -> pure (Left (AuditPulsarError err))
    Right subscription -> do
      seeked <- pulsarSeek subscription SeekEarliest
      case seeked of
        Left err -> pure (Left (AuditPulsarError err))
        Right () -> replayLoop subscription mempty

auditEvent :: Audit.ResourceRef -> Audit.ReconcileAction -> Audit.AuditEvent
auditEvent resource action =
  defMessage
    & Audit.resource .~ resource
    & Audit.action .~ action

auditResource :: Text -> Text -> Audit.ResourceRef
auditResource kind idValue =
  defMessage
    & Audit.kind .~ kind
    & Audit.id .~ idValue

auditResourceKey :: Audit.ResourceRef -> Text
auditResourceKey resource =
  resource ^. Audit.kind <> ":" <> resource ^. Audit.id

reconcileActionCreated :: Audit.ReconcileAction
reconcileActionCreated =
  Audit.RECONCILE_ACTION_CREATED

reconcileActionConfigured :: Audit.ReconcileAction
reconcileActionConfigured =
  Audit.RECONCILE_ACTION_CONFIGURED

reconcileActionDeleted :: Audit.ReconcileAction
reconcileActionDeleted =
  Audit.RECONCILE_ACTION_DELETED

replayLoop ::
  (HasPulsar m) =>
  Subscription ->
  Map Audit.ResourceRef Audit.ReconcileAction ->
  m (Either AuditError (Map Audit.ResourceRef Audit.ReconcileAction))
replayLoop subscription latestByResource = do
  consumed <- pulsarConsume subscription
  case consumed of
    Left err -> pure (Left (AuditPulsarError err))
    Right Nothing -> pure (Right latestByResource)
    Right (Just message) ->
      case (decodeMessage (pulsarMessagePayload message) :: Either String Audit.AuditEvent) of
        Left err -> pure (Left (AuditDecodeError (Text.pack err)))
        Right event -> do
          acknowledged <- pulsarAcknowledge subscription (pulsarMessageId message)
          case acknowledged of
            Left err -> pure (Left (AuditPulsarError err))
            Right () ->
              replayLoop
                subscription
                (Map.insert (event ^. Audit.resource) (event ^. Audit.action) latestByResource)

replaySubscription :: SubscriptionName
replaySubscription =
  SubscriptionName "__daemon-substrate-audit-replay"
