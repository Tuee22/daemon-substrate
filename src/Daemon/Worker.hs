module Daemon.Worker where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.Engine
import Daemon.MinIO
import Daemon.MinIO.Store (readBlob)
import Daemon.Pulsar
import qualified Daemon.Wire.OrchestratorWorker as WorkerWire
import qualified Daemon.Wire.Workflow as Workflow

data WorkerOptions = WorkerOptions
  { workerInputTopic :: !TopicName,
    workerSubscriptionName :: !SubscriptionName,
    workerSubscriptionMode :: !SubscriptionMode,
    workerResultTopic :: !TopicName,
    workerResultPayloadType :: !Text
  }
  deriving stock (Eq, Show)

data WorkerStepResult
  = WorkerNoMessage
  | WorkerProcessed !Text !Int
  deriving stock (Eq, Show)

data WorkerError
  = WorkerPulsarError !PulsarError
  | WorkerWireError !WorkerWire.OrchestratorWorkerWireError
  | WorkerEmptyBatch !Text
  | WorkerMinIOError !Workflow.ObjectRef !MinIOError
  | WorkerEngineResultCountMismatch !Int !Int
  deriving stock (Eq, Show)

workerOptions ::
  TopicName ->
  SubscriptionName ->
  TopicName ->
  Text ->
  WorkerOptions
workerOptions inputTopic subscriptionName resultTopic resultPayloadType =
  WorkerOptions
    { workerInputTopic = inputTopic,
      workerSubscriptionName = subscriptionName,
      workerSubscriptionMode = Shared,
      workerResultTopic = resultTopic,
      workerResultPayloadType = resultPayloadType
    }

runWorker ::
  (HasPulsar m, HasMinIO m, HasEngine m) =>
  WorkerOptions ->
  m (Either WorkerError WorkerStepResult)
runWorker options = do
  subscribed <-
    pulsarSubscribe
      (workerInputTopic options)
      (workerSubscriptionName options)
      (workerSubscriptionMode options)
  case subscribed of
    Left err -> pure (Left (WorkerPulsarError err))
    Right subscription -> workerStep options subscription

workerStep ::
  (HasPulsar m, HasMinIO m, HasEngine m) =>
  WorkerOptions ->
  Subscription ->
  m (Either WorkerError WorkerStepResult)
workerStep options subscription = do
  consumed <- pulsarConsume subscription
  case consumed of
    Left err -> pure (Left (WorkerPulsarError err))
    Right Nothing -> pure (Right WorkerNoMessage)
    Right (Just message) ->
      case WorkerWire.decodeOrchestratorToWorker (pulsarMessagePayload message) of
        Left err -> nack message (WorkerWireError err)
        Right batch ->
          case NonEmpty.nonEmpty (WorkerWire.orchestratorEvents batch) of
            Nothing -> nack message (WorkerEmptyBatch (WorkerWire.orchestratorBatchId batch))
            Just events -> do
              materializedRequests <- traverse eventToEngineRequest events
              case sequenceA materializedRequests of
                Left err -> nack message err
                Right engineRequests -> do
                  engineResults <- engineCall engineRequests
                  case buildWorkerResults options (WorkerWire.orchestratorBatchId batch) events engineResults of
                    Left err -> nack message err
                    Right results -> do
                      published <- traverse (publishWorkerResult options) results
                      case firstLeft published of
                        Just err -> nack message err
                        Nothing -> ack message (WorkerProcessed (WorkerWire.orchestratorBatchId batch) (length results))
  where
    ack message result = do
      acknowledged <- pulsarAcknowledge subscription (pulsarMessageId message)
      pure case acknowledged of
        Left err -> Left (WorkerPulsarError err)
        Right () -> Right result
    nack message err = do
      nacked <- pulsarNegativeAcknowledge subscription (pulsarMessageId message)
      pure case nacked of
        Left pulsarErr -> Left (WorkerPulsarError pulsarErr)
        Right () -> Left err

eventToEngineRequest ::
  (HasMinIO m) =>
  Workflow.WorkflowEvent ->
  m (Either WorkerError EngineRequest)
