module Daemon.WorkflowState where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.ProtoLens.Encoding (decodeMessage, encodeMessage)
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.Pulsar
import qualified Daemon.Proto.Workflow as WorkflowProto
import qualified Daemon.Wire.Workflow as Workflow

data WorkflowStateError foldError
  = WorkflowStatePulsarError !PulsarError
  | WorkflowStateDecodeError !Text
  | WorkflowStateWireError !Workflow.WorkflowWireError
  | WorkflowStateFoldError !foldError
  deriving stock (Eq, Show)

appendWorkflowEvent ::
  (HasPulsar m) =>
  TopicName ->
  Workflow.WorkflowEvent ->
  m (Either (WorkflowStateError foldError) MessageId)
appendWorkflowEvent topic event = do
  published <-
    pulsarPublish
      topic
      ProducerMessage
        { producerKey = Just (Workflow.unEventId (Workflow.workflowEventId event)),
          producerPayload = encodeMessage (Workflow.toProto event),
          producerProperties = mempty,
          producerDeduplicationKey = Just (Workflow.unEventId (Workflow.workflowEventId event))
        }
  pure case published of
    Left err -> Left (WorkflowStatePulsarError err)
    Right messageId -> Right messageId

rehydrateWorkflowState ::
  (HasPulsar m) =>
  TopicName ->
  state ->
  (state -> Workflow.WorkflowEvent -> Either foldError state) ->
  m (Either (WorkflowStateError foldError) state)
rehydrateWorkflowState topic initial step = do
  subscribed <- pulsarSubscribe topic rehydrateSubscription Failover
  case subscribed of
    Left err -> pure (Left (WorkflowStatePulsarError err))
    Right subscription -> do
      seeked <- pulsarSeek subscription SeekEarliest
      case seeked of
        Left err -> pure (Left (WorkflowStatePulsarError err))
        Right () -> replay initial subscription
  where
    replay state subscription = do
      consumed <- pulsarConsume subscription
      case consumed of
        Left err -> pure (Left (WorkflowStatePulsarError err))
        Right Nothing -> pure (Right state)
        Right (Just message) ->
          case decodeWorkflowPayload (pulsarMessagePayload message) of
            Left err -> pure (Left err)
            Right event ->
              case step state event of
                Left err -> pure (Left (WorkflowStateFoldError err))
                Right state' -> do
                  acknowledged <- pulsarAcknowledge subscription (pulsarMessageId message)
                  case acknowledged of
                    Left err -> pure (Left (WorkflowStatePulsarError err))
                    Right () -> replay state' subscription

workflowStateByEventId ::
  (HasPulsar m) =>
  TopicName ->
  m (Either (WorkflowStateError Void) (Map Workflow.EventId Workflow.WorkflowEvent))
workflowStateByEventId topic =
  rehydrateWorkflowState topic mempty \state event ->
    Right (Map.insert (Workflow.workflowEventId event) event state)

data Void
  = Void
  deriving stock (Eq, Show)

decodeWorkflowPayload ::
  ByteString ->
  Either (WorkflowStateError foldError) Workflow.WorkflowEvent
decodeWorkflowPayload payload =
  case (decodeMessage payload :: Either String WorkflowProto.WorkflowEvent) of
    Left err -> Left (WorkflowStateDecodeError (Text.pack err))
    Right proto ->
      case Workflow.fromProto proto of
        Left err -> Left (WorkflowStateWireError err)
        Right event -> Right event

rehydrateSubscription :: SubscriptionName
rehydrateSubscription =
  SubscriptionName "__daemon-substrate-workflow-state-rehydrate"
