module Daemon.Bootstrap where

import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Daemon.MinIO
import Daemon.MinIO.Store (putBlob, stableETag)
import Daemon.Pulsar
import qualified Daemon.Wire.Workflow as Workflow

data BootstrapOptions = BootstrapOptions
  { bootstrapRequestTopic :: !TopicName,
    bootstrapSubscriptionName :: !SubscriptionName,
    bootstrapSubscriptionMode :: !SubscriptionMode,
    bootstrapReadyTopic :: !TopicName,
    bootstrapArtifactBucket :: !BucketName,
    bootstrapReadyPayloadType :: !Workflow.PayloadTypeUrl
  }
  deriving stock (Eq, Show)

data BootstrapOutput = BootstrapOutput
  { bootstrapOutputName :: !Text,
    bootstrapOutputBytes :: !ByteString
  }
  deriving stock (Eq, Show)

data BootstrapStepResult
  = BootstrapNoMessage
  | BootstrapPublished !Workflow.EventId !ObjectRef !MessageId
  deriving stock (Eq, Show)

data BootstrapError
  = BootstrapPulsarError !PulsarError
  | BootstrapMinIOError !MinIOError
  | BootstrapWorkflowWireError !Workflow.WorkflowWireError
  | BootstrapHandlerFailed !Text
  deriving stock (Eq, Show)

type BootstrapHandler m = Workflow.WorkflowEvent -> m (Either BootstrapError BootstrapOutput)

bootstrapOptions ::
  TopicName ->
  SubscriptionName ->
  TopicName ->
  BucketName ->
  Workflow.PayloadTypeUrl ->
  BootstrapOptions
bootstrapOptions requestTopic subscriptionName readyTopic artifactBucket readyPayloadType =
  BootstrapOptions
    { bootstrapRequestTopic = requestTopic,
      bootstrapSubscriptionName = subscriptionName,
      bootstrapSubscriptionMode = Shared,
      bootstrapReadyTopic = readyTopic,
      bootstrapArtifactBucket = artifactBucket,
      bootstrapReadyPayloadType = readyPayloadType
    }

runFanInBootstrap ::
  (HasPulsar m, HasMinIO m) =>
  BootstrapOptions ->
  BootstrapHandler m ->
  m (Either BootstrapError BootstrapStepResult)
runFanInBootstrap options handler = do
  subscribed <-
    pulsarSubscribe
      (bootstrapRequestTopic options)
      (bootstrapSubscriptionName options)
      (bootstrapSubscriptionMode options)
  case subscribed of
    Left err -> pure (Left (BootstrapPulsarError err))
    Right subscription -> bootstrapStep options handler subscription

bootstrapStep ::
  (HasPulsar m, HasMinIO m) =>
  BootstrapOptions ->
  BootstrapHandler m ->
  Subscription ->
  m (Either BootstrapError BootstrapStepResult)
bootstrapStep options handler subscription = do
  consumed <- pulsarConsume subscription
  case consumed of
    Left err -> pure (Left (BootstrapPulsarError err))
    Right Nothing -> pure (Right BootstrapNoMessage)
    Right (Just message) ->
      case Workflow.decodeWorkflowEvent (pulsarMessagePayload message) of
        Left err -> nack message (BootstrapWorkflowWireError err)
        Right event -> do
          handled <- handler event
          case handled of
            Left err -> nack message err
            Right output -> do
              stored <- putBlob (bootstrapArtifactBucket options) (bootstrapOutputBytes output)
              case stored of
                Left err -> nack message (BootstrapMinIOError err)
                Right ref -> do
                  published <- publishReadyEvent options event output ref
                  case published of
                    Left err -> nack message err
                    Right messageId -> ack message (BootstrapPublished (Workflow.workflowEventId event) ref messageId)
  where
    ack message result = do
      acknowledged <- pulsarAcknowledge subscription (pulsarMessageId message)
      pure case acknowledged of
        Left err -> Left (BootstrapPulsarError err)
        Right () -> Right result
    nack message err = do
      nacked <- pulsarNegativeAcknowledge subscription (pulsarMessageId message)
      pure case nacked of
        Left pulsarErr -> Left (BootstrapPulsarError pulsarErr)
        Right () -> Left err

publishReadyEvent ::
  (HasPulsar m) =>
  BootstrapOptions ->
  Workflow.WorkflowEvent ->
  BootstrapOutput ->
  ObjectRef ->
  m (Either BootstrapError MessageId)
publishReadyEvent options request output ref = do
  published <-
    pulsarPublish
      (bootstrapReadyTopic options)
      ProducerMessage
        { producerKey = Just (Workflow.unEventId (Workflow.workflowEventId request)),
          producerPayload = Workflow.encodeWorkflowEvent (readyEvent options request output ref),
          producerProperties = Map.singleton "bootstrap-output-name" (bootstrapOutputName output),
          producerDeduplicationKey = Just (Workflow.unEventId (Workflow.workflowEventId request))
        }
  pure case published of
    Left err -> Left (BootstrapPulsarError err)
    Right messageId -> Right messageId

readyEvent ::
  BootstrapOptions ->
  Workflow.WorkflowEvent ->
  BootstrapOutput ->
  ObjectRef ->
  Workflow.WorkflowEvent
readyEvent options request output ref =
  Workflow.WorkflowEvent
    { Workflow.workflowEventId = Workflow.workflowEventId request,
      Workflow.workflowProducedAt = Workflow.workflowProducedAt request,
      Workflow.workflowDeadlineAt = Nothing,
      Workflow.workflowKind = Workflow.workflowKind request,
      Workflow.workflowPayloadType = bootstrapReadyPayloadType options,
      Workflow.workflowPayload =
        Workflow.WireObjectRef
          Workflow.ObjectRef
            { Workflow.objectRefBucket = unBucketName (objectRefBucket ref),
              Workflow.objectRefKey = unObjectKey (objectRefKey ref),
              Workflow.objectRefETag = unETag (stableETag (bootstrapOutputBytes output))
            }
    }
