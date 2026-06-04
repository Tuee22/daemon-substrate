module Daemon.Batching.Batcher where

import Data.List (partition)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime, diffUTCTime)
import Daemon.Batching.Hooks
import Daemon.Batching.Scheduler
import Daemon.Batching.Telemetry
import Daemon.Config.LiveConfig
  ( BackpressureMode (..),
    BatchingPolicy (..),
    BucketKey,
    FlushStrategy (..),
    SchedulerPolicy (..),
  )
import qualified Daemon.Wire.Workflow as Workflow

data BatcherRequest req = BatcherRequest
  { batcherRequestEvent :: !Workflow.WorkflowEvent,
    batcherRequestPayload :: !req,
    batcherRequestEnqueuedAt :: !UTCTime
  }
  deriving stock (Eq, Show)

data BatcherBatch req = BatcherBatch
  { batcherBatchBucket :: !BucketKey,
    batcherBatchRequests :: !(NonEmpty (BatcherRequest req)),
    batcherBatchDispatchedAt :: !UTCTime,
    batcherBatchDeadlinePreempted :: !Bool
  }
  deriving stock (Eq, Show)

data BackpressureDecision
  = BackpressureAccept
  | BackpressureBlock
  | BackpressureShedLoad
  | BackpressureRedirect !(Maybe Text)
  deriving stock (Eq, Show)

data BatcherEnqueueResult req
  = BatcherEnqueued !(Batcher req)
  | BatcherBackpressured !BackpressureDecision !(Batcher req)

data Batcher req = Batcher
  { batcherBatchingPolicy :: !BatchingPolicy,
    batcherSchedulerPolicy :: !SchedulerPolicy,
    batcherHooks :: !(BatchingHooks req),
    batcherQueues :: !(Map.Map BucketKey [BatcherRequest req]),
    batcherInFlightCount :: !Int,
    batcherSchedulerState :: !SchedulerState,
    batcherTelemetry :: ![BatcherTelemetry]
  }

newBatcher ::
  BatchingPolicy ->
  SchedulerPolicy ->
  BatchingHooks req ->
  Batcher req
newBatcher batchingPolicy schedulerPolicy hooks =
  Batcher
    { batcherBatchingPolicy = batchingPolicy,
      batcherSchedulerPolicy = schedulerPolicy,
      batcherHooks = hooks,
      batcherQueues = Map.empty,
      batcherInFlightCount = 0,
      batcherSchedulerState = initialSchedulerState,
      batcherTelemetry = []
    }

enqueueRequest ::
  UTCTime ->
  Workflow.WorkflowEvent ->
  req ->
  Batcher req ->
  BatcherEnqueueResult req
enqueueRequest enqueuedAt event payload =
  enqueueBatcherRequest
    BatcherRequest
      { batcherRequestEvent = event,
        batcherRequestPayload = payload,
        batcherRequestEnqueuedAt = enqueuedAt
      }

enqueueBatcherRequest :: BatcherRequest req -> Batcher req -> BatcherEnqueueResult req
enqueueBatcherRequest request batcher =
  case backpressureDecision (batcherBatchingPolicy batcher) (batcherTotalDepth batcher) of
    BackpressureAccept ->
      BatcherEnqueued
        batcher
          { batcherQueues =
              appendRequest
                (requestBucket (batcherHooks batcher) (batcherRequestPayload request))
                request
                (batcherQueues batcher)
          }
    decision ->
      BatcherBackpressured decision (appendTelemetry (BatcherBackpressureEvent mode (batcherTotalDepth batcher)) batcher)
  where
    mode =
      batchingBackpressureMode (batcherBatchingPolicy batcher)

