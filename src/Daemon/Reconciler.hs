module Daemon.Reconciler where

import Data.Foldable (foldlM)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Numeric.Natural (Natural)
import Daemon.Audit
import Daemon.Config.LifecyclePolicy
import Daemon.MinIO
import qualified Daemon.MinIO.Admin as MinIOAdmin
import Daemon.Pulsar
import Daemon.Pulsar.Admin

data ReconcileReport = ReconcileReport
  { reconcilerChangedTopics :: ![TopicName],
    reconcilerChangedBuckets :: ![BucketName],
    reconcilerDeletedObjects :: ![ObjectRef],
    reconcilerAuditReplaySize :: !Int
  }
  deriving stock (Eq, Show)

data ReconcilerError
  = ReconcilerPulsarError !PulsarError
  | ReconcilerPulsarAdminError !PulsarAdminError
  | ReconcilerMinIOAdminError !MinIOAdmin.MinIOAdminError
  | ReconcilerAuditError !AuditError
  deriving stock (Eq, Show)

emptyReconcileReport :: ReconcileReport
emptyReconcileReport =
  ReconcileReport
    { reconcilerChangedTopics = [],
      reconcilerChangedBuckets = [],
      reconcilerDeletedObjects = [],
      reconcilerAuditReplaySize = 0
    }

runReconciler ::
  (HasPulsar m, HasPulsarAdmin m, MinIOAdmin.HasMinIOAdmin m) =>
  LifecyclePolicy ->
  m (Either ReconcilerError ReconcileReport)
runReconciler policy = do
  leadership <- reconcilerAcquireActiveLeadership policy
  case leadership of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right emptyReconcileReport)
    Right (Just _subscription) -> reconcileOnce policy

reconcilerAcquireActiveLeadership ::
  (HasPulsar m) =>
  LifecyclePolicy ->
  m (Either ReconcilerError (Maybe Subscription))
reconcilerAcquireActiveLeadership policy = do
  leadership <- reconcilerAcquireLeadership policy
  case leadership of
    Left err -> pure (Left err)
    Right subscription -> do
      active <- pulsarWaitActive subscription
      pure case active of
        Left err -> Left (ReconcilerPulsarError err)
        Right True -> Right (Just subscription)
        Right False -> Right Nothing

reconcilerAcquireLeadership ::
  (HasPulsar m) =>
  LifecyclePolicy ->
  m (Either ReconcilerError Subscription)
reconcilerAcquireLeadership policy = do
  subscribed <-
    pulsarSubscribe
      (lifecyclePolicyLeaderControlTopic policy)
      reconcilerLeaderSubscription
      Failover
  pure case subscribed of
    Left err -> Left (ReconcilerPulsarError err)
    Right subscription -> Right subscription

reconcileOnce ::
  (HasPulsar m, HasPulsarAdmin m, MinIOAdmin.HasMinIOAdmin m) =>
  LifecyclePolicy ->
  m (Either ReconcilerError ReconcileReport)
reconcileOnce policy = do
  replayed <- auditReplay (lifecyclePolicyAuditTopic policy)
  case replayed of
    Left err -> pure (Left (ReconcilerAuditError err))
    Right auditState -> do
      topicReport <- reconcileTopics policy emptyReconcileReport {reconcilerAuditReplaySize = Map.size auditState}
      case topicReport of
        Left err -> pure (Left err)
        Right withTopics -> do
          bucketReport <- reconcileBuckets policy withTopics
          case bucketReport of
            Left err -> pure (Left err)
            Right withBuckets -> reconcileOrphans policy withBuckets

reconcileTopics ::
  (HasPulsar m, HasPulsarAdmin m) =>
  LifecyclePolicy ->
  ReconcileReport ->
  m (Either ReconcilerError ReconcileReport)
reconcileTopics policy initialReport =
  foldlM reconcileTopic (Right initialReport)
    (auditEntry : leaderEntry : lifecyclePolicyTopics policy <> sessionControlEntries policy)
  where
    auditEntry =
      TopicLifecycleEntry (lifecyclePolicyAuditTopic policy) (Ephemeral 60 60)
    leaderEntry =
      TopicLifecycleEntry (lifecyclePolicyLeaderControlTopic policy) (Ephemeral 60 0)

    reconcileTopic reportResult entry =
      case reportResult of
        Left err -> pure (Left err)
        Right report -> reconcileTopicEntry policy report entry

reconcileBuckets ::
  (HasPulsar m, MinIOAdmin.HasMinIOAdmin m) =>
  LifecyclePolicy ->
  ReconcileReport ->
  m (Either ReconcilerError ReconcileReport)
