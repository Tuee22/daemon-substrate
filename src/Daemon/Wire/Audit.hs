module Daemon.Wire.Audit where

import Data.ProtoLens (defMessage)
import Data.Text (Text)
import Data.Time (UTCTime)
import qualified Daemon.Proto.Audit as Proto
import qualified Daemon.Wire.Workflow as Workflow
import Daemon.Wire.Workflow (unixNanosToUTCTime, utcTimeToUnixNanos)
import Lens.Family2 ((&), (.~), (^.))

data ResourceRef = ResourceRef
  { resourceKind :: !Text,
    resourceId :: !Text
  }
  deriving stock (Eq, Ord, Show)

data ReconcileAction
  = ReconcileActionUnspecified
  | ReconcileCreated
  | ReconcileConfigured
  | ReconcileTerminated
  | ReconcileExported
  | ReconcileImported
  | ReconcileDeleted
  | ReconcileNoop
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data AuditEvent = AuditEvent
  { auditResource :: !ResourceRef,
    auditAction :: !ReconcileAction,
    auditObservedAt :: !UTCTime,
    auditActor :: !Text,
    auditSourceRefs :: ![Workflow.ObjectRef],
    auditResultRefs :: ![Workflow.ObjectRef]
  }
  deriving stock (Eq, Ord, Show)

toProto :: AuditEvent -> Proto.AuditEvent
toProto event =
  defMessage
    & Proto.resource .~ resourceRefToProto (auditResource event)
    & Proto.action .~ reconcileActionToProto (auditAction event)
    & Proto.observedAt .~ utcTimeToUnixNanos (auditObservedAt event)
    & Proto.actor .~ auditActor event
    & Proto.sourceRefs .~ fmap Workflow.objectRefToProto (auditSourceRefs event)
    & Proto.resultRefs .~ fmap Workflow.objectRefToProto (auditResultRefs event)

fromProto :: Proto.AuditEvent -> Either Void AuditEvent
fromProto event =
  Right
    AuditEvent
      { auditResource = resourceRefFromProto (event ^. Proto.resource),
        auditAction = reconcileActionFromProto (event ^. Proto.action),
        auditObservedAt = unixNanosToUTCTime (event ^. Proto.observedAt),
        auditActor = event ^. Proto.actor,
        auditSourceRefs = fmap Workflow.objectRefFromProto (event ^. Proto.sourceRefs),
        auditResultRefs = fmap Workflow.objectRefFromProto (event ^. Proto.resultRefs)
      }

data Void
  deriving stock (Eq, Show)

resourceRefToProto :: ResourceRef -> Proto.ResourceRef
resourceRefToProto ref =
  defMessage
    & Proto.kind .~ resourceKind ref
    & Proto.id .~ resourceId ref

resourceRefFromProto :: Proto.ResourceRef -> ResourceRef
resourceRefFromProto ref =
  ResourceRef
    { resourceKind = ref ^. Proto.kind,
      resourceId = ref ^. Proto.id
    }

reconcileActionToProto :: ReconcileAction -> Proto.ReconcileAction
reconcileActionToProto action =
  case action of
    ReconcileActionUnspecified -> Proto.RECONCILE_ACTION_UNSPECIFIED
    ReconcileCreated -> Proto.RECONCILE_ACTION_CREATED
    ReconcileConfigured -> Proto.RECONCILE_ACTION_CONFIGURED
    ReconcileTerminated -> Proto.RECONCILE_ACTION_TERMINATED
    ReconcileExported -> Proto.RECONCILE_ACTION_EXPORTED
    ReconcileImported -> Proto.RECONCILE_ACTION_IMPORTED
    ReconcileDeleted -> Proto.RECONCILE_ACTION_DELETED
    ReconcileNoop -> Proto.RECONCILE_ACTION_NOOP

reconcileActionFromProto :: Proto.ReconcileAction -> ReconcileAction
reconcileActionFromProto action =
  case action of
    Proto.RECONCILE_ACTION_UNSPECIFIED -> ReconcileActionUnspecified
    Proto.RECONCILE_ACTION_CREATED -> ReconcileCreated
    Proto.RECONCILE_ACTION_CONFIGURED -> ReconcileConfigured
    Proto.RECONCILE_ACTION_TERMINATED -> ReconcileTerminated
    Proto.RECONCILE_ACTION_EXPORTED -> ReconcileExported
    Proto.RECONCILE_ACTION_IMPORTED -> ReconcileImported
    Proto.RECONCILE_ACTION_DELETED -> ReconcileDeleted
    Proto.RECONCILE_ACTION_NOOP -> ReconcileNoop
    _ -> ReconcileActionUnspecified
