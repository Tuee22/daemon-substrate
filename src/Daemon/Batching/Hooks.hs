module Daemon.Batching.Hooks where

import Data.List.NonEmpty (NonEmpty (..))
import Daemon.Config.LiveConfig (BucketKey (..))

data BatchingHooks req = BatchingHooks
  { canCombine :: req -> req -> Bool,
    bucketKey :: Maybe (req -> BucketKey)
  }

defaultBatchingHooks :: BatchingHooks req
defaultBatchingHooks =
  BatchingHooks
    { canCombine = \_ _ -> True,
      bucketKey = Nothing
    }

defaultBucketKey :: BucketKey
defaultBucketKey =
  BucketKey "default"

requestBucket :: BatchingHooks req -> req -> BucketKey
requestBucket hooks request =
  case bucketKey hooks of
    Nothing -> defaultBucketKey
    Just chooseBucket -> chooseBucket request

canJoinBatch :: BatchingHooks req -> NonEmpty req -> req -> Bool
canJoinBatch hooks (first :| rest) request =
  all canCombineWithExisting (first : rest)
  where
    canCombineWithExisting existing =
      canCombine hooks existing request && canCombine hooks request existing
