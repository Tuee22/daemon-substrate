{-# LANGUAGE ScopedTypeVariables #-}

module Daemon.Config.LifecyclePolicy
  ( ArchiveLayout (..),
    BucketLayout (..),
    BucketLifecycle (..),
    LifecyclePolicy (..),
    LifecyclePolicyError (..),
    OrphanScan (..),
    PrefixLayout (..),
    RetainedPrefixLayout (..),
    TopicLifecycle (..),
    TopicLifecycleEntry (..),
    decodeLifecyclePolicyFile,
    decodeLifecyclePolicyText,
    defaultSafetyWindowMinutes,
  )
where

import Control.Exception (SomeException, displayException, try)
import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.MinIO (BucketName (..))
import Daemon.Pulsar (TopicName (..))
import Dhall (Decoder)
import qualified Dhall
import Numeric.Natural (Natural)

data TopicLifecycle
  = Ephemeral
      { ephemeralRetentionMinutes :: !Natural,
        ephemeralDedupWindowSeconds :: !Natural
      }
  | ContinuousWithArchive
      { continuousHotRetentionHours :: !Natural,
        continuousArchiveBucket :: !BucketName,
        continuousArchivePrefix :: !Text,
        continuousArchiveRetentionDays :: !Natural,
        continuousDedupWindowSeconds :: !Natural
      }
  | FiniteSession
      { finiteSessionControlTopic :: !TopicName,
        finiteExportOnComplete :: !Bool,
        finiteArchiveBucket :: !(Maybe BucketName),
        finiteArchivePrefix :: !(Maybe Text),
        finiteReopenOnResume :: !Bool
      }
  | OnlineLearning
      { onlineInferenceHotHours :: !Natural,
        onlineTrainingHotHours :: !Natural,
        onlineArchiveBucket :: !BucketName,
        onlineArchivePrefix :: !Text,
        onlineArchiveRetentionDays :: !Natural
      }
  deriving stock (Eq, Show)

data TopicLifecycleEntry = TopicLifecycleEntry
  { topicLifecycleEntryTopic :: !TopicName,
    topicLifecycleEntryLifecycle :: !TopicLifecycle
  }
  deriving stock (Eq, Show)

data RetainedPrefixLayout = RetainedPrefixLayout
  { retainedPrefix :: !Text,
    retainedPrefixRetentionDays :: !(Maybe Natural)
  }
  deriving stock (Eq, Show)

newtype PrefixLayout = PrefixLayout
  { prefixLayoutPrefix :: Text
  }
  deriving stock (Eq, Show)

data ArchiveLayout = ArchiveLayout
  { archiveLayoutPrefix :: !Text,
    archiveLayoutRetentionDays :: !Natural
  }
  deriving stock (Eq, Show)

data BucketLayout = BucketLayout
  { bucketLayoutBlobs :: !RetainedPrefixLayout,
    bucketLayoutManifests :: !RetainedPrefixLayout,
    bucketLayoutPointers :: !PrefixLayout,
    bucketLayoutArchives :: !(Maybe ArchiveLayout)
  }
  deriving stock (Eq, Show)

data OrphanScan
  = Never
  | EveryHours
      { orphanScanIntervalHours :: !Natural,
        orphanScanSafetyWindowMinutes :: !Natural
      }
  deriving stock (Eq, Show)

data BucketLifecycle = BucketLifecycle
  { bucketLifecycleBucket :: !BucketName,
    bucketLifecycleLayout :: !BucketLayout,
    bucketLifecycleOrphanScan :: !OrphanScan,
    bucketLifecycleReachableFromPointers :: ![Text],
    bucketLifecycleDeleteOnUndeclare :: !Bool
  }
  deriving stock (Eq, Show)

data LifecyclePolicy = LifecyclePolicy
  { lifecyclePolicyReconcileEverySeconds :: !Natural,
    lifecyclePolicyTopics :: ![TopicLifecycleEntry],
    lifecyclePolicyBuckets :: ![BucketLifecycle],
    lifecyclePolicyAuditTopic :: !TopicName,
    lifecyclePolicyLeaderControlTopic :: !TopicName
  }
  deriving stock (Eq, Show)

newtype LifecyclePolicyError
  = LifecyclePolicyDhallError Text
  deriving stock (Eq, Show)

defaultSafetyWindowMinutes :: Natural
defaultSafetyWindowMinutes = 60

decodeLifecyclePolicyText :: Text -> IO (Either LifecyclePolicyError LifecyclePolicy)
decodeLifecyclePolicyText text =
  decodeWith lifecyclePolicyDecoder text

decodeLifecyclePolicyFile :: FilePath -> IO (Either LifecyclePolicyError LifecyclePolicy)
decodeLifecyclePolicyFile path =
  decodeFileWith lifecyclePolicyDecoder path

lifecyclePolicyDecoder :: Decoder LifecyclePolicy
lifecyclePolicyDecoder =
  Dhall.record
    ( LifecyclePolicy
        <$> Dhall.field "reconcileEverySeconds" Dhall.auto
        <*> Dhall.field "topics" (Dhall.list topicLifecycleEntryDecoder)
        <*> Dhall.field "buckets" (Dhall.list bucketLifecycleDecoder)
        <*> (TopicName <$> Dhall.field "auditTopic" Dhall.auto)
        <*> (TopicName <$> Dhall.field "leaderControlTopic" Dhall.auto)
    )

topicLifecycleEntryDecoder :: Decoder TopicLifecycleEntry
topicLifecycleEntryDecoder =
  Dhall.record
    ( TopicLifecycleEntry
        <$> (TopicName <$> Dhall.field "topic" Dhall.auto)
        <*> Dhall.field "lifecycle" topicLifecycleDecoder
    )

topicLifecycleDecoder :: Decoder TopicLifecycle
topicLifecycleDecoder =
  Dhall.union
    ( (Dhall.constructor "Ephemeral" ephemeralDecoder)
        <> (Dhall.constructor "ContinuousWithArchive" continuousDecoder)
        <> (Dhall.constructor "FiniteSession" finiteSessionDecoder)
        <> (Dhall.constructor "OnlineLearning" onlineLearningDecoder)
    )

ephemeralDecoder :: Decoder TopicLifecycle
ephemeralDecoder =
  Dhall.record
    ( Ephemeral
        <$> Dhall.field "retentionMinutes" Dhall.auto
        <*> Dhall.field "dedupWindowSeconds" Dhall.auto
    )

continuousDecoder :: Decoder TopicLifecycle
continuousDecoder =
  Dhall.record
    ( ContinuousWithArchive
        <$> Dhall.field "hotRetentionHours" Dhall.auto
        <*> (BucketName <$> Dhall.field "archiveBucket" Dhall.auto)
        <*> Dhall.field "archivePrefix" Dhall.auto
        <*> Dhall.field "archiveRetentionDays" Dhall.auto
        <*> Dhall.field "dedupWindowSeconds" Dhall.auto
    )

finiteSessionDecoder :: Decoder TopicLifecycle
finiteSessionDecoder =
  Dhall.record
    ( FiniteSession
        <$> (TopicName <$> Dhall.field "sessionControlTopic" Dhall.auto)
        <*> Dhall.field "exportOnComplete" Dhall.auto
        <*> (fmap BucketName <$> Dhall.field "archiveBucket" Dhall.auto)
        <*> Dhall.field "archivePrefix" Dhall.auto
        <*> Dhall.field "reopenOnResume" Dhall.auto
    )

onlineLearningDecoder :: Decoder TopicLifecycle
onlineLearningDecoder =
  Dhall.record
    ( OnlineLearning
        <$> Dhall.field "inferenceHotHours" Dhall.auto
        <*> Dhall.field "trainingHotHours" Dhall.auto
        <*> (BucketName <$> Dhall.field "archiveBucket" Dhall.auto)
        <*> Dhall.field "archivePrefix" Dhall.auto
        <*> Dhall.field "archiveRetentionDays" Dhall.auto
    )

bucketLifecycleDecoder :: Decoder BucketLifecycle
bucketLifecycleDecoder =
  Dhall.record
    ( BucketLifecycle
        <$> (BucketName <$> Dhall.field "bucket" Dhall.auto)
        <*> Dhall.field "layout" bucketLayoutDecoder
        <*> Dhall.field "orphanScan" orphanScanDecoder
        <*> Dhall.field "reachableFromPointers" Dhall.auto
        <*> Dhall.field "deleteOnUndeclare" Dhall.auto
    )

bucketLayoutDecoder :: Decoder BucketLayout
bucketLayoutDecoder =
  Dhall.record
    ( BucketLayout
        <$> Dhall.field "blobs" retainedPrefixLayoutDecoder
        <*> Dhall.field "manifests" retainedPrefixLayoutDecoder
        <*> Dhall.field "pointers" prefixLayoutDecoder
        <*> Dhall.field "archives" (Dhall.maybe archiveLayoutDecoder)
    )

retainedPrefixLayoutDecoder :: Decoder RetainedPrefixLayout
retainedPrefixLayoutDecoder =
  Dhall.record
    ( RetainedPrefixLayout
        <$> Dhall.field "prefix" Dhall.auto
        <*> Dhall.field "retentionDays" Dhall.auto
    )

prefixLayoutDecoder :: Decoder PrefixLayout
prefixLayoutDecoder =
  Dhall.record
    ( PrefixLayout
        <$> Dhall.field "prefix" Dhall.auto
    )

archiveLayoutDecoder :: Decoder ArchiveLayout
archiveLayoutDecoder =
  Dhall.record
    ( ArchiveLayout
        <$> Dhall.field "prefix" Dhall.auto
        <*> Dhall.field "retentionDays" Dhall.auto
    )

orphanScanDecoder :: Decoder OrphanScan
orphanScanDecoder =
  Dhall.union
    ( (Never <$ Dhall.constructor "Never" Dhall.unit)
        <> (Dhall.constructor "EveryHours" everyHoursDecoder)
    )

everyHoursDecoder :: Decoder OrphanScan
everyHoursDecoder =
  Dhall.record
    ( everyHours
        <$> Dhall.field "interval" Dhall.auto
        <*> Dhall.field "safetyWindowMin" Dhall.auto
    )
  where
    everyHours interval safetyWindow =
      EveryHours
        { orphanScanIntervalHours = interval,
          orphanScanSafetyWindowMinutes =
            maybe defaultSafetyWindowMinutes id safetyWindow
        }

decodeWith :: Decoder a -> Text -> IO (Either LifecyclePolicyError a)
decodeWith decoder text = do
  decoded <- try (Dhall.input decoder text)
  pure case decoded of
    Right value -> Right value
    Left (exception :: SomeException) ->
      Left (LifecyclePolicyDhallError (Text.pack (displayException exception)))

decodeFileWith :: Decoder a -> FilePath -> IO (Either LifecyclePolicyError a)
decodeFileWith decoder path = do
  decoded <- try (Dhall.inputFile decoder path)
  pure case decoded of
    Right value -> Right value
    Left (exception :: SomeException) ->
      Left (LifecyclePolicyDhallError (Text.pack (displayException exception)))
