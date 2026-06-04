module Daemon.Wire.Control where

import Data.ProtoLens (defMessage)
import Data.Time (UTCTime)
import qualified Daemon.Proto.Control as Proto
import Daemon.Wire.Workflow (unixNanosToUTCTime, utcTimeToUnixNanos)
import Lens.Family2 ((&), (.~), (^.))

newtype Drain = Drain
  { drainDeadline :: UTCTime
  }
  deriving stock (Eq, Ord, Show)

data Reload = Reload
  deriving stock (Eq, Ord, Show)

data ControlEnvelope
  = ControlDrain !Drain
  | ControlReload !Reload
  deriving stock (Eq, Ord, Show)

data ControlWireError
  = ControlMissingCommand
  deriving stock (Eq, Show)

toProto :: ControlEnvelope -> Proto.ControlEnvelope
toProto command =
  case command of
    ControlDrain drain ->
      defMessage & Proto.drain .~ drainToProto drain
    ControlReload Reload ->
      defMessage & Proto.reload .~ defMessage

fromProto :: Proto.ControlEnvelope -> Either ControlWireError ControlEnvelope
fromProto command =
  case command ^. Proto.maybe'drain of
    Just drain ->
      Right (ControlDrain (drainFromProto drain))
    Nothing ->
      case command ^. Proto.maybe'reload of
        Just _ -> Right (ControlReload Reload)
        Nothing -> Left ControlMissingCommand

drainToProto :: Drain -> Proto.Drain
drainToProto drain =
  defMessage
    & Proto.deadlineUnixNanos .~ utcTimeToUnixNanos (drainDeadline drain)

drainFromProto :: Proto.Drain -> Drain
drainFromProto drain =
  Drain
    { drainDeadline = unixNanosToUTCTime (drain ^. Proto.deadlineUnixNanos)
    }