flushReady :: UTCTime -> Batcher req -> (Batcher req, Maybe (BatcherBatch req))
flushReady now batcher0 =
  case selectBucket now schedulerPolicy schedulerState candidateBuckets of
    Nothing -> (batcher, Nothing)
    Just choice ->
      case Map.lookup (schedulerChoiceBucket choice) (batcherQueues batcher) >>= takeBatch hooks maxBatchSize of
        Nothing -> (batcher, Nothing)
        Just (requests, remaining) ->
          let bucket = schedulerChoiceBucket choice
              flushedSize = NonEmpty.length requests
              waitTime =
                diffUTCTime now (batcherRequestEnqueuedAt (NonEmpty.head requests))
              afterQueues =
                replaceQueue bucket remaining (batcherQueues batcher)
              afterScheduler =
                recordService
                  schedulerPolicy
                  bucket
                  flushedSize
                  (schedulerChoiceState choice)
              batch =
                BatcherBatch
                  { batcherBatchBucket = bucket,
                    batcherBatchRequests = requests,
                    batcherBatchDispatchedAt = now,
                    batcherBatchDeadlinePreempted = schedulerChoicePreempted choice
                  }
              telemetry =
                [ BatcherBatchFlushed bucket flushedSize waitTime (schedulerChoicePreempted choice),
                  BatcherQueueDepth bucket (length remaining),
                  BatcherSchedulerDeficit bucket (schedulerBucketDeficit afterScheduler bucket)
                ]
           in ( batcher
                  { batcherQueues = afterQueues,
                    batcherInFlightCount = batcherInFlightCount batcher + flushedSize,
                    batcherSchedulerState = afterScheduler,
                    batcherTelemetry = batcherTelemetry batcher <> telemetry
                  },
                Just batch
              )
  where
    batcher =
      dropExpiredRequests now batcher0
    batchingPolicy =
      batcherBatchingPolicy batcher
    schedulerPolicy =
      batcherSchedulerPolicy batcher
    schedulerState =
      batcherSchedulerState batcher
    hooks =
      batcherHooks batcher
    maxBatchSize =
      positiveBatchSize (batchingMaxBatchSize batchingPolicy)
    candidateBuckets =
      mapMaybe
        (flushableBucket now batchingPolicy schedulerPolicy)
        (Map.toList (batcherQueues batcher))

completeBatch :: BatcherBatch req -> Batcher req -> Batcher req
completeBatch batch batcher =
  batcher
    { batcherInFlightCount =
        max 0 (batcherInFlightCount batcher - NonEmpty.length (batcherBatchRequests batch))
    }

batcherQueuedCount :: Batcher req -> Int
batcherQueuedCount =
  foldl' (\total requests -> total + length requests) 0 . batcherQueues

batcherTotalDepth :: Batcher req -> Int
batcherTotalDepth batcher =
  batcherQueuedCount batcher + batcherInFlightCount batcher

batcherBatchSize :: BatcherBatch req -> Int
batcherBatchSize =
  NonEmpty.length . batcherBatchRequests

drainBatcherTelemetry :: Batcher req -> (Batcher req, [BatcherTelemetry])
drainBatcherTelemetry batcher =
  (batcher {batcherTelemetry = []}, batcherTelemetry batcher)

backpressureDecision :: BatchingPolicy -> Int -> BackpressureDecision
backpressureDecision policy currentDepth
  | currentDepth < batchingMaxInFlightBuffer policy = BackpressureAccept
  | otherwise =
      case batchingBackpressureMode policy of
        Block -> BackpressureBlock
        ShedLoad -> BackpressureShedLoad
        Redirect -> BackpressureRedirect (batchingSecondaryWorker policy)

dropExpiredRequests :: UTCTime -> Batcher req -> Batcher req
dropExpiredRequests now batcher =
  batcher
    { batcherQueues = keptQueues,
      batcherTelemetry = batcherTelemetry batcher <> droppedTelemetry
    }
  where
    (keptQueues, droppedTelemetry) =
      Map.foldlWithKey' dropExpired (Map.empty, []) (batcherQueues batcher)
    dropExpired (queues, telemetry) bucket requests =
      let (expired, live) = partition (requestExpired now) requests
          nextQueues = replaceQueue bucket live queues
          nextTelemetry =
            telemetry
              <> [ BatcherDroppedExpired bucket (Workflow.workflowEventId (batcherRequestEvent request))
                   | request <- expired
                 ]
       in (nextQueues, nextTelemetry)

flushableBucket ::
  UTCTime ->
  BatchingPolicy ->
  SchedulerPolicy ->
  (BucketKey, [BatcherRequest req]) ->
  Maybe SchedulerBucket
flushableBucket now batchingPolicy schedulerPolicy (bucket, requests)
  | null requests = Nothing
  | shouldFlushBucket now batchingPolicy schedulerPolicy requests =
      Just
        SchedulerBucket
          { schedulerBucketKey = bucket,
            schedulerBucketDepth = length requests,
            schedulerBucketEarliestDeadline = earliestDeadline requests
          }
  | otherwise = Nothing

