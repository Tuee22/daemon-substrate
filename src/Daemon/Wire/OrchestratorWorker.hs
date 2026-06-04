module Daemon.Wire.OrchestratorWorker where

import Data.ByteString (ByteString)
import Data.ProtoLens (defMessage)
import Data.ProtoLens.Encoding (decodeMessage, encodeMessage)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Daemon.Proto.OrchestratorWorker as Proto
import qualified Daemon.Wire.Workflow as Workflow
import Lens.Family2 ((&), (.~), (^.))

data OrchestratorToWorker = OrchestratorToWorker
  { orchestratorBatchId :: !Text,
    orchestratorCohort :: !Text,
    orchestratorEvents :: ![Workflow.WorkflowEvent]
  }
  deriving stock (Eq, Ord, Show)

data SuccessPayload = SuccessPayload
  { successResultPayload :: !ByteString,
    successPayloadType :: !Text,
    successOutputObject :: !(Maybe Workflow.ObjectRef)
  }
  deriving stock (Eq, Ord, Show)

data FailurePayload = FailurePayload
  { failureReason :: !Text,
    failureAttempt :: !Int
  }
  deriving stock (Eq, Ord, Show)

data WorkerOutcome
  = WorkerSuccess !SuccessPayload
  | WorkerFailure !FailurePayload
  deriving stock (Eq, Ord, Show)

data WorkerResult = WorkerResult
  { workerRequestId :: !Text,
    workerBatchId :: !Text,
    workerOutcome :: !WorkerOutcome
  }
  deriving stock (Eq, Ord, Show)

data OrchestratorWorkerWireError
  = OrchestratorWorkflowError !Workflow.WorkflowWireError
  | WorkerMissingOutcome
  | OrchestratorWorkerDecodeError !Text
  deriving stock (Eq, Show)

encodeOrchestratorToWorker :: OrchestratorToWorker -> ByteString
encodeOrchestratorToWorker =
  encodeMessage . toProtoOrchestratorToWorker

decodeOrchestratorToWorker :: ByteString -> Either OrchestratorWorkerWireError OrchestratorToWorker
decodeOrchestratorToWorker bytes =
  case decodeMessage bytes of
    Left err -> Left (OrchestratorWorkerDecodeError (Text.pack err))
    Right proto -> fromProtoOrchestratorToWorker proto

encodeWorkerResult :: WorkerResult -> ByteString
encodeWorkerResult =
  encodeMessage . toProtoWorkerResult

decodeWorkerResult :: ByteString -> Either OrchestratorWorkerWireError WorkerResult
decodeWorkerResult bytes =
  case decodeMessage bytes of
    Left err -> Left (OrchestratorWorkerDecodeError (Text.pack err))
    Right proto -> fromProtoWorkerResult proto

toProtoOrchestratorToWorker :: OrchestratorToWorker -> Proto.OrchestratorToWorker
toProtoOrchestratorToWorker batch =
  defMessage
    & Proto.batchId .~ orchestratorBatchId batch
    & Proto.cohort .~ orchestratorCohort batch
    & Proto.events .~ fmap Workflow.toProto (orchestratorEvents batch)

fromProtoOrchestratorToWorker ::
  Proto.OrchestratorToWorker ->
  Either OrchestratorWorkerWireError OrchestratorToWorker
fromProtoOrchestratorToWorker batch = do
  events <-
    traverse
      (either (Left . OrchestratorWorkflowError) Right . Workflow.fromProto)
      (batch ^. Proto.events)
  Right
    OrchestratorToWorker
      { orchestratorBatchId = batch ^. Proto.batchId,
        orchestratorCohort = batch ^. Proto.cohort,
        orchestratorEvents = events
      }

toProtoWorkerResult :: WorkerResult -> Proto.WorkerResult
toProtoWorkerResult result =
  setOutcome (workerOutcome result) base
  where
    base =
      defMessage
        & Proto.requestId .~ workerRequestId result
        & Proto.batchId .~ workerBatchId result
    setOutcome outcome message =
      case outcome of
        WorkerSuccess success ->
          message & Proto.success .~ successToProto success
        WorkerFailure failure ->
          message & Proto.failure .~ failureToProto failure

fromProtoWorkerResult ::
  Proto.WorkerResult ->
  Either OrchestratorWorkerWireError WorkerResult
fromProtoWorkerResult result = do
  outcome <-
    case result ^. Proto.maybe'success of
      Just success ->
        Right (WorkerSuccess (successFromProto success))
      Nothing ->
        case result ^. Proto.maybe'failure of
          Just failure -> Right (WorkerFailure (failureFromProto failure))
          Nothing -> Left WorkerMissingOutcome
  Right
    WorkerResult
      { workerRequestId = result ^. Proto.requestId,
        workerBatchId = result ^. Proto.batchId,
        workerOutcome = outcome
      }

successToProto :: SuccessPayload -> Proto.SuccessPayload
successToProto success =
  maybe id (\ref message -> message & Proto.outputObject .~ Workflow.objectRefToProto ref) (successOutputObject success) base
  where
    base =
      defMessage
        & Proto.resultPayload .~ successResultPayload success
        & Proto.payloadType .~ successPayloadType success

successFromProto :: Proto.SuccessPayload -> SuccessPayload
successFromProto success =
  SuccessPayload
    { successResultPayload = success ^. Proto.resultPayload,
      successPayloadType = success ^. Proto.payloadType,
      successOutputObject = Workflow.objectRefFromProto <$> success ^. Proto.maybe'outputObject
    }

failureToProto :: FailurePayload -> Proto.FailurePayload
failureToProto failure =
  defMessage
    & Proto.reason .~ failureReason failure
    & Proto.attempt .~ fromIntegral (failureAttempt failure)

failureFromProto :: Proto.FailurePayload -> FailurePayload
failureFromProto failure =
  FailurePayload
    { failureReason = failure ^. Proto.reason,
      failureAttempt = fromIntegral (failure ^. Proto.attempt)
    }
