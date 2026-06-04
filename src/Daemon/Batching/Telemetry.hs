module Daemon.Batching.Telemetry where

import Data.Foldable (traverse_)
import Data.Time (NominalDiffTime)
import Daemon.Config.LiveConfig (BackpressureMode, BucketKey)
import qualified Daemon.Wire.Workflow as Workflow

data BatcherTelemetry
  = BatcherBatchFlushed !BucketKey !Int !NominalDiffTime !Bool
  | BatcherQueueDepth !BucketKey !Int
  | BatcherSchedulerDeficit !BucketKey !Double
  | BatcherBackpressureEvent !BackpressureMode !Int
  | BatcherDroppedExpired !BucketKey !Workflow.EventId
  deriving stock (Eq, Show)

emitBatcherTelemetry ::
  (Monad m) =>
  (BatcherTelemetry -> m ()) ->
  [BatcherTelemetry] ->
  m ()
emitBatcherTelemetry emit =
  traverse_ emit