eventToEngineRequest event =
  case Workflow.workflowPayload event of
    Workflow.WireInline bytes ->
      pure (Right (engineRequest bytes))
    Workflow.WireObjectRef ref -> do
      materialized <- readWorkerObject ref
      pure (engineRequest <$> materialized)
  where
    engineRequest bytes =
      EngineRequest
        { engineRequestId = Workflow.unEventId (Workflow.workflowEventId event),
          engineRequestPayload = bytes
        }

readWorkerObject ::
  (HasMinIO m) =>
  Workflow.ObjectRef ->
  m (Either WorkerError ByteString)
readWorkerObject ref = do
  result <-
    readBlob
      ObjectRef
        { objectRefBucket = BucketName (Workflow.objectRefBucket ref),
          objectRefKey = ObjectKey (Workflow.objectRefKey ref)
        }
  pure case result of
    Left err -> Left (WorkerMinIOError ref err)
    Right bytes -> Right bytes

buildWorkerResults ::
  WorkerOptions ->
  Text ->
  NonEmpty Workflow.WorkflowEvent ->
  NonEmpty (Either EngineError EngineResponse) ->
  Either WorkerError [WorkerWire.WorkerResult]
buildWorkerResults options batchId events engineResults
  | NonEmpty.length events /= NonEmpty.length engineResults =
      Left (WorkerEngineResultCountMismatch (NonEmpty.length events) (NonEmpty.length engineResults))
  | otherwise =
      Right
        [ workerResultFor outcome event
        | (event, outcome) <- zip (NonEmpty.toList events) (NonEmpty.toList engineResults)
        ]
  where
    workerResultFor outcome event =
      case outcome of
        Right response ->
          WorkerWire.WorkerResult
            { WorkerWire.workerRequestId = engineResponseRequestId response,
              WorkerWire.workerBatchId = batchId,
              WorkerWire.workerOutcome =
                WorkerWire.WorkerSuccess
                  WorkerWire.SuccessPayload
                    { WorkerWire.successResultPayload = engineResponsePayload response,
                      WorkerWire.successPayloadType = workerResultPayloadType options,
                      WorkerWire.successOutputObject = Nothing
                    }
            }
        Left err ->
          WorkerWire.WorkerResult
            { WorkerWire.workerRequestId = engineErrorRequestIdOr event err,
              WorkerWire.workerBatchId = batchId,
              WorkerWire.workerOutcome =
                WorkerWire.WorkerFailure
                  WorkerWire.FailurePayload
                    { WorkerWire.failureReason = engineErrorText err,
                      WorkerWire.failureAttempt = 0
                    }
            }

publishWorkerResult ::
  (HasPulsar m) =>
  WorkerOptions ->
  WorkerWire.WorkerResult ->
  m (Either WorkerError MessageId)
publishWorkerResult options result = do
  published <-
    pulsarPublish
      (workerResultTopic options)
      ProducerMessage
        { producerKey = Just (WorkerWire.workerRequestId result),
          producerPayload = WorkerWire.encodeWorkerResult result,
          producerProperties = Map.empty,
          producerDeduplicationKey =
            Just (WorkerWire.workerBatchId result <> ":" <> WorkerWire.workerRequestId result)
        }
  pure case published of
    Left err -> Left (WorkerPulsarError err)
    Right messageId -> Right messageId

engineErrorRequestIdOr :: Workflow.WorkflowEvent -> EngineError -> Text
engineErrorRequestIdOr event err =
  case err of
    EngineRequestFailed requestId _ -> requestId
    EngineBatchFailed _ -> Workflow.unEventId (Workflow.workflowEventId event)
    EngineSubprocessUnavailable requestId _ -> requestId
    EngineSubprocessFailed requestId _ _ -> requestId
    EngineTimedOut requestId _ -> requestId

engineErrorText :: EngineError -> Text
engineErrorText err =
  case err of
    EngineRequestFailed _ detail -> detail
    EngineBatchFailed detail -> detail
    EngineSubprocessUnavailable _ detail -> detail
    EngineSubprocessFailed _ exitCode detail -> Text.pack (show exitCode) <> ": " <> detail
    EngineTimedOut requestId micros ->
      "request " <> requestId <> " timed out after " <> Text.pack (show micros) <> "us"

firstLeft :: [Either err ok] -> Maybe err
firstLeft items =
  case filter isLeft items of
    Left err : _ -> Just err
    _ -> Nothing
  where
    isLeft value =
      case value of
        Left _ -> True
        Right _ -> False