reconcileBuckets policy report =
  foldlM (reconcileBucket policy) (Right report) (lifecyclePolicyBuckets policy)

reconcileOrphans ::
  (MinIOAdmin.HasMinIOAdmin m) =>
  LifecyclePolicy ->
  ReconcileReport ->
  m (Either ReconcilerError ReconcileReport)
reconcileOrphans policy report =
  foldlM reconcileBucketOrphans (Right report) (lifecyclePolicyBuckets policy)

reconcileTopicEntry ::
  (HasPulsar m, HasPulsarAdmin m) =>
  LifecyclePolicy ->
  ReconcileReport ->
  TopicLifecycleEntry ->
  m (Either ReconcilerError ReconcileReport)
reconcileTopicEntry policy report entry = do
  created <- createTopic (topicLifecycleEntryTopic entry)
  case created of
    Left err -> pure (Left (ReconcilerPulsarAdminError err))
    Right createResult -> do
      configured <- configureTopic (topicLifecycleEntryTopic entry) (topicLifecycleEntryLifecycle entry)
      case configured of
        Left err -> pure (Left err)
        Right changedByConfig -> do
          let changed = adminActionChanged createResult || changedByConfig
          audited <-
            if changed
              then auditTopicChange policy (topicLifecycleEntryTopic entry)
              else pure (Right ())
          pure case audited of
            Left err -> Left err
            Right () ->
              Right
                report
                  { reconcilerChangedTopics =
                      if changed
                        then reconcilerChangedTopics report <> [topicLifecycleEntryTopic entry]
                        else reconcilerChangedTopics report
                  }

configureTopic ::
  (HasPulsarAdmin m) =>
  TopicName ->
  TopicLifecycle ->
  m (Either ReconcilerError Bool)
configureTopic topic lifecycle = do
  retentionChanged <- setTopicRetention topic lifecycle
  case retentionChanged of
    Left err -> pure (Left err)
    Right retention -> do
      dedupChanged <- setTopicDedup topic lifecycle
      pure ((retention ||) <$> dedupChanged)

setTopicRetention ::
  (HasPulsarAdmin m) =>
  TopicName ->
  TopicLifecycle ->
  m (Either ReconcilerError Bool)
setTopicRetention topic lifecycle =
  case topicRetentionSeconds lifecycle of
    Nothing -> pure (Right False)
    Just secondsValue -> do
      result <- setRetention topic RetentionPolicy {retentionSizeBytes = Nothing, retentionTimeSeconds = Just secondsValue}
      pure (adminActionChanged <$> mapPulsarAdmin result)

setTopicDedup ::
  (HasPulsarAdmin m) =>
  TopicName ->
  TopicLifecycle ->
  m (Either ReconcilerError Bool)
setTopicDedup topic lifecycle =
  case topicDedupSeconds lifecycle of
    Nothing -> pure (Right False)
    Just secondsValue -> do
      result <- setDedupWindow topic DedupWindow {dedupWindowSeconds = secondsValue}
      pure (adminActionChanged <$> mapPulsarAdmin result)

reconcileBucket ::
  (HasPulsar m, MinIOAdmin.HasMinIOAdmin m) =>
  LifecyclePolicy ->
  Either ReconcilerError ReconcileReport ->
  BucketLifecycle ->
  m (Either ReconcilerError ReconcileReport)
reconcileBucket _policy (Left err) _bucket = pure (Left err)
reconcileBucket policy (Right report) bucket = do
  created <- MinIOAdmin.createBucket (bucketLifecycleBucket bucket)
  case created of
    Left err -> pure (Left (ReconcilerMinIOAdminError err))
    Right createChanged -> do
      configured <- MinIOAdmin.setBucketLifecycle (bucketLifecycleBucket bucket) (toAdminBucketLifecycle bucket)
      case configured of
        Left err -> pure (Left (ReconcilerMinIOAdminError err))
        Right configChanged -> do
          let changed = createChanged || configChanged
          audited <-
            if changed
              then auditBucketChange policy (bucketLifecycleBucket bucket)
              else pure (Right ())
          pure case audited of
            Left err -> Left err
            Right () ->
              Right
                report
                  { reconcilerChangedBuckets =
                      if changed
                        then reconcilerChangedBuckets report <> [bucketLifecycleBucket bucket]
                        else reconcilerChangedBuckets report
                  }

reconcileBucketOrphans ::
  (MinIOAdmin.HasMinIOAdmin m) =>
  Either ReconcilerError ReconcileReport ->
  BucketLifecycle ->
  m (Either ReconcilerError ReconcileReport)
