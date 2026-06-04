module Daemon.Batching.Scheduler where

import Data.List (find, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Ord (Down (..))
import Data.Time (UTCTime, addUTCTime)
import Daemon.Config.LiveConfig (BucketKey, SchedulerPolicy (..), schedulerBucketWeight)

data SchedulerBucket = SchedulerBucket
  { schedulerBucketKey :: !BucketKey,
    schedulerBucketDepth :: !Int,
    schedulerBucketEarliestDeadline :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show)

data SchedulerState = SchedulerState
  { schedulerDeficits :: !(Map.Map BucketKey Double),
    schedulerLastBucket :: !(Maybe BucketKey),
    schedulerDwellUntil :: !(Maybe UTCTime),
    schedulerActiveWeight :: !Double
  }
  deriving stock (Eq, Show)

data SchedulerChoice = SchedulerChoice
  { schedulerChoiceBucket :: !BucketKey,
    schedulerChoicePreempted :: !Bool,
    schedulerChoiceState :: !SchedulerState
  }
  deriving stock (Eq, Show)

initialSchedulerState :: SchedulerState
initialSchedulerState =
  SchedulerState
    { schedulerDeficits = Map.empty,
      schedulerLastBucket = Nothing,
      schedulerDwellUntil = Nothing,
      schedulerActiveWeight = 1
    }

selectBucket ::
  UTCTime ->
  SchedulerPolicy ->
  SchedulerState ->
  [SchedulerBucket] ->
  Maybe SchedulerChoice
selectBucket now policy state buckets =
  case activeBuckets of
    [] -> Nothing
    _ ->
      case preemptedBucket now policy activeBuckets of
        Just bucket ->
          Just
            SchedulerChoice
              { schedulerChoiceBucket = schedulerBucketKey bucket,
                schedulerChoicePreempted = True,
                schedulerChoiceState =
                  setDwell now policy (schedulerBucketKey bucket) (withActiveWeight policy activeBuckets state)
              }
        Nothing ->
          case dwellBucket now state activeBuckets of
            Just bucket ->
              Just
                SchedulerChoice
                  { schedulerChoiceBucket = schedulerBucketKey bucket,
                    schedulerChoicePreempted = False,
                    schedulerChoiceState = withActiveWeight policy activeBuckets state
                  }
            Nothing ->
              let advanced = advanceDeficits policy (withActiveWeight policy activeBuckets state) activeBuckets
                  bucket = highestDeficitBucket advanced activeBuckets
               in Just
                    SchedulerChoice
                      { schedulerChoiceBucket = schedulerBucketKey bucket,
                        schedulerChoicePreempted = False,
                        schedulerChoiceState = setDwell now policy (schedulerBucketKey bucket) advanced
                      }
  where
    activeBuckets =
      filter ((> 0) . schedulerBucketDepth) buckets

recordService ::
  SchedulerPolicy ->
  BucketKey ->
  Int ->
  SchedulerState ->
  SchedulerState
recordService _policy bucket servicedCount state =
  state
    { schedulerDeficits =
        Map.adjust
          (\deficit -> deficit - (fromIntegral servicedCount * schedulerActiveWeight state))
          bucket
          (schedulerDeficits state)
    }

withActiveWeight :: SchedulerPolicy -> [SchedulerBucket] -> SchedulerState -> SchedulerState
withActiveWeight policy buckets state =
  state
    { schedulerActiveWeight =
        sum [positiveWeight policy (schedulerBucketKey bucket) | bucket <- buckets]
    }

schedulerBucketDeficit :: SchedulerState -> BucketKey -> Double
schedulerBucketDeficit state bucket =
  Map.findWithDefault 0 bucket (schedulerDeficits state)

advanceDeficits :: SchedulerPolicy -> SchedulerState -> [SchedulerBucket] -> SchedulerState
advanceDeficits policy state buckets =
  state
    { schedulerDeficits =
        foldl'
          ( \deficits bucket ->
              let key = schedulerBucketKey bucket
               in Map.insertWith (+) key (positiveWeight policy key) deficits
          )
          (schedulerDeficits state)
          buckets
    }

highestDeficitBucket :: SchedulerState -> [SchedulerBucket] -> SchedulerBucket
highestDeficitBucket state buckets =
  case sortOn sortKey buckets of
    bucket : _ -> bucket
    [] -> error "highestDeficitBucket called without active buckets"
  where
    sortKey bucket =
      (Down (schedulerBucketDeficit state (schedulerBucketKey bucket)), schedulerBucketKey bucket)

preemptedBucket :: UTCTime -> SchedulerPolicy -> [SchedulerBucket] -> Maybe SchedulerBucket
preemptedBucket now policy buckets =
  case sortOn sortKey (mapMaybe withinDeadline buckets) of
    (bucket, _) : _ -> Just bucket
    [] -> Nothing
  where
    threshold =
      addUTCTime (schedulerDeadlinePreemptionEpsilon policy) now
    withinDeadline bucket =
      case schedulerBucketEarliestDeadline bucket of
        Just deadline | deadline <= threshold -> Just (bucket, deadline)
        _ -> Nothing
    sortKey (bucket, deadline) =
      (deadline, schedulerBucketKey bucket)

dwellBucket :: UTCTime -> SchedulerState -> [SchedulerBucket] -> Maybe SchedulerBucket
dwellBucket now state buckets =
  case (schedulerLastBucket state, schedulerDwellUntil state) of
    (Just bucket, Just dwellUntil)
      | now < dwellUntil -> find ((== bucket) . schedulerBucketKey) buckets
    _ -> Nothing

setDwell :: UTCTime -> SchedulerPolicy -> BucketKey -> SchedulerState -> SchedulerState
setDwell now policy bucket state =
  state
    { schedulerLastBucket = Just bucket,
      schedulerDwellUntil =
        if schedulerBucketDwellTime policy > 0
          then Just (addUTCTime (schedulerBucketDwellTime policy) now)
          else Nothing
    }

positiveWeight :: SchedulerPolicy -> BucketKey -> Double
positiveWeight policy bucket =
  max 1 (schedulerBucketWeight policy bucket)
