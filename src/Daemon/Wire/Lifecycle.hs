module Daemon.Wire.Lifecycle where

import Data.ProtoLens (defMessage)
import Data.Text (Text)
import Data.Time (UTCTime)
import qualified Daemon.Proto.Lifecycle as Proto
import Daemon.Wire.Workflow (unixNanosToUTCTime, utcTimeToUnixNanos)
import Lens.Family2 ((&), (.~), (^.))

data LifecyclePhase
  = LifecyclePhaseUnspecified
  | LifecycleLoad
  | LifecyclePrereq
  | LifecycleAcquire
  | LifecycleReady
  | LifecycleServe
  | LifecycleDrain
  | LifecycleExit
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data ReadinessReport = ReadinessReport
  { readinessPhase :: !LifecyclePhase,
    readinessPhaseDetail :: !Text,
    readinessHeartbeatAt :: !UTCTime,
    readinessReady :: !Bool
  }
  deriving stock (Eq, Ord, Show)

toProto :: ReadinessReport -> Proto.ReadinessReport
toProto report =
  defMessage
    & Proto.phase .~ lifecyclePhaseToProto (readinessPhase report)
    & Proto.phaseDetail .~ readinessPhaseDetail report
    & Proto.heartbeatAt .~ utcTimeToUnixNanos (readinessHeartbeatAt report)
    & Proto.ready .~ readinessReady report

fromProto :: Proto.ReadinessReport -> Either Void ReadinessReport
fromProto report =
  Right
    ReadinessReport
      { readinessPhase = lifecyclePhaseFromProto (report ^. Proto.phase),
        readinessPhaseDetail = report ^. Proto.phaseDetail,
        readinessHeartbeatAt = unixNanosToUTCTime (report ^. Proto.heartbeatAt),
        readinessReady = report ^. Proto.ready
      }

data Void
  deriving stock (Eq, Show)

lifecyclePhaseToProto :: LifecyclePhase -> Proto.LifecyclePhase
lifecyclePhaseToProto phaseValue =
  case phaseValue of
    LifecyclePhaseUnspecified -> Proto.LIFECYCLE_PHASE_UNSPECIFIED
    LifecycleLoad -> Proto.LIFECYCLE_PHASE_LOAD
    LifecyclePrereq -> Proto.LIFECYCLE_PHASE_PREREQ
    LifecycleAcquire -> Proto.LIFECYCLE_PHASE_ACQUIRE
    LifecycleReady -> Proto.LIFECYCLE_PHASE_READY
    LifecycleServe -> Proto.LIFECYCLE_PHASE_SERVE
    LifecycleDrain -> Proto.LIFECYCLE_PHASE_DRAIN
    LifecycleExit -> Proto.LIFECYCLE_PHASE_EXIT

lifecyclePhaseFromProto :: Proto.LifecyclePhase -> LifecyclePhase
lifecyclePhaseFromProto phaseValue =
  case phaseValue of
    Proto.LIFECYCLE_PHASE_UNSPECIFIED -> LifecyclePhaseUnspecified
    Proto.LIFECYCLE_PHASE_LOAD -> LifecycleLoad
    Proto.LIFECYCLE_PHASE_PREREQ -> LifecyclePrereq
    Proto.LIFECYCLE_PHASE_ACQUIRE -> LifecycleAcquire
    Proto.LIFECYCLE_PHASE_READY -> LifecycleReady
    Proto.LIFECYCLE_PHASE_SERVE -> LifecycleServe
    Proto.LIFECYCLE_PHASE_DRAIN -> LifecycleDrain
    Proto.LIFECYCLE_PHASE_EXIT -> LifecycleExit
    _ -> LifecyclePhaseUnspecified
