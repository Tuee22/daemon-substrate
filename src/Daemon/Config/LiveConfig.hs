{-# LANGUAGE ScopedTypeVariables #-}

module Daemon.Config.LiveConfig
  ( BackpressureMode (..),
    BatchingPolicy (..),
    BucketKey (..),
    DedupCachePolicy (..),
    FlushStrategy (..),
    LiveConfig (..),
    LiveConfigError (..),
    LiveConfigReload (..),
    RetryPolicy (..),
    SchedulerPolicy (..),
    decodeLiveConfigFile,
    decodeLiveConfigText,
    reloadLiveConfigFile,
    schedulerBucketWeight,
  )
where

import Control.Exception (SomeException, displayException, try)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ratio ((%))
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (NominalDiffTime)
import Dhall (Decoder, FromDhall)
import qualified Dhall
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

data FlushStrategy
  = MaxFillOrTimeout
  | AdaptiveLatencyAware
  | WindowedFixed
  | DeadlineAware
  deriving stock (Eq, Ord, Show, Generic)

instance FromDhall FlushStrategy

data BackpressureMode
  = Block
  | ShedLoad
  | Redirect
  deriving stock (Eq, Ord, Show, Generic)

instance FromDhall BackpressureMode

newtype BucketKey = BucketKey {unBucketKey :: Text}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

instance FromDhall BucketKey where
  autoWith inputNormalizer =
    BucketKey <$> Dhall.autoWith inputNormalizer

data RetryPolicy = RetryPolicy
  { retryMaxAttempts :: !Natural,
    retryBaseDelay :: !NominalDiffTime,
    retryMaxDelay :: !NominalDiffTime
  }
  deriving stock (Eq, Show)

data DedupCachePolicy = DedupCachePolicy
  { dedupCacheMaxEntries :: !Natural,
    dedupCacheTtl :: !NominalDiffTime
  }
  deriving stock (Eq, Show)

data BatchingPolicy = BatchingPolicy
  { batchingMaxBatchSize :: !Int,
    batchingMaxWaitWindow :: !NominalDiffTime,
    batchingMinBatchSize :: !Int,
    batchingMaxInFlightBuffer :: !Int,
    batchingFlushStrategy :: !FlushStrategy,
    batchingBackpressureMode :: !BackpressureMode,
    batchingSecondaryWorker :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data SchedulerPolicy = SchedulerPolicy
  { schedulerBucketWeights :: !(Map BucketKey Double),
    schedulerDeadlinePreemptionEpsilon :: !NominalDiffTime,
    schedulerBucketDwellTime :: !NominalDiffTime
  }
  deriving stock (Eq, Show)

data LiveConfig = LiveConfig
  { liveConfigRetryPolicy :: !RetryPolicy,
    liveConfigDedupCachePolicy :: !DedupCachePolicy,
    liveConfigDrainDeadlineSeconds :: !Natural,
    liveConfigBatchingPolicy :: !BatchingPolicy,
    liveConfigSchedulerPolicy :: !SchedulerPolicy
  }
  deriving stock (Eq, Show)

data LiveConfigError
  = LiveConfigDhallError !Text
  | LiveConfigNaturalOverflow !Text !Natural
  deriving stock (Eq, Show)

data LiveConfigReload = LiveConfigReload
  { liveConfigReloadValue :: !LiveConfig,
    liveConfigReloadError :: !(Maybe LiveConfigError),
    liveConfigReloadChanged :: !Bool
  }
  deriving stock (Eq, Show)

decodeLiveConfigText :: Text -> IO (Either LiveConfigError LiveConfig)
decodeLiveConfigText text = do
  decoded <- decodeWith rawLiveConfigDecoder text
  pure (decoded >>= rawToLiveConfig)

decodeLiveConfigFile :: FilePath -> IO (Either LiveConfigError LiveConfig)
decodeLiveConfigFile path = do
  decoded <- decodeFileWith rawLiveConfigDecoder path
  pure (decoded >>= rawToLiveConfig)

reloadLiveConfigFile :: LiveConfig -> FilePath -> IO LiveConfigReload
reloadLiveConfigFile previous path = do
  decoded <- decodeLiveConfigFile path
  pure case decoded of
    Right next ->
      LiveConfigReload
        { liveConfigReloadValue = next,
          liveConfigReloadError = Nothing,
          liveConfigReloadChanged = next /= previous
        }
    Left err ->
      LiveConfigReload
        { liveConfigReloadValue = previous,
          liveConfigReloadError = Just err,
          liveConfigReloadChanged = False
        }

schedulerBucketWeight :: SchedulerPolicy -> BucketKey -> Double
schedulerBucketWeight policy bucket =
  Map.findWithDefault 1 bucket (schedulerBucketWeights policy)

data RawLiveConfig = RawLiveConfig
  { rawRetryPolicy :: !RawRetryPolicy,
    rawDedupCachePolicy :: !RawDedupCachePolicy,
    rawDrainDeadlineSeconds :: !Natural,
    rawBatchingPolicy :: !RawBatchingPolicy,
    rawSchedulerPolicy :: !RawSchedulerPolicy
  }

data RawRetryPolicy = RawRetryPolicy
  { rawRetryMaxAttempts :: !Natural,
    rawRetryBaseDelayMs :: !Natural,
    rawRetryMaxDelayMs :: !Natural
  }

data RawDedupCachePolicy = RawDedupCachePolicy
  { rawDedupCacheMaxEntries :: !Natural,
    rawDedupCacheTtlSeconds :: !Natural
  }

data RawBatchingPolicy = RawBatchingPolicy
  { rawBatchingMaxBatchSize :: !Natural,
    rawBatchingMaxWaitWindowMs :: !Natural,
    rawBatchingMinBatchSize :: !Natural,
    rawBatchingMaxInFlightBuffer :: !Natural,
    rawBatchingFlushStrategy :: !FlushStrategy,
    rawBatchingBackpressureMode :: !BackpressureMode,
    rawBatchingSecondaryWorker :: !(Maybe Text)
  }

data RawSchedulerPolicy = RawSchedulerPolicy
  { rawSchedulerBucketWeights :: ![RawBucketWeight],
    rawSchedulerDeadlinePreemptionMs :: !Natural,
    rawSchedulerBucketDwellMs :: !Natural
  }

data RawBucketWeight = RawBucketWeight
  { rawBucketWeightBucket :: !Text,
    rawBucketWeightWeight :: !Double
  }

rawLiveConfigDecoder :: Decoder RawLiveConfig
rawLiveConfigDecoder =
  Dhall.record
    ( RawLiveConfig
        <$> Dhall.field "retryPolicy" rawRetryPolicyDecoder
        <*> Dhall.field "dedupCache" rawDedupCachePolicyDecoder
        <*> Dhall.field "drainDeadlineSeconds" Dhall.auto
        <*> Dhall.field "batchingPolicy" rawBatchingPolicyDecoder
        <*> Dhall.field "schedulerPolicy" rawSchedulerPolicyDecoder
    )

rawRetryPolicyDecoder :: Decoder RawRetryPolicy
rawRetryPolicyDecoder =
  Dhall.record
    ( RawRetryPolicy
        <$> Dhall.field "maxAttempts" Dhall.auto
        <*> Dhall.field "baseDelayMs" Dhall.auto
        <*> Dhall.field "maxDelayMs" Dhall.auto
    )

rawDedupCachePolicyDecoder :: Decoder RawDedupCachePolicy
rawDedupCachePolicyDecoder =
  Dhall.record
    ( RawDedupCachePolicy
        <$> Dhall.field "maxEntries" Dhall.auto
        <*> Dhall.field "ttlSeconds" Dhall.auto
    )

rawBatchingPolicyDecoder :: Decoder RawBatchingPolicy
rawBatchingPolicyDecoder =
  Dhall.record
    ( RawBatchingPolicy
        <$> Dhall.field "maxBatchSize" Dhall.auto
        <*> Dhall.field "maxWaitWindowMs" Dhall.auto
        <*> Dhall.field "minBatchSize" Dhall.auto
        <*> Dhall.field "maxInFlightBuffer" Dhall.auto
        <*> Dhall.field "flushStrategy" Dhall.auto
        <*> Dhall.field "backpressureMode" Dhall.auto
        <*> Dhall.field "secondaryWorker" Dhall.auto
    )

rawSchedulerPolicyDecoder :: Decoder RawSchedulerPolicy
rawSchedulerPolicyDecoder =
  Dhall.record
    ( RawSchedulerPolicy
        <$> Dhall.field "bucketWeights" (Dhall.list rawBucketWeightDecoder)
        <*> Dhall.field "deadlinePreemptionMs" Dhall.auto
        <*> Dhall.field "bucketDwellMs" Dhall.auto
    )

rawBucketWeightDecoder :: Decoder RawBucketWeight
rawBucketWeightDecoder =
  Dhall.record
    ( RawBucketWeight
        <$> Dhall.field "bucket" Dhall.auto
        <*> Dhall.field "weight" Dhall.auto
    )

rawToLiveConfig :: RawLiveConfig -> Either LiveConfigError LiveConfig
rawToLiveConfig raw = do
  batching <- rawToBatchingPolicy (rawBatchingPolicy raw)
  pure
    LiveConfig
      { liveConfigRetryPolicy =
          RetryPolicy
            { retryMaxAttempts = rawRetryMaxAttempts (rawRetryPolicy raw),
              retryBaseDelay = milliseconds (rawRetryBaseDelayMs (rawRetryPolicy raw)),
              retryMaxDelay = milliseconds (rawRetryMaxDelayMs (rawRetryPolicy raw))
            },
        liveConfigDedupCachePolicy =
          DedupCachePolicy
            { dedupCacheMaxEntries = rawDedupCacheMaxEntries (rawDedupCachePolicy raw),
              dedupCacheTtl = seconds (rawDedupCacheTtlSeconds (rawDedupCachePolicy raw))
            },
        liveConfigDrainDeadlineSeconds = rawDrainDeadlineSeconds raw,
        liveConfigBatchingPolicy = batching,
        liveConfigSchedulerPolicy =
          SchedulerPolicy
            { schedulerBucketWeights =
                Map.fromList
                  [ (BucketKey (rawBucketWeightBucket bucketWeight), rawBucketWeightWeight bucketWeight)
                    | bucketWeight <- rawSchedulerBucketWeights (rawSchedulerPolicy raw)
                  ],
              schedulerDeadlinePreemptionEpsilon =
                milliseconds (rawSchedulerDeadlinePreemptionMs (rawSchedulerPolicy raw)),
              schedulerBucketDwellTime =
                milliseconds (rawSchedulerBucketDwellMs (rawSchedulerPolicy raw))
            }
      }

rawToBatchingPolicy :: RawBatchingPolicy -> Either LiveConfigError BatchingPolicy
rawToBatchingPolicy raw = do
  maxBatchSize <- naturalToInt "batchingPolicy.maxBatchSize" (rawBatchingMaxBatchSize raw)
  minBatchSize <- naturalToInt "batchingPolicy.minBatchSize" (rawBatchingMinBatchSize raw)
  maxInFlightBuffer <-
    naturalToInt "batchingPolicy.maxInFlightBuffer" (rawBatchingMaxInFlightBuffer raw)
  pure
    BatchingPolicy
      { batchingMaxBatchSize = maxBatchSize,
        batchingMaxWaitWindow = milliseconds (rawBatchingMaxWaitWindowMs raw),
        batchingMinBatchSize = minBatchSize,
        batchingMaxInFlightBuffer = maxInFlightBuffer,
        batchingFlushStrategy = rawBatchingFlushStrategy raw,
        batchingBackpressureMode = rawBatchingBackpressureMode raw,
        batchingSecondaryWorker = rawBatchingSecondaryWorker raw
      }

naturalToInt :: Text -> Natural -> Either LiveConfigError Int
naturalToInt fieldName value
  | toInteger value <= toInteger (maxBound :: Int) =
      Right (fromIntegral value)
  | otherwise =
      Left (LiveConfigNaturalOverflow fieldName value)

milliseconds :: Natural -> NominalDiffTime
milliseconds value =
  fromRational (toInteger value % 1000)

seconds :: Natural -> NominalDiffTime
seconds value =
  fromInteger (toInteger value)

decodeWith :: Decoder a -> Text -> IO (Either LiveConfigError a)
decodeWith decoder text = do
  decoded <- try (Dhall.input decoder text)
  pure case decoded of
    Right value -> Right value
    Left (exception :: SomeException) ->
      Left (LiveConfigDhallError (Text.pack (displayException exception)))

decodeFileWith :: Decoder a -> FilePath -> IO (Either LiveConfigError a)
decodeFileWith decoder path = do
  decoded <- try (Dhall.inputFile decoder path)
  pure case decoded of
    Right value -> Right value
    Left (exception :: SomeException) ->
      Left (LiveConfigDhallError (Text.pack (displayException exception)))
