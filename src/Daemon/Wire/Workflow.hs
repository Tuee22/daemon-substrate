module Daemon.Wire.Workflow where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.ProtoLens (defMessage)
import Data.ProtoLens.Encoding (decodeMessage, encodeMessage)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import qualified Daemon.Proto.Workflow as Proto
import Lens.Family2 ((&), (.~), (^.))

newtype EventId = EventId {unEventId :: Text}
  deriving stock (Eq, Ord, Show)

newtype PayloadTypeUrl = PayloadTypeUrl {unPayloadTypeUrl :: Text}
  deriving stock (Eq, Ord, Show)

data ObjectRef = ObjectRef
  { objectRefBucket :: !Text,
    objectRefKey :: !Text,
    objectRefETag :: !Text
  }
  deriving stock (Eq, Ord, Show)

data WorkflowKind
  = WorkflowKindUnspecified
  | WorkflowTraining
  | WorkflowInference
  | WorkflowEvaluation
  | WorkflowIngestion
  | WorkflowAudit
  | WorkflowCustom
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data WirePayload
  = WireInline !ByteString
  | WireObjectRef !ObjectRef
  deriving stock (Eq, Ord, Show)

data WorkflowEvent = WorkflowEvent
  { workflowEventId :: !EventId,
    workflowProducedAt :: !UTCTime,
    workflowDeadlineAt :: !(Maybe UTCTime),
    workflowKind :: !WorkflowKind,
    workflowPayloadType :: !PayloadTypeUrl,
    workflowPayload :: !WirePayload
  }
  deriving stock (Eq, Ord, Show)

data WorkflowWireError
  = WorkflowMissingPayload
  | WorkflowDecodeError !Text
  deriving stock (Eq, Show)

encodeWorkflowEvent :: WorkflowEvent -> ByteString
encodeWorkflowEvent =
  encodeMessage . toProto

decodeWorkflowEvent :: ByteString -> Either WorkflowWireError WorkflowEvent
decodeWorkflowEvent bytes =
  case decodeMessage bytes of
    Left err -> Left (WorkflowDecodeError (Text.pack err))
    Right proto -> fromProto proto

toProto :: WorkflowEvent -> Proto.WorkflowEvent
toProto event =
  setPayload (workflowPayload event) base
  where
    base =
      defMessage
        & Proto.eventId .~ unEventId (workflowEventId event)
        & Proto.producedAt .~ utcTimeToUnixNanos (workflowProducedAt event)
        & Proto.deadlineAt .~ maybe 0 utcTimeToUnixNanos (workflowDeadlineAt event)
        & Proto.workflowKind .~ workflowKindToProto (workflowKind event)
        & Proto.payloadType .~ unPayloadTypeUrl (workflowPayloadType event)
    setPayload payload message =
      case payload of
        WireInline bytes ->
          message & Proto.inlineBytes .~ bytes
        WireObjectRef ref ->
          message & Proto.objectRef .~ objectRefToProto ref

fromProto :: Proto.WorkflowEvent -> Either WorkflowWireError WorkflowEvent
fromProto event = do
  payload <-
    case event ^. Proto.maybe'inlineBytes of
      Just bytes ->
        Right (WireInline bytes)
      Nothing ->
        case event ^. Proto.maybe'objectRef of
          Just ref -> Right (WireObjectRef (objectRefFromProto ref))
          Nothing -> Left WorkflowMissingPayload
  Right
    WorkflowEvent
      { workflowEventId = EventId (event ^. Proto.eventId),
        workflowProducedAt = unixNanosToUTCTime (event ^. Proto.producedAt),
        workflowDeadlineAt =
          case event ^. Proto.deadlineAt of
            0 -> Nothing
            nanos -> Just (unixNanosToUTCTime nanos),
        workflowKind = workflowKindFromProto (event ^. Proto.workflowKind),
        workflowPayloadType = PayloadTypeUrl (event ^. Proto.payloadType),
        workflowPayload = payload
      }

objectRefToProto :: ObjectRef -> Proto.ObjectRef
objectRefToProto ref =
  defMessage
    & Proto.bucket .~ objectRefBucket ref
    & Proto.key .~ objectRefKey ref
    & Proto.etag .~ objectRefETag ref

objectRefFromProto :: Proto.ObjectRef -> ObjectRef
objectRefFromProto ref =
  ObjectRef
    { objectRefBucket = ref ^. Proto.bucket,
      objectRefKey = ref ^. Proto.key,
      objectRefETag = ref ^. Proto.etag
    }

workflowKindToProto :: WorkflowKind -> Proto.WorkflowKind
workflowKindToProto kindValue =
  case kindValue of
    WorkflowKindUnspecified -> Proto.WORKFLOW_KIND_UNSPECIFIED
    WorkflowTraining -> Proto.WORKFLOW_KIND_TRAINING
    WorkflowInference -> Proto.WORKFLOW_KIND_INFERENCE
    WorkflowEvaluation -> Proto.WORKFLOW_KIND_EVALUATION
    WorkflowIngestion -> Proto.WORKFLOW_KIND_INGESTION
    WorkflowAudit -> Proto.WORKFLOW_KIND_AUDIT
    WorkflowCustom -> Proto.WORKFLOW_KIND_CUSTOM

workflowKindFromProto :: Proto.WorkflowKind -> WorkflowKind
workflowKindFromProto kindValue =
  case kindValue of
    Proto.WORKFLOW_KIND_UNSPECIFIED -> WorkflowKindUnspecified
    Proto.WORKFLOW_KIND_TRAINING -> WorkflowTraining
    Proto.WORKFLOW_KIND_INFERENCE -> WorkflowInference
    Proto.WORKFLOW_KIND_EVALUATION -> WorkflowEvaluation
    Proto.WORKFLOW_KIND_INGESTION -> WorkflowIngestion
    Proto.WORKFLOW_KIND_AUDIT -> WorkflowAudit
    Proto.WORKFLOW_KIND_CUSTOM -> WorkflowCustom
    _ -> WorkflowKindUnspecified

utcTimeToUnixNanos :: UTCTime -> Int64
utcTimeToUnixNanos =
  round . (* 1000000000) . utcTimeToPOSIXSeconds

unixNanosToUTCTime :: Int64 -> UTCTime
unixNanosToUTCTime nanos =
  posixSecondsToUTCTime (fromRational (toRational nanos / 1000000000))
