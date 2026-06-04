module Daemon.Topology.BatchedFanIn where

import Daemon.Batching.Hooks (BatchingHooks)
import Daemon.Config.LiveConfig (BatchingPolicy, SchedulerPolicy)
import qualified Daemon.Topology.FanIn as FanIn
import Daemon.Topology.Types

data BatchedFanIn req = BatchedFanIn
  { batchedFanInUnderlying :: !FanIn.FanIn,
    batchedFanInBatchingPolicy :: !BatchingPolicy,
    batchedFanInSchedulerPolicy :: !SchedulerPolicy,
    batchedFanInHooks :: !(BatchingHooks req)
  }

batchedFanIn ::
  FanIn.FanIn ->
  BatchingPolicy ->
  SchedulerPolicy ->
  BatchingHooks req ->
  BatchedFanIn req
batchedFanIn underlying batchingPolicy schedulerPolicy hooks =
  BatchedFanIn
    { batchedFanInUnderlying = underlying,
      batchedFanInBatchingPolicy = batchingPolicy,
      batchedFanInSchedulerPolicy = schedulerPolicy,
      batchedFanInHooks = hooks
    }

toTopology :: BatchedFanIn req -> Topology
toTopology =
  FanIn.toTopology . batchedFanInUnderlying