shouldFlushBucket ::
  UTCTime ->
  BatchingPolicy ->
  SchedulerPolicy ->
  [BatcherRequest req] ->
  Bool
shouldFlushBucket now batchingPolicy schedulerPolicy requests =
  sizeHit || deadlineHit || strategyHit
  where
    queuedCount =
      length requests
    sizeHit =
      queuedCount >= positiveBatchSize (batchingMaxBatchSize batchingPolicy)
    deadlineHit =
      any (requestWithinDeadline now schedulerPolicy) requests
    strategyHit =
      case batchingFlushStrategy batchingPolicy of
        MaxFillOrTimeout -> waitHit
        AdaptiveLatencyAware -> waitHit
        WindowedFixed -> False
        DeadlineAware -> waitHit
    waitHit =
      queuedCount >= positiveBatchSize (batchingMinBatchSize batchingPolicy)
        && oldestWait >= batchingMaxWaitWindow batchingPolicy
    oldestWait =
      case requests of
        first : _ -> diffUTCTime now (batcherRequestEnqueuedAt first)
        [] -> 0

takeBatch ::
  BatchingHooks req ->
  Int ->
  [BatcherRequest req] ->
  Maybe (NonEmpty (BatcherRequest req), [BatcherRequest req])
takeBatch hooks limit requests =
  case requests of
    [] -> Nothing
    first : rest ->
      let (selected, remaining) = go [first] rest
       in case nonEmptyRequests selected of
            Nothing -> Nothing
            Just nonEmptySelected -> Just (nonEmptySelected, remaining)
  where
    go selected remaining
      | length selected >= limit = (selected, remaining)
      | otherwise =
          case remaining of
            [] -> (selected, [])
            next : rest
              | canJoinBatch hooks (selectedPayloads selected) (batcherRequestPayload next) ->
                  go (selected <> [next]) rest
              | otherwise -> (selected, remaining)
    selectedPayloads selected =
      case fmap batcherRequestPayload selected of
        firstPayload : remainingPayloads -> firstPayload :| remainingPayloads
        [] -> error "takeBatch selectedPayloads called with empty selection"

nonEmptyRequests :: [BatcherRequest req] -> Maybe (NonEmpty (BatcherRequest req))
nonEmptyRequests requests =
  case requests of
    [] -> Nothing
    first : rest -> Just (first :| rest)

appendRequest ::
  BucketKey ->
  BatcherRequest req ->
  Map.Map BucketKey [BatcherRequest req] ->
  Map.Map BucketKey [BatcherRequest req]
appendRequest bucket request =
  Map.alter (Just . maybe [request] (<> [request])) bucket

replaceQueue ::
  BucketKey ->
  [BatcherRequest req] ->
  Map.Map BucketKey [BatcherRequest req] ->
  Map.Map BucketKey [BatcherRequest req]
replaceQueue bucket requests
  | null requests = Map.delete bucket
  | otherwise = Map.insert bucket requests

appendTelemetry :: BatcherTelemetry -> Batcher req -> Batcher req
appendTelemetry telemetry batcher =
  batcher {batcherTelemetry = batcherTelemetry batcher <> [telemetry]}

requestExpired :: UTCTime -> BatcherRequest req -> Bool
requestExpired now request =
  case Workflow.workflowDeadlineAt (batcherRequestEvent request) of
    Just deadline -> deadline <= now
    Nothing -> False

requestWithinDeadline :: UTCTime -> SchedulerPolicy -> BatcherRequest req -> Bool
requestWithinDeadline now policy request =
  case Workflow.workflowDeadlineAt (batcherRequestEvent request) of
    Just deadline -> deadline <= addUTCTime (schedulerDeadlinePreemptionEpsilon policy) now
    Nothing -> False

earliestDeadline :: [BatcherRequest req] -> Maybe UTCTime
earliestDeadline =
  foldr minDeadline Nothing . fmap (Workflow.workflowDeadlineAt . batcherRequestEvent)
  where
    minDeadline candidate current =
      case (candidate, current) of
        (Nothing, value) -> value
        (value, Nothing) -> value
        (Just left, Just right) -> Just (min left right)

positiveBatchSize :: Int -> Int
positiveBatchSize =
  max 1