reconcileBucketOrphans (Left err) _bucket = pure (Left err)
reconcileBucketOrphans (Right report) bucket =
  case bucketLifecycleOrphanScan bucket of
    Never -> pure (Right report)
    EveryHours {} -> do
      listed <- MinIOAdmin.listObjectsByPrefix (bucketLifecycleBucket bucket) (retainedPrefix (bucketLayoutBlobs (bucketLifecycleLayout bucket)))
      case listed of
        Left err -> pure (Left (ReconcilerMinIOAdminError err))
        Right keys -> deleteUnreachable report keys
  where
    reachable = bucketLifecycleReachableFromPointers bucket
    deleteUnreachable currentReport keys =
      foldlM deleteOne (Right currentReport) [key | key <- keys, unObjectKey key `notElem` reachable]
    deleteOne (Left err) _key = pure (Left err)
    deleteOne (Right current) key = do
      let ref = ObjectRef (bucketLifecycleBucket bucket) key
      deleted <- MinIOAdmin.deleteObjectAdmin ref
      pure case deleted of
        Left err -> Left (ReconcilerMinIOAdminError err)
        Right changed ->
          Right
            current
              { reconcilerDeletedObjects =
                  if changed
                    then reconcilerDeletedObjects current <> [ref]
                    else reconcilerDeletedObjects current
              }

auditTopicChange ::
  (HasPulsar m) =>
  LifecyclePolicy ->
  TopicName ->
  m (Either ReconcilerError ())
auditTopicChange policy topic =
  mapAudit (auditPublish (lifecyclePolicyAuditTopic policy) (auditResource "pulsar-topic" (unTopicName topic)) reconcileActionCreated)

auditBucketChange ::
  (HasPulsar m) =>
  LifecyclePolicy ->
  BucketName ->
  m (Either ReconcilerError ())
auditBucketChange policy bucket =
  mapAudit (auditPublish (lifecyclePolicyAuditTopic policy) (auditResource "minio-bucket" (unBucketName bucket)) reconcileActionCreated)

mapAudit :: (Functor m) => m (Either AuditError ()) -> m (Either ReconcilerError ())
mapAudit =
  fmap (either (Left . ReconcilerAuditError) Right)

mapPulsarAdmin :: Either PulsarAdminError AdminActionResult -> Either ReconcilerError AdminActionResult
mapPulsarAdmin =
  either (Left . ReconcilerPulsarAdminError) Right

topicRetentionSeconds :: TopicLifecycle -> Maybe Int
topicRetentionSeconds lifecycle =
  case lifecycle of
    Ephemeral minutes _ -> Just (naturalToInt (minutes * 60))
    ContinuousWithArchive hours _ _ _ _ -> Just (naturalToInt (hours * 3600))
    FiniteSession {} -> Nothing
    OnlineLearning inferenceHours trainingHours _ _ _ ->
      Just (naturalToInt (max inferenceHours trainingHours * 3600))

topicDedupSeconds :: TopicLifecycle -> Maybe Int
topicDedupSeconds lifecycle =
  case lifecycle of
    Ephemeral _ secondsValue -> Just (naturalToInt secondsValue)
    ContinuousWithArchive _ _ _ _ secondsValue -> Just (naturalToInt secondsValue)
    FiniteSession {} -> Nothing
    OnlineLearning {} -> Nothing

sessionControlEntries :: LifecyclePolicy -> [TopicLifecycleEntry]
sessionControlEntries policy =
  mapMaybe sessionEntry (lifecyclePolicyTopics policy)
  where
    sessionEntry entry =
      case topicLifecycleEntryLifecycle entry of
        FiniteSession controlTopic _ _ _ _ ->
          Just (TopicLifecycleEntry controlTopic (Ephemeral 60 0))
        _ -> Nothing

toAdminBucketLifecycle :: BucketLifecycle -> MinIOAdmin.BucketLifecycle
toAdminBucketLifecycle bucket =
  MinIOAdmin.BucketLifecycle
    { MinIOAdmin.bucketLifecycleName = unBucketName (bucketLifecycleBucket bucket),
      MinIOAdmin.bucketLifecycleRetentionDays = fromIntegral <$> retainedPrefixRetentionDays (bucketLayoutBlobs (bucketLifecycleLayout bucket))
    }

naturalToInt :: Natural -> Int
naturalToInt =
  fromInteger . toInteger

reconcilerLeaderSubscription :: SubscriptionName
reconcilerLeaderSubscription =
  SubscriptionName "__daemon-substrate-reconciler-leader"
