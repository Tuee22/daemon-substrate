module Daemon.Topology.BatchedFanOut where

import Daemon.Batching.Hooks (BatchingHooks)
import Daemon.Config.LiveConfig (BatchingPolicy, SchedulerPolicy)
import qualified Daemon.Topology.FanOut as FanOut
import Daemon.Topology.Types

data BatchedFanOut req = BatchedFanOut
  { batchedFanOutUnderlying :: !FanOut.FanOut,
    batchedFanOutBatchingPolicy :: !BatchingPolicy,
    batchedFanOutSchedulerPolicy :: !SchedulerPolicy,
    batchedFanOutHooks :: !(BatchingHooks req)
  }

batchedFanOut ::
  FanOut.FanOut ->
  BatchingPolicy ->
  SchedulerPolicy ->
  BatchingHooks req ->
  BatchedFanOut req
batchedFanOut underlying batchingPolicy schedulerPolicy hooks =
  BatchedFanOut
    { batchedFanOutUnderlying = underlying,
      batchedFanOutBatchingPolicy = batchingPolicy,
      batchedFanOutSchedulerPolicy = schedulerPolicy,
      batchedFanOutHooks = hooks
    }

toTopology :: BatchedFanOut req -> Topology
toTopology =
  FanOut.toTopology . batchedFanOutUnderlying
