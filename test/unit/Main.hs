{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (throwIO)
import Control.Monad (unless)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString.Char8
import Data.Foldable (traverse_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (elemIndex)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.ProtoLens (Message, defMessage)
import Data.ProtoLens.Encoding (decodeMessage, encodeMessage)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import Daemon.Audit
import Daemon.Batching.Batcher
import Daemon.Batching.Hooks
import Daemon.Batching.Scheduler
import Daemon.Batching.Telemetry
import Daemon.Bridge
import Daemon.Bootstrap
import qualified Daemon.Cluster.EdgePort as ClusterEdgePort
import qualified Daemon.Cluster.Plan as ClusterPlan
import qualified Daemon.Cluster.Runner as ClusterRunner
import qualified Daemon.Cluster.Types as ClusterTypes
import qualified Daemon.Cluster.Workload as ClusterWorkload
import Daemon.Consumer
import Daemon.Config.BootConfig
import Daemon.Config.LifecyclePolicy
import Daemon.Config.LiveConfig
import Daemon.Engine
import Daemon.Harbor
import Daemon.Kubectl
import Daemon.Lifecycle
import Daemon.Lifecycle.Endpoints
import Daemon.MinIO
import qualified Daemon.MinIO.Admin as MinIOAdmin
import Daemon.MinIO.Cache
import Daemon.MinIO.Store
import Daemon.MinIO.Subprocess
import Daemon.Orchestrator
import Daemon.Pulsar
import Daemon.Pulsar.Admin (HasPulsarAdmin (..))
import qualified Daemon.Pulsar.Admin as PulsarAdmin
import qualified Daemon.Pulsar.Admin.Http as PulsarAdminHttp
import qualified Daemon.Pulsar.Native as Native
import Daemon.MinIO.Admin (HasMinIOAdmin (..))
import Daemon.Reconciler
import qualified Daemon.Proto.Audit as AuditProto
import qualified Daemon.Proto.Control as ControlProto
import qualified Daemon.Proto.Lifecycle as LifecycleProto
import qualified Daemon.Proto.Mock as MockProto
import qualified Daemon.Proto.OrchestratorWorker as WorkerProto
import qualified Daemon.Proto.PulsarApi as PulsarApi
import qualified Daemon.Proto.Workflow as WorkflowProto
import Daemon.Signal
import Daemon.Sub
import Daemon.Test.FilesystemHarbor
import Daemon.Test.FilesystemKubectl
import Daemon.Test.FilesystemMinIO
import Daemon.Test.FilesystemPulsar
import Daemon.Test.EchoEngines
import Daemon.Test.CLI.Cluster
import Daemon.Test.CLI.Tests
import Daemon.Test.CLI.Types
import Daemon.Test.MockEngine
import qualified Daemon.Topology.BatchedFanIn as BatchedFanIn
import qualified Daemon.Topology.BatchedFanOut as BatchedFanOut
import qualified Daemon.Topology.FanIn as FanIn
import qualified Daemon.Topology.FanOut as FanOut
import qualified Daemon.Topology.Pipeline as Pipeline
import qualified Daemon.Topology.RequestResponse as RequestResponse
import qualified Daemon.Topology.Stream as Stream
import Daemon.Topology.Types
import Daemon.Worker
import Daemon.WorkflowState
import qualified Daemon.Wire.Audit as WireAudit
import qualified Daemon.Wire.Control as WireControl
import qualified Daemon.Wire.Lifecycle as WireLifecycle
import qualified Daemon.Wire.OrchestratorWorker as WireWorker
import qualified Daemon.Wire.Workflow as WireWorkflow
import qualified Dhall
import GHC.Generics (Generic)
import Lens.Family2 ((&), (.~), (^.))
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.Exit (ExitCode (ExitFailure))
import System.FilePath ((</>))

main :: IO ()
main = do
  testPublishConsumeAck
  testNegativeAckAndSeek
  testDedupAndExclusive
  testPulsarAdminIdempotency
  testPulsarAdminHttpPayloads
  testBootConfigDhall
  testLiveConfigDhall
  testLifecyclePolicyDhall
  testDaemonLifecycle
  testSignalAndEndpoints
  testRunService
  testCliSurface
  testProtoRoundTrips
  testWireRoundTrips
  testEngineHandles
  testMockEngine
  testAuditHelper
  testConsumerWorkflowStateAndTopology
  testBatchingAndBatchedTopology
  testWorkerLoop
  testOrchestratorLoop
  testBridgeLoop
  testFanInBootstrap
  testReconcilerLoop
  testConcurrentExecutionContract
  testClusterLifecyclePlans
  testPulsarNativeProtocolHelpers
  testMinIOStoreCacheAndAdmin
  testMinIOSigV4Args
  testHarborFilesystem
  testKubectlFilesystem

testPublishConsumeAck :: IO ()
testPublishConsumeAck =
  withFilesystemPulsar do
    let topic = TopicName "test.publish"
        name = SubscriptionName "worker"
    Right messageId <- pulsarPublish topic (simpleProducerMessage (ByteString.Char8.pack "payload"))
    Right subscription <- pulsarSubscribe topic name Shared
    Right (Just message) <- pulsarConsume subscription
    liftAssert "message id round-trips" (pulsarMessageId message == messageId)
    liftAssert "payload round-trips" (pulsarMessagePayload message == ByteString.Char8.pack "payload")
    Right () <- pulsarAcknowledge subscription messageId
    Right Nothing <- pulsarConsume subscription
    pure ()

testNegativeAckAndSeek :: IO ()
testNegativeAckAndSeek =
  withFilesystemPulsar do
    let topic = TopicName "test.retry"
    Right messageId <- pulsarPublish topic (simpleProducerMessage (ByteString.Char8.pack "retry"))
    Right subscription <- pulsarSubscribe topic (SubscriptionName "worker") Shared
    Right (Just firstDelivery) <- pulsarConsume subscription
    liftAssert "first delivery is original message" (pulsarMessageId firstDelivery == messageId)
    Right () <- pulsarNegativeAcknowledge subscription messageId
    Right (Just redelivery) <- pulsarConsume subscription
    liftAssert "negative ack redelivers" (pulsarMessageId redelivery == messageId)
    Right () <- pulsarSeek subscription SeekEarliest
    Right (Just replayed) <- pulsarConsume subscription
    liftAssert "seek earliest replays" (pulsarMessageId replayed == messageId)
    Right () <- pulsarSeek subscription SeekLatest
    Right Nothing <- pulsarConsume subscription
    pure ()

testDedupAndExclusive :: IO ()
testDedupAndExclusive =
  withFilesystemPulsar do
    let topic = TopicName "test.dedup"
        deduped =
          ProducerMessage
            { producerKey = Nothing,
              producerPayload = ByteString.Char8.pack "once",
              producerProperties = Map.empty,
              producerDeduplicationKey = Just "dedup-key"
            }
    Right first <- pulsarPublish topic deduped
    Right second <- pulsarPublish topic deduped
    liftAssert "dedup key returns original message id" (first == second)
    Right subscription <- pulsarSubscribe topic (SubscriptionName "exclusive") Exclusive
    Left (ExclusiveSubscriptionAlreadyActive _ _) <- pulsarSubscribe topic (SubscriptionName "exclusive") Exclusive
    Right (Just message) <- pulsarConsume subscription
    liftAssert "dedup stores one message" (pulsarMessageId message == first)
    Right Nothing <- pulsarConsume subscription
    pure ()

liftAssert :: (MonadIO m) => String -> Bool -> m ()
liftAssert label condition =
  unless condition (error label)

data TestApp = TestApp
  { testAppName :: Text.Text
  }
  deriving stock (Eq, Show, Generic)

instance Dhall.FromDhall TestApp

data HarnessWorkerTopic = HarnessWorkerTopic
  { harnessWorkerTopicCohort :: Text.Text,
    harnessWorkerTopicName :: Text.Text
  }
  deriving stock (Eq, Show, Generic)

instance Dhall.FromDhall HarnessWorkerTopic

data HarnessOrchestratorApp = HarnessOrchestratorApp
  { harnessOrchestratorIngressTopic :: Text.Text,
    harnessOrchestratorResultTopic :: Text.Text,
    harnessOrchestratorResponseTopic :: Text.Text,
    harnessOrchestratorControlTopic :: Text.Text,
    harnessOrchestratorAuditTopic :: Text.Text,
    harnessOrchestratorLifecyclePolicyPath :: Text.Text,
    harnessOrchestratorLiveConfigPath :: Text.Text,
    harnessOrchestratorWorkerTopics :: [HarnessWorkerTopic]
  }
  deriving stock (Eq, Show, Generic)

instance Dhall.FromDhall HarnessOrchestratorApp

data HarnessWorkerApp = HarnessWorkerApp
  { harnessWorkerCohort :: Text.Text,
    harnessWorkerWorkTopic :: Text.Text,
    harnessWorkerResultTopic :: Text.Text,
    harnessWorkerControlTopic :: Text.Text,
    harnessWorkerCacheDirectory :: Text.Text
  }
  deriving stock (Eq, Show, Generic)

instance Dhall.FromDhall HarnessWorkerApp

testBootConfigDhall :: IO ()
testBootConfigDhall = do
  Right decoded <-
    ( decodeWorkerBootConfigText (bootConfigDhall "Worker" (Just "2048") [])
        :: IO (Either BootConfigError (BootConfig WorkerRole TestApp))
      )
  liftAssert "boot config role decodes" (bootConfigRole decoded == Worker)
  liftAssert "boot config app plug decodes" (bootConfigApp decoded == TestApp "unit")
  liftAssert "boot config max inline payload decodes" (bootConfigMaxInlinePayloadBytes decoded == 2048)

  Right defaulted <-
    ( decodeWorkerBootConfigText (bootConfigDhall "Worker" Nothing [])
        :: IO (Either BootConfigError (BootConfig WorkerRole TestApp))
      )
  liftAssert
    "boot config default max inline payload is used when omitted"
    (bootConfigMaxInlinePayloadBytes defaulted == defaultMaxInlinePayloadBytes)

  schemaMismatch <-
    ( decodeWorkerBootConfigText (bootConfigDhall "Worker" (Just "2048") ["unexpected = True"])
        :: IO (Either BootConfigError (BootConfig WorkerRole TestApp))
      )
  case schemaMismatch of
    Left _ -> pure ()
    Right _ -> error "boot config schema mismatch fails closed"

  Left (BootConfigRoleMismatch Worker Orchestrator) <-
    ( decodeWorkerBootConfigText (bootConfigDhall "Orchestrator" (Just "2048") [])
        :: IO (Either BootConfigError (BootConfig WorkerRole TestApp))
      )

  Right workerStub <-
    ( decodeWorkerBootConfigFile "dhall/worker.dhall"
        :: IO (Either BootConfigError (BootConfig WorkerRole HarnessWorkerApp))
      )
  liftAssert "worker harness role decodes" (bootConfigRole workerStub == Worker)
  liftAssert "worker harness cohort decodes" (harnessWorkerCohort (bootConfigApp workerStub) == "apple-silicon")
  liftAssert "worker harness work topic decodes" (harnessWorkerWorkTopic (bootConfigApp workerStub) == "test.batch.apple-silicon")

  Right chartWorkerStub <-
    ( decodeWorkerBootConfigFile "chart/files/worker.dhall"
        :: IO (Either BootConfigError (BootConfig WorkerRole HarnessWorkerApp))
      )
  liftAssert "chart worker harness cohort decodes" (harnessWorkerCohort (bootConfigApp chartWorkerStub) == "linux-cpu")
  liftAssert "chart worker harness work topic decodes" (harnessWorkerWorkTopic (bootConfigApp chartWorkerStub) == "test.batch.linux-cpu")

  Right orchestratorStub <-
    ( decodeOrchestratorBootConfigFile "dhall/orchestrator.dhall"
        :: IO (Either BootConfigError (BootConfig OrchestratorRole HarnessOrchestratorApp))
      )
  liftAssert "orchestrator harness role decodes" (bootConfigRole orchestratorStub == Orchestrator)
  liftAssert "orchestrator harness ingress decodes" (harnessOrchestratorIngressTopic (bootConfigApp orchestratorStub) == "test.request")
  liftAssert "orchestrator harness worker topics decode" (length (harnessOrchestratorWorkerTopics (bootConfigApp orchestratorStub)) == 2)

bootConfigDhall :: Text.Text -> Maybe Text.Text -> [Text.Text] -> Text.Text
bootConfigDhall role maxInlinePayloadBytes extraFields =
  Text.unlines $
    ["{ role = < Worker | Orchestrator >." <> role]
      <> fmap
        (", " <>)
        ( baseFields
            <> maybe [] (\value -> ["maxInlinePayloadBytes = " <> value]) maxInlinePayloadBytes
            <> extraFields
        )
      <> ["}"]
  where
    baseFields =
      [ "app = { testAppName = \"unit\" }",
        "pulsarServiceUrl = \"pulsar://localhost:6650\"",
        "pulsarAdminUrl = \"http://localhost:8080\"",
        "minIOEndpoint = \"http://localhost:9000\"",
        "harborEndpoint = Some \"http://localhost:8081\"",
        "kubectlPath = \"/usr/local/bin/kubectl\""
      ]

testLiveConfigDhall :: IO ()
testLiveConfigDhall = do
  Right decoded <- decodeLiveConfigText (liveConfigDhall "MaxFillOrTimeout" "Block" Nothing 16 [])
  let batching = liveConfigBatchingPolicy decoded
      scheduler = liveConfigSchedulerPolicy decoded
  liftAssert "live config max batch size decodes" (batchingMaxBatchSize batching == 16)
  liftAssert "live config flush strategy decodes" (batchingFlushStrategy batching == MaxFillOrTimeout)
  liftAssert "live config backpressure mode decodes" (batchingBackpressureMode batching == Block)
  liftAssert "configured bucket weight decodes" (schedulerBucketWeight scheduler (BucketKey "hot") == 2.5)
  liftAssert "missing bucket weight defaults to one" (schedulerBucketWeight scheduler (BucketKey "cold") == 1)

  Right liveStub <- decodeLiveConfigFile "dhall/live.dhall"
  liftAssert "live config file stub decodes" (liveConfigDrainDeadlineSeconds liveStub == 30)
  liftAssert
    "live config file includes linux-cpu scheduler weight"
    (schedulerBucketWeight (liveConfigSchedulerPolicy liveStub) (BucketKey "linux-cpu") == 1)

  traverse_ testFlushStrategyDecode [MaxFillOrTimeout, AdaptiveLatencyAware, WindowedFixed, DeadlineAware]
  traverse_ testBackpressureModeDecode [Block, ShedLoad, Redirect]

  tempRoot <- getTemporaryDirectory
  let tempDir = tempRoot </> "daemon-substrate-unit"
      livePath = tempDir </> "live-reload.dhall"
  createDirectoryIfMissing True tempDir
  Text.IO.writeFile livePath (liveConfigDhall "MaxFillOrTimeout" "Block" Nothing 4 [])
  Right initial <- decodeLiveConfigFile livePath
  Text.IO.writeFile livePath (liveConfigDhall "MaxFillOrTimeout" "Block" Nothing 8 [])
  reloaded <- reloadLiveConfigFile initial livePath
  liftAssert "live config reload observes edits" (liveConfigReloadChanged reloaded)
  liftAssert
    "live config reload returns new value"
    (batchingMaxBatchSize (liveConfigBatchingPolicy (liveConfigReloadValue reloaded)) == 8)

  Text.IO.writeFile livePath "{ invalid = True }"
  failedReload <- reloadLiveConfigFile (liveConfigReloadValue reloaded) livePath
  liftAssert "live config failed reload preserves previous value" (liveConfigReloadValue failedReload == liveConfigReloadValue reloaded)
  liftAssert "live config failed reload reports error" (isJust (liveConfigReloadError failedReload))
  liftAssert "live config failed reload is not marked changed" (not (liveConfigReloadChanged failedReload))

testFlushStrategyDecode :: FlushStrategy -> IO ()
testFlushStrategyDecode strategy = do
  Right decoded <- decodeLiveConfigText (liveConfigDhall (Text.pack (show strategy)) "Block" Nothing 16 [])
  liftAssert
    ("flush strategy decodes: " <> show strategy)
    (batchingFlushStrategy (liveConfigBatchingPolicy decoded) == strategy)

testBackpressureModeDecode :: BackpressureMode -> IO ()
testBackpressureModeDecode mode = do
  let secondary =
        case mode of
          Redirect -> Just "secondary.worker"
          _ -> Nothing
  Right decoded <- decodeLiveConfigText (liveConfigDhall "MaxFillOrTimeout" (Text.pack (show mode)) secondary 16 [])
  liftAssert
    ("backpressure mode decodes: " <> show mode)
    (batchingBackpressureMode (liveConfigBatchingPolicy decoded) == mode)

liveConfigDhall ::
  Text.Text ->
  Text.Text ->
  Maybe Text.Text ->
  Int ->
  [Text.Text] ->
  Text.Text
liveConfigDhall flushStrategy backpressureMode secondaryWorker maxBatchSize extraBucketWeights =
  Text.unlines
    [ "{ retryPolicy =",
      "  { maxAttempts = 3",
      "  , baseDelayMs = 100",
      "  , maxDelayMs = 1000",
      "  }",
      ", dedupCache =",
      "  { maxEntries = 10000",
      "  , ttlSeconds = 300",
      "  }",
      ", drainDeadlineSeconds = 30",
      ", batchingPolicy =",
      "  { maxBatchSize = " <> Text.pack (show maxBatchSize),
      "  , maxWaitWindowMs = 25",
      "  , minBatchSize = 1",
      "  , maxInFlightBuffer = 1024",
      "  , flushStrategy = < MaxFillOrTimeout | AdaptiveLatencyAware | WindowedFixed | DeadlineAware >." <> flushStrategy,
      "  , backpressureMode = < Block | ShedLoad | Redirect >." <> backpressureMode,
      "  , secondaryWorker = " <> optionalText secondaryWorker,
      "  }",
      ", schedulerPolicy =",
      "  { bucketWeights =",
      "    [ { bucket = \"hot\", weight = 2.5 }"
        <> bucketWeightSuffix extraBucketWeights,
      "    ]",
      "  , deadlinePreemptionMs = 50",
      "  , bucketDwellMs = 0",
      "  }",
      "}"
    ]

optionalText :: Maybe Text.Text -> Text.Text
optionalText =
  maybe "None Text" (\value -> "Some \"" <> value <> "\"")

bucketWeightSuffix :: [Text.Text] -> Text.Text
bucketWeightSuffix weights =
  case weights of
    [] -> ""
    _ -> Text.concat (fmap (", " <>) weights)

testLifecyclePolicyDhall :: IO ()
testLifecyclePolicyDhall = do
  testTopicLifecycleDecode
    "Ephemeral"
    ephemeralLifecycleDhall
    Ephemeral
      { ephemeralRetentionMinutes = 5,
        ephemeralDedupWindowSeconds = 30
      }
  testTopicLifecycleDecode
    "ContinuousWithArchive"
    continuousLifecycleDhall
    ContinuousWithArchive
      { continuousHotRetentionHours = 12,
        continuousArchiveBucket = BucketName "archive-bucket",
        continuousArchivePrefix = "archives/",
        continuousArchiveRetentionDays = 14,
        continuousDedupWindowSeconds = 60
      }
  testTopicLifecycleDecode
    "FiniteSession"
    finiteSessionLifecycleDhall
    FiniteSession
      { finiteSessionControlTopic = TopicName "session.control",
        finiteExportOnComplete = True,
        finiteArchiveBucket = Just (BucketName "session-archive"),
        finiteArchivePrefix = Just "sessions/",
        finiteReopenOnResume = True
      }
  testTopicLifecycleDecode
    "OnlineLearning"
    onlineLearningLifecycleDhall
    OnlineLearning
      { onlineInferenceHotHours = 6,
        onlineTrainingHotHours = 24,
        onlineArchiveBucket = BucketName "online-archive",
        onlineArchivePrefix = "online/",
        onlineArchiveRetentionDays = 21
      }

  Right neverPolicy <- decodeLifecyclePolicyText (lifecyclePolicyDhall ephemeralLifecycleDhall orphanNeverDhall)
  liftAssert "bucket orphan scan Never decodes" (bucketLifecycleOrphanScan (singleBucket neverPolicy) == Never)

  Right everyPolicy <- decodeLifecyclePolicyText (lifecyclePolicyDhall ephemeralLifecycleDhall (orphanEveryHoursDhall "Some 30"))
  liftAssert
    "bucket orphan scan EveryHours decodes"
    ( bucketLifecycleOrphanScan (singleBucket everyPolicy)
        == EveryHours
          { orphanScanIntervalHours = 2,
            orphanScanSafetyWindowMinutes = 30
          }
    )

  Right defaultPolicy <- decodeLifecyclePolicyText (lifecyclePolicyDhall ephemeralLifecycleDhall (orphanEveryHoursDhall "None Natural"))
  liftAssert
    "bucket orphan scan safety window defaults"
    ( bucketLifecycleOrphanScan (singleBucket defaultPolicy)
        == EveryHours
          { orphanScanIntervalHours = 2,
            orphanScanSafetyWindowMinutes = defaultSafetyWindowMinutes
          }
    )

  Right filePolicy <- decodeLifecyclePolicyFile "dhall/lifecycle-policy.dhall"
  let fileLifecycles = topicLifecycleEntryLifecycle <$> lifecyclePolicyTopics filePolicy
  liftAssert "lifecycle policy file decodes" (lifecyclePolicyReconcileEverySeconds filePolicy == 30)
  liftAssert
    "lifecycle policy file covers every topic lifecycle mode"
    ( all
        ($ fileLifecycles)
        [ any isEphemeralLifecycle,
          any isContinuousLifecycle,
          any isFiniteSessionLifecycle,
          any isOnlineLearningLifecycle
        ]
    )
  liftAssert
    "lifecycle policy file configures tight orphan safety window"
    ( any
        ( \bucket ->
            bucketLifecycleBucket bucket == BucketName "daemon-substrate-test-weights"
              && bucketLifecycleOrphanScan bucket
                == EveryHours
                  { orphanScanIntervalHours = 1,
                    orphanScanSafetyWindowMinutes = 1
                  }
        )
        (lifecyclePolicyBuckets filePolicy)
    )

isEphemeralLifecycle :: TopicLifecycle -> Bool
isEphemeralLifecycle lifecycle =
  case lifecycle of
    Ephemeral {} -> True
    _ -> False

isContinuousLifecycle :: TopicLifecycle -> Bool
isContinuousLifecycle lifecycle =
  case lifecycle of
    ContinuousWithArchive {} -> True
    _ -> False

isFiniteSessionLifecycle :: TopicLifecycle -> Bool
isFiniteSessionLifecycle lifecycle =
  case lifecycle of
    FiniteSession {} -> True
    _ -> False

isOnlineLearningLifecycle :: TopicLifecycle -> Bool
isOnlineLearningLifecycle lifecycle =
  case lifecycle of
    OnlineLearning {} -> True
    _ -> False

testTopicLifecycleDecode :: String -> Text.Text -> TopicLifecycle -> IO ()
testTopicLifecycleDecode label lifecycle expected = do
  Right policy <- decodeLifecyclePolicyText (lifecyclePolicyDhall lifecycle orphanNeverDhall)
  liftAssert
    ("topic lifecycle decodes: " <> label)
    (topicLifecycleEntryLifecycle (singleTopic policy) == expected)

singleTopic :: LifecyclePolicy -> TopicLifecycleEntry
singleTopic policy =
  case lifecyclePolicyTopics policy of
    [topic] -> topic
    _ -> error "expected exactly one topic lifecycle entry"

singleBucket :: LifecyclePolicy -> BucketLifecycle
singleBucket policy =
  case lifecyclePolicyBuckets policy of
    [bucket] -> bucket
    _ -> error "expected exactly one bucket lifecycle entry"

lifecyclePolicyDhall :: Text.Text -> Text.Text -> Text.Text
lifecyclePolicyDhall lifecycle orphanScan =
  Text.unlines
    [ "{ reconcileEverySeconds = 30",
      ", topics =",
      "  [ { topic = \"policy.topic\"",
      "    , lifecycle = " <> indent lifecycle,
      "    }",
      "  ]",
      ", buckets =",
      "  [ { bucket = \"policy-bucket\"",
      "    , layout =",
      "      { blobs = { prefix = \"blobs/\", retentionDays = None Natural }",
      "      , manifests = { prefix = \"manifests/\", retentionDays = None Natural }",
      "      , pointers = { prefix = \"pointers/\" }",
      "      , archives = None { prefix : Text, retentionDays : Natural }",
      "      }",
      "    , orphanScan = " <> indent orphanScan,
      "    , reachableFromPointers = [ \"pointers/\" ]",
      "    , deleteOnUndeclare = False",
      "    }",
      "  ]",
      ", auditTopic = \"audit.reconcile.policy\"",
      ", leaderControlTopic = \"control.reconcile.policy\"",
      "}"
    ]

indent :: Text.Text -> Text.Text
indent =
  Text.replace "\n" "\n      "

topicLifecycleType :: Text.Text
topicLifecycleType =
  Text.intercalate
    "\n"
    [ "< Ephemeral :",
      "    { retentionMinutes : Natural, dedupWindowSeconds : Natural }",
      "| ContinuousWithArchive :",
      "    { hotRetentionHours : Natural",
      "    , archiveBucket : Text",
      "    , archivePrefix : Text",
      "    , archiveRetentionDays : Natural",
      "    , dedupWindowSeconds : Natural",
      "    }",
      "| FiniteSession :",
      "    { sessionControlTopic : Text",
      "    , exportOnComplete : Bool",
      "    , archiveBucket : Optional Text",
      "    , archivePrefix : Optional Text",
      "    , reopenOnResume : Bool",
      "    }",
      "| OnlineLearning :",
      "    { inferenceHotHours : Natural",
      "    , trainingHotHours : Natural",
      "    , archiveBucket : Text",
      "    , archivePrefix : Text",
      "    , archiveRetentionDays : Natural",
      "    }",
      ">"
    ]

ephemeralLifecycleDhall :: Text.Text
ephemeralLifecycleDhall =
  topicLifecycleType <> ".Ephemeral { retentionMinutes = 5, dedupWindowSeconds = 30 }"

continuousLifecycleDhall :: Text.Text
continuousLifecycleDhall =
  topicLifecycleType
    <> ".ContinuousWithArchive"
    <> " { hotRetentionHours = 12"
    <> ", archiveBucket = \"archive-bucket\""
    <> ", archivePrefix = \"archives/\""
    <> ", archiveRetentionDays = 14"
    <> ", dedupWindowSeconds = 60"
    <> " }"

finiteSessionLifecycleDhall :: Text.Text
finiteSessionLifecycleDhall =
  topicLifecycleType
    <> ".FiniteSession"
    <> " { sessionControlTopic = \"session.control\""
    <> ", exportOnComplete = True"
    <> ", archiveBucket = Some \"session-archive\""
    <> ", archivePrefix = Some \"sessions/\""
    <> ", reopenOnResume = True"
    <> " }"

onlineLearningLifecycleDhall :: Text.Text
onlineLearningLifecycleDhall =
  topicLifecycleType
    <> ".OnlineLearning"
    <> " { inferenceHotHours = 6"
    <> ", trainingHotHours = 24"
    <> ", archiveBucket = \"online-archive\""
    <> ", archivePrefix = \"online/\""
    <> ", archiveRetentionDays = 21"
    <> " }"

orphanNeverDhall :: Text.Text
orphanNeverDhall =
  "< Never | EveryHours : { interval : Natural, safetyWindowMin : Optional Natural } >.Never"

orphanEveryHoursDhall :: Text.Text -> Text.Text
orphanEveryHoursDhall safetyWindow =
  "< Never | EveryHours : { interval : Natural, safetyWindowMin : Optional Natural } >.EveryHours"
    <> " { interval = 2, safetyWindowMin = "
    <> safetyWindow
    <> " }"

testDaemonLifecycle :: IO ()
testDaemonLifecycle = do
  runtime <- testRuntime
  visitedRef <- newIORef []
  let record phase current = do
        modifyIORef' visitedRef (<> [(phase, daemonRuntimeReady current)])
        pure (Right current)
      actions :: DaemonLifecycleActions IO WorkerRole HarnessWorkerApp () [Text.Text]
      actions =
        baseActions
          { lifecycleLoad = record Load,
            lifecyclePrereq = record Prereq,
            lifecycleAcquire = record Acquire,
            lifecycleReady = record Ready,
            lifecycleServe = record Serve,
            lifecycleDrain = record Drain,
            lifecycleExit = record Exit
          }
  LifecycleCompleted completed <- runDaemonLifecycle actions runtime
  visited <- readIORef visitedRef
  liftAssert "lifecycle visits phases in order" (fmap fst visited == lifecyclePhaseOrder)
  liftAssert
    "lifecycle ready flag is true only in Ready and Serve"
    ( visited
        == [ (Load, False),
             (Prereq, False),
             (Acquire, False),
             (Ready, True),
             (Serve, True),
             (Drain, False),
             (Exit, False)
           ]
    )
  liftAssert "lifecycle completes at Exit" (daemonRuntimePhase completed == Exit)
  liftAssert "lifecycle completion clears readiness" (not (daemonRuntimeReady completed))

  failedRuntime <- testRuntime
  let failingActions :: DaemonLifecycleActions IO WorkerRole HarnessWorkerApp () [Text.Text]
      failingActions =
        baseActions
          { lifecycleAcquire = \_ -> pure (Left "probe failed")
          }
  LifecycleFailed failed errorInfo <- runDaemonLifecycle failingActions failedRuntime
  liftAssert "lifecycle failure records failed phase" (lifecycleErrorPhase errorInfo == Acquire)
  liftAssert "lifecycle failure leaves runtime in failed phase" (daemonRuntimePhase failed == Acquire)
  liftAssert "lifecycle failure clears readiness" (not (daemonRuntimeReady failed))
  liftAssert "lifecycle failure stores error on runtime" (daemonRuntimeLastError failed == Just errorInfo)

testRuntime :: IO (DaemonRuntime WorkerRole HarnessWorkerApp () [Text.Text])
testRuntime = do
  Right boot <-
    ( decodeWorkerBootConfigFile "dhall/worker.dhall"
        :: IO (Either BootConfigError (BootConfig WorkerRole HarnessWorkerApp))
      )
  Right live <- decodeLiveConfigFile "dhall/live.dhall"
  Right policy <- decodeLifecyclePolicyFile "dhall/lifecycle-policy.dhall"
  pure
    DaemonRuntime
      { daemonRuntimePhase = Load,
        daemonRuntimeBootConfig = boot,
        daemonRuntimeLiveConfig = live,
        daemonRuntimeLifecyclePolicy = policy,
        daemonRuntimeClients = (),
        daemonRuntimeSubscriptions = [],
        daemonRuntimeReady = False,
        daemonRuntimeLastError = Nothing
      }

baseActions :: DaemonLifecycleActions IO WorkerRole HarnessWorkerApp () [Text.Text]
baseActions =
  noopLifecycleActions

testSignalAndEndpoints :: IO ()
testSignalAndEndpoints = do
  runtime <- testRuntime
  hup <- applyDaemonSignal runtime DaemonSIGHUP
  liftAssert "sighup requests reload" (daemonRuntimeSnapshotReloadRequested hup)
  liftAssert "sighup does not request drain" (not (daemonRuntimeSnapshotDrainRequested hup))
  liftAssert
    "sighup preserves runtime phase"
    (daemonRuntimePhase (daemonRuntimeSnapshotRuntime hup) == daemonRuntimePhase runtime)

  let servingRuntime = runtime {daemonRuntimePhase = Serve, daemonRuntimeReady = True}
  term <- applyDaemonSignal servingRuntime DaemonSIGTERM
  liftAssert "sigterm requests drain" (daemonRuntimeSnapshotDrainRequested term)
  liftAssert "sigterm enters drain phase" (daemonRuntimePhase (daemonRuntimeSnapshotRuntime term) == Drain)
  liftAssert "sigterm clears readiness" (not (daemonRuntimeReady (daemonRuntimeSnapshotRuntime term)))

  int <- applyDaemonSignal servingRuntime DaemonSIGINT
  liftAssert "sigint enters drain phase" (daemonRuntimePhase (daemonRuntimeSnapshotRuntime int) == Drain)

  let health = renderLifecycleEndpoint runtime "/healthz"
      ready = renderLifecycleEndpoint servingRuntime "/readyz"
      notReady = renderLifecycleEndpoint runtime "/readyz"
      metrics = renderLifecycleEndpoint servingRuntime "/metrics"
      missing = renderLifecycleEndpoint runtime "/missing"
  liftAssert "healthz is healthy" (endpointResponseStatus health == 200)
  liftAssert "readyz is 200 when ready" (endpointResponseStatus ready == 200)
  liftAssert "readyz is 503 when not ready" (endpointResponseStatus notReady == 503)
  liftAssert "unknown endpoint is 404" (endpointResponseStatus missing == 404)
  liftAssert
    "metrics include lifecycle phase"
    ("daemon_lifecycle_phase{phase=\"Serve\"} 1" `ByteString.Char8.isInfixOf` endpointResponseBody metrics)

testRunService :: IO ()
testRunService = do
  liftAssert
    "runService parses CLI args"
    ( parseRunServiceArgs workerServiceArgs
        == Right
          RunServiceOptions
            { runServiceRole = ServiceWorker,
              runServiceBootConfigPath = "dhall/worker.dhall",
              runServiceLiveConfigPath = "dhall/live.dhall",
              runServiceLifecyclePolicyPath = "dhall/lifecycle-policy.dhall"
            }
    )

  failed <-
    runServiceWithArgs
      (replaceBootConfigPath "dhall/missing-worker.dhall" workerServiceArgs)
      serviceNoop
  case failed of
    Left (RunServiceBootConfigError _) -> pure ()
    _ -> error "runService reports Dhall decode failure"

  invoked <- newIORef False
  result <-
    runServiceWithArgs workerServiceArgs (serviceCallback invoked)
  called <- readIORef invoked
  liftAssert "runService callback succeeds" (result == Right ())
  liftAssert "runService invokes callback" called

testCliSurface :: IO ()
testCliSurface = do
  liftAssert "CLI parses cluster up" (parseCliCommand ["cluster", "up"] == Right (CliCluster ClusterUp))
  liftAssert "CLI parses test all" (parseCliCommand ["test", "all"] == Right (CliTest TestAll))
  liftAssert
    "CLI parses service config"
    ( parseCliCommand ["service", "--role", "worker", "--config", "dhall/worker.dhall"]
        == Right
          ( CliService
              ServiceCommand
                { serviceCommandRole = ServiceWorkerArg,
                  serviceCommandConfigPath = "dhall/worker.dhall",
                  serviceCommandLiveConfigPath = "dhall/live.dhall",
                  serviceCommandLifecyclePolicyPath = "dhall/lifecycle-policy.dhall"
                }
          )
    )
  liftAssert "CLI help lists service command" ("service --role" `Text.isInfixOf` renderCliHelp)
  liftAssert "cluster up render includes kind create" ("kind-create" `Text.isInfixOf` renderClusterCommand ClusterUp)
  liftAssert
    "test all render includes integration suite"
    ("daemon-substrate-integration" `Text.isInfixOf` renderHarnessTestCommand TestAll)

testProtoRoundTrips :: IO ()
testProtoRoundTrips = do
  let ref = protoObjectRef
      inlineEvent =
        workflowEventInline
          WorkflowProto.WORKFLOW_KIND_TRAINING
          (ByteString.Char8.pack "inline-payload")
      objectEvent =
        workflowEventObjectRef WorkflowProto.WORKFLOW_KIND_INFERENCE ref
      drainPayload :: ControlProto.Drain
      drainPayload =
        defMessage & ControlProto.deadlineUnixNanos .~ 12345
      drainCommand :: ControlProto.ControlEnvelope
      drainCommand =
        defMessage & ControlProto.drain .~ drainPayload
      reloadCommand :: ControlProto.ControlEnvelope
      reloadCommand =
        defMessage & ControlProto.reload .~ (defMessage :: ControlProto.Reload)
      workerBatch :: WorkerProto.OrchestratorToWorker
      workerBatch =
        defMessage
          & WorkerProto.batchId .~ "batch-1"
          & WorkerProto.cohort .~ "linux-cpu"
          & WorkerProto.events .~ [inlineEvent, objectEvent]
      successPayload :: WorkerProto.SuccessPayload
      successPayload =
        defMessage
          & WorkerProto.resultPayload .~ ByteString.Char8.pack "result"
          & WorkerProto.payloadType .~ "type.daemon-substrate.test/MockResult"
          & WorkerProto.outputObject .~ ref
      workerSuccess :: WorkerProto.WorkerResult
      workerSuccess =
        defMessage
          & WorkerProto.requestId .~ "request-1"
          & WorkerProto.batchId .~ "batch-1"
          & WorkerProto.success .~ successPayload
      failurePayload :: WorkerProto.FailurePayload
      failurePayload =
        defMessage
          & WorkerProto.reason .~ "forced failure"
          & WorkerProto.attempt .~ 2
      workerFailure :: WorkerProto.WorkerResult
      workerFailure =
        defMessage
          & WorkerProto.requestId .~ "request-2"
          & WorkerProto.batchId .~ "batch-1"
          & WorkerProto.failure .~ failurePayload
      readiness :: LifecycleProto.ReadinessReport
      readiness =
        defMessage
          & LifecycleProto.phase .~ LifecycleProto.LIFECYCLE_PHASE_SERVE
          & LifecycleProto.phaseDetail .~ "serving"
          & LifecycleProto.heartbeatAt .~ 999
          & LifecycleProto.ready .~ True
      auditProtoResource :: AuditProto.ResourceRef
      auditProtoResource =
        defMessage
          & AuditProto.kind .~ "pulsar-topic"
          & AuditProto.id .~ "persistent://public/default/test"
      audit :: AuditProto.AuditEvent
      audit =
        defMessage
          & AuditProto.resource .~ auditProtoResource
          & AuditProto.action .~ AuditProto.RECONCILE_ACTION_CREATED
          & AuditProto.observedAt .~ 456
          & AuditProto.actor .~ "unit-test"
          & AuditProto.sourceRefs .~ [ref]
          & AuditProto.resultRefs .~ [ref]
      mockRequest :: MockProto.MockRequest
      mockRequest =
        defMessage
          & MockProto.requestId .~ "mock-request"
          & MockProto.weightBucket .~ "weights"
          & MockProto.weightKey .~ "blobs/weight"
          & MockProto.forceFailure .~ False
          & MockProto.inputPayload .~ ByteString.Char8.pack "input"
      mockBatch :: MockProto.MockBatch
      mockBatch =
        defMessage
          & MockProto.requests .~ [mockRequest]
      mockProtoResult :: MockProto.MockResult
      mockProtoResult =
        defMessage
          & MockProto.requestId .~ "mock-request"
          & MockProto.resultPayload .~ ByteString.Char8.pack "mock-result"

  roundTrip "workflow inline payload" inlineEvent
  roundTrip "workflow object ref payload" objectEvent
  liftAssert
    "workflow inline oneof survives round-trip"
    (decodedValue inlineEvent ^. WorkflowProto.maybe'inlineBytes == Just (ByteString.Char8.pack "inline-payload"))
  liftAssert
    "workflow object_ref oneof survives round-trip"
    (decodedValue objectEvent ^. WorkflowProto.maybe'objectRef == Just ref)
  traverse_ testWorkflowKindRoundTrip workflowKinds
  roundTrip "control drain command" drainCommand
  roundTrip "control reload command" reloadCommand
  roundTrip "orchestrator-to-worker batch" workerBatch
  roundTrip "worker success result" workerSuccess
  roundTrip "worker failure result" workerFailure
  roundTrip "lifecycle readiness report" readiness
  roundTrip "audit event" audit
  roundTrip "mock request" mockRequest
  roundTrip "mock batch" mockBatch
  roundTrip "mock result" mockProtoResult

  liftAssert
    "inline payload under max is accepted"
    (WorkflowProto.validateWorkflowPayloadSize 64 inlineEvent == Right ())
  liftAssert
    "inline payload over max is rejected"
    ( WorkflowProto.validateWorkflowPayloadSize 4 inlineEvent
        == Left
          WorkflowProto.InlinePayloadTooLarge
            { WorkflowProto.inlinePayloadSize = 14,
              WorkflowProto.inlinePayloadMax = 4
            }
    )
  liftAssert
    "object ref payload is not externalized by guard"
    (WorkflowProto.validateWorkflowPayloadSize 0 objectEvent == Right ())

workflowKinds :: [WorkflowProto.WorkflowKind]
workflowKinds =
  [ WorkflowProto.WORKFLOW_KIND_UNSPECIFIED,
    WorkflowProto.WORKFLOW_KIND_TRAINING,
    WorkflowProto.WORKFLOW_KIND_INFERENCE,
    WorkflowProto.WORKFLOW_KIND_EVALUATION,
    WorkflowProto.WORKFLOW_KIND_INGESTION,
    WorkflowProto.WORKFLOW_KIND_AUDIT,
    WorkflowProto.WORKFLOW_KIND_CUSTOM
  ]

testWorkflowKindRoundTrip :: WorkflowProto.WorkflowKind -> IO ()
testWorkflowKindRoundTrip kindValue =
  liftAssert
    ("workflow kind round-trips: " <> show kindValue)
    (decodedValue event ^. WorkflowProto.workflowKind == kindValue)
  where
    event = workflowEventInline kindValue (ByteString.Char8.pack "kind-payload")

workflowEventInline ::
  WorkflowProto.WorkflowKind ->
  ByteString ->
  WorkflowProto.WorkflowEvent
workflowEventInline kindValue payload =
  defMessage
    & WorkflowProto.eventId .~ "event-inline"
    & WorkflowProto.producedAt .~ 100
    & WorkflowProto.deadlineAt .~ 0
    & WorkflowProto.workflowKind .~ kindValue
    & WorkflowProto.payloadType .~ "type.daemon-substrate.test/Inline"
    & WorkflowProto.inlineBytes .~ payload

workflowEventObjectRef ::
  WorkflowProto.WorkflowKind ->
  WorkflowProto.ObjectRef ->
  WorkflowProto.WorkflowEvent
workflowEventObjectRef kindValue ref =
  defMessage
    & WorkflowProto.eventId .~ "event-object"
    & WorkflowProto.producedAt .~ 101
    & WorkflowProto.deadlineAt .~ 200
    & WorkflowProto.workflowKind .~ kindValue
    & WorkflowProto.payloadType .~ "type.daemon-substrate.test/ObjectRef"
    & WorkflowProto.objectRef .~ ref

protoObjectRef :: WorkflowProto.ObjectRef
protoObjectRef =
  defMessage
    & WorkflowProto.bucket .~ "artifacts"
    & WorkflowProto.key .~ "mock/output.bin"
    & WorkflowProto.etag .~ "etag-1"

roundTrip :: (Eq message, Message message, Show message) => String -> message -> IO ()
roundTrip label message =
  liftAssert label (decodeMessage (encodeMessage message) == Right message)

decodedValue :: (Message message, Show message) => message -> message
decodedValue message =
  case decodeMessage (encodeMessage message) of
    Right decoded ->
      decoded
    Left err ->
      error ("protobuf round-trip decode failed: " <> err <> " for " <> show message)

testWireRoundTrips :: IO ()
testWireRoundTrips =
  traverse_ testOne [0 .. 999 :: Int]
  where
    testOne index = do
      wireRoundTrip "wire workflow event" WireWorkflow.toProto WireWorkflow.fromProto (wireWorkflowEvent index)
      wireRoundTrip "wire control envelope" WireControl.toProto WireControl.fromProto (wireControlEnvelope index)
      wireRoundTrip
        "wire orchestrator-to-worker"
        WireWorker.toProtoOrchestratorToWorker
        WireWorker.fromProtoOrchestratorToWorker
        (wireOrchestratorToWorker index)
      wireRoundTrip
        "wire worker result"
        WireWorker.toProtoWorkerResult
        WireWorker.fromProtoWorkerResult
        (wireWorkerResult index)
      wireRoundTrip "wire lifecycle readiness" WireLifecycle.toProto WireLifecycle.fromProto (wireReadinessReport index)
      wireRoundTrip "wire audit event" WireAudit.toProto WireAudit.fromProto (wireAuditEvent index)

wireRoundTrip ::
  (Eq wire, Eq err, Message proto, Show err, Show wire) =>
  String ->
  (wire -> proto) ->
  (proto -> Either err wire) ->
  wire ->
  IO ()
wireRoundTrip label toProtoValue fromProtoValue value =
  case decodeMessage (encodeMessage (toProtoValue value)) of
    Left err ->
      error ("wire decode failed: " <> label <> ": " <> err)
    Right decodedProto ->
      liftAssert label (fromProtoValue decodedProto == Right value)

wireWorkflowEvent :: Int -> WireWorkflow.WorkflowEvent
wireWorkflowEvent index =
  WireWorkflow.WorkflowEvent
    { WireWorkflow.workflowEventId = WireWorkflow.EventId ("wire-event-" <> Text.pack (show index)),
      WireWorkflow.workflowProducedAt = wireTime index,
      WireWorkflow.workflowDeadlineAt =
        if index `mod` 3 == 0
          then Nothing
          else Just (wireTime (index + 5000)),
      WireWorkflow.workflowKind = wireWorkflowKind index,
      WireWorkflow.workflowPayloadType = WireWorkflow.PayloadTypeUrl ("type.daemon-substrate.test/" <> Text.pack (show (index `mod` 5))),
      WireWorkflow.workflowPayload =
        if even index
          then WireWorkflow.WireInline (ByteString.Char8.pack ("inline-" <> show index))
          else WireWorkflow.WireObjectRef (wireObjectRef index)
    }

wireObjectRef :: Int -> WireWorkflow.ObjectRef
wireObjectRef index =
  WireWorkflow.ObjectRef
    { WireWorkflow.objectRefBucket = "bucket-" <> Text.pack (show (index `mod` 7)),
      WireWorkflow.objectRefKey = "objects/" <> Text.pack (show index),
      WireWorkflow.objectRefETag = "etag-" <> Text.pack (show (index * 17))
    }

wireWorkflowKind :: Int -> WireWorkflow.WorkflowKind
wireWorkflowKind index =
  toEnum (index `mod` (fromEnum (maxBound :: WireWorkflow.WorkflowKind) + 1))

wireControlEnvelope :: Int -> WireControl.ControlEnvelope
wireControlEnvelope index
  | even index = WireControl.ControlDrain (WireControl.Drain (wireTime (index + 100)))
  | otherwise = WireControl.ControlReload WireControl.Reload

wireOrchestratorToWorker :: Int -> WireWorker.OrchestratorToWorker
wireOrchestratorToWorker index =
  WireWorker.OrchestratorToWorker
    { WireWorker.orchestratorBatchId = "batch-" <> Text.pack (show index),
      WireWorker.orchestratorCohort =
        if even index
          then "linux-cpu"
          else "apple-silicon",
      WireWorker.orchestratorEvents = [wireWorkflowEvent index, wireWorkflowEvent (index + 1)]
    }

wireWorkerResult :: Int -> WireWorker.WorkerResult
wireWorkerResult index =
  WireWorker.WorkerResult
    { WireWorker.workerRequestId = "request-" <> Text.pack (show index),
      WireWorker.workerBatchId = "batch-" <> Text.pack (show (index `div` 4)),
      WireWorker.workerOutcome =
        if even index
          then
            WireWorker.WorkerSuccess
              WireWorker.SuccessPayload
                { WireWorker.successResultPayload = ByteString.Char8.pack ("result-" <> show index),
                  WireWorker.successPayloadType = "type.daemon-substrate.test/Result",
                  WireWorker.successOutputObject =
                    if index `mod` 4 == 0
                      then Nothing
                      else Just (wireObjectRef index)
                }
          else
            WireWorker.WorkerFailure
              WireWorker.FailurePayload
                { WireWorker.failureReason = "failure-" <> Text.pack (show index),
                  WireWorker.failureAttempt = index `mod` 5
                }
    }

wireReadinessReport :: Int -> WireLifecycle.ReadinessReport
wireReadinessReport index =
  WireLifecycle.ReadinessReport
    { WireLifecycle.readinessPhase = wireLifecyclePhase index,
      WireLifecycle.readinessPhaseDetail = "phase-detail-" <> Text.pack (show index),
      WireLifecycle.readinessHeartbeatAt = wireTime (index + 9000),
      WireLifecycle.readinessReady = even index
    }

wireLifecyclePhase :: Int -> WireLifecycle.LifecyclePhase
wireLifecyclePhase index =
  toEnum (index `mod` (fromEnum (maxBound :: WireLifecycle.LifecyclePhase) + 1))

wireAuditEvent :: Int -> WireAudit.AuditEvent
wireAuditEvent index =
  WireAudit.AuditEvent
    { WireAudit.auditResource =
        WireAudit.ResourceRef
          { WireAudit.resourceKind =
              if even index
                then "pulsar-topic"
                else "minio-bucket",
            WireAudit.resourceId = "resource-" <> Text.pack (show index)
          },
      WireAudit.auditAction = wireReconcileAction index,
      WireAudit.auditObservedAt = wireTime (index + 12000),
      WireAudit.auditActor = "actor-" <> Text.pack (show (index `mod` 3)),
      WireAudit.auditSourceRefs = [wireObjectRef index],
      WireAudit.auditResultRefs = [wireObjectRef (index + 1), wireObjectRef (index + 2)]
    }

wireReconcileAction :: Int -> WireAudit.ReconcileAction
wireReconcileAction index =
  toEnum (index `mod` (fromEnum (maxBound :: WireAudit.ReconcileAction) + 1))

wireTime :: Int -> UTCTime
wireTime index =
  WireWorkflow.unixNanosToUTCTime (1700000000000000000 + fromIntegral index)

testEngineHandles :: IO ()
testEngineHandles = do
  singletonResult <-
    runNativeEngineT nativeEchoEngine (engineCall (requestA :| []))
  liftAssert
    "native echo singleton batch round-trips"
    (singletonResult == Right (echoResponse requestA) :| [])

  multiResult <-
    runNativeEngineT nativeEchoEngine (engineCall (requestA :| [requestB]))
  liftAssert
    "native echo multi-element batch round-trips"
    (multiResult == fmap (Right . echoResponse) (requestA :| [requestB]))

  mixedResult <-
    runNativeEngineT mixedNativeEngine (engineCall (requestA :| [failedRequest, requestB]))
  liftAssert
    "native engine preserves per-element failures"
    ( mixedResult
        == Right (echoResponse requestA)
          :| [ Left (EngineRequestFailed "failed" "forced failure"),
               Right (echoResponse requestB)
             ]
    )

  batchFailed <-
    runNativeEngineT batchFailingNativeEngine (engineCall (requestA :| [requestB]))
  liftAssert
    "native engine reports batch-wide error for every request"
    (batchFailed == fmap (const (Left (EngineBatchFailed "engine crashed"))) (requestA :| [requestB]))

  subprocessResult <-
    runSubprocessEngineT (subprocessEchoEngine "/bin/cat" 1000000) (engineCall (requestA :| [requestB]))
  liftAssert
    "subprocess echo engine round-trips each request"
    (subprocessResult == fmap (Right . echoResponse) (requestA :| [requestB]))

  timeoutResult <-
    runSubprocessEngineT
      ( SubprocessEngine
          { subprocessEngineExecutable = "/bin/sleep",
            subprocessEngineArguments = ["1"],
            subprocessEngineTimeoutMicros = 10000
          }
      )
      (engineCall (slowRequest :| []))
  liftAssert
    "subprocess engine timeout is typed"
    (timeoutResult == Left (EngineTimedOut "slow" 10000) :| [])

requestA :: EngineRequest
requestA =
  EngineRequest
    { engineRequestId = "request-a",
      engineRequestPayload = ByteString.Char8.pack "payload-a"
    }

requestB :: EngineRequest
requestB =
  EngineRequest
    { engineRequestId = "request-b",
      engineRequestPayload = ByteString.Char8.pack "payload-b"
    }

failedRequest :: EngineRequest
failedRequest =
  EngineRequest
    { engineRequestId = "failed",
      engineRequestPayload = ByteString.Char8.pack "payload-failed"
    }

slowRequest :: EngineRequest
slowRequest =
  EngineRequest
    { engineRequestId = "slow",
      engineRequestPayload = ByteString.Char8.pack "payload-slow"
    }

mixedNativeEngine :: NativeEngine IO
mixedNativeEngine =
  NativeEngine \requests ->
    pure (engineStep <$> requests)
  where
    engineStep request
      | engineRequestId request == "failed" =
          Left (EngineRequestFailed "failed" "forced failure")
      | otherwise =
          Right (echoResponse request)

batchFailingNativeEngine :: NativeEngine IO
batchFailingNativeEngine =
  NativeEngine \requests ->
    pure (const (Left (EngineBatchFailed "engine crashed")) <$> requests)

testMockEngine :: IO ()
testMockEngine =
  withFilesystemMinIO do
    let bucket = BucketName "weights"
        smallRef = ObjectRef bucket (ObjectKey "mock/v1/small.bin")
        mediumRef = ObjectRef bucket (ObjectKey "mock/v1/medium.bin")
        smallBytes = ByteString.Char8.pack "small-weight"
        mediumBytes = ByteString.Char8.pack "medium-weight"
        smallRequest = mockRequestProto "mock-small" bucket "mock/v1/small.bin" False "input-a"
        mediumRequest = mockRequestProto "mock-medium" bucket "mock/v1/medium.bin" False "input-b"
        forcedRequest = mockRequestProto "mock-failed" bucket "mock/v1/small.bin" True "input-c"
    Right _ <- MinIOAdmin.createBucket bucket
    Right _ <- putBlobIfAbsent smallRef smallBytes
    Right _ <- putBlobIfAbsent mediumRef mediumBytes
    cache <- liftIO (newCache 1024)

    singletonResult <-
      runNativeEngineT
        (mockNativeEngine (MockEngine cache))
        (engineCall (mockEngineRequest smallRequest :| []))
    singletonResponse <- expectEngineSuccess "mock singleton succeeds" singletonResult
    let singletonMockResult = decodeMockResult singletonResponse
    liftAssert
      "mock singleton result carries request id"
      (singletonMockResult ^. MockProto.requestId == "mock-small")
    liftAssert
      "mock singleton result is sha256-sized"
      (ByteString.length (singletonMockResult ^. MockProto.resultPayload) == 32)
    liftAssert
      "mock singleton result payload is deterministic"
      (singletonMockResult ^. MockProto.resultPayload == mockResultPayload smallRequest smallBytes)

    multiResult <-
      runNativeEngineT
        (mockNativeEngine (MockEngine cache))
        (engineCall (mockEngineRequest smallRequest :| [mockEngineRequest mediumRequest]))
    let expectedMulti =
          Right (mockEngineResponse smallRequest smallBytes)
            :| [Right (mockEngineResponse mediumRequest mediumBytes)]
    liftAssert "mock multi-element batch succeeds" (multiResult == expectedMulti)

    mixedResult <-
      runNativeEngineT
        (mockNativeEngine (MockEngine cache))
        (engineCall (mockEngineRequest smallRequest :| [mockEngineRequest forcedRequest, mockEngineRequest mediumRequest]))
    liftAssert
      "mock mixed batch preserves per-element failure"
      ( mixedResult
          == Right (mockEngineResponse smallRequest smallBytes)
            :| [ Left (EngineRequestFailed "mock-failed" "mock forced failure"),
                 Right (mockEngineResponse mediumRequest mediumBytes)
               ]
      )

    Right () <- deleteObject smallRef
    warmResult <-
      runNativeEngineT
        (mockNativeEngine (MockEngine cache))
        (engineCall (mockEngineRequest smallRequest :| []))
    liftAssert
      "mock engine warm cache serves deleted MinIO object"
      (warmResult == Right (mockEngineResponse smallRequest smallBytes) :| [])

mockRequestProto ::
  Text.Text ->
  BucketName ->
  Text.Text ->
  Bool ->
  ByteString ->
  MockProto.MockRequest
mockRequestProto requestId bucket weightKey forceFailure inputPayload =
  defMessage
    & MockProto.requestId .~ requestId
    & MockProto.weightBucket .~ unBucketName bucket
    & MockProto.weightKey .~ weightKey
    & MockProto.forceFailure .~ forceFailure
    & MockProto.inputPayload .~ inputPayload

mockEngineRequest :: MockProto.MockRequest -> EngineRequest
mockEngineRequest request =
  EngineRequest
    { engineRequestId = request ^. MockProto.requestId,
      engineRequestPayload = encodeMessage request
    }

mockEngineResponse :: MockProto.MockRequest -> ByteString -> EngineResponse
mockEngineResponse request weightBytes =
  EngineResponse
    { engineResponseRequestId = request ^. MockProto.requestId,
      engineResponsePayload = encodeMessage (mockResult request weightBytes)
    }

expectEngineSuccess ::
  String ->
  NonEmpty (Either EngineError EngineResponse) ->
  FilesystemMinIO EngineResponse
expectEngineSuccess label result =
  case result of
    Right response :| [] ->
      pure response
    _ ->
      error label

decodeMockResult :: EngineResponse -> MockProto.MockResult
decodeMockResult response =
  case decodeMessage (engineResponsePayload response) of
    Right decoded ->
      decoded
    Left err ->
      error ("mock result decode failed: " <> err)

testAuditHelper :: IO ()
testAuditHelper =
  withFilesystemPulsar do
    let topic = TopicName "audit.reconcile.unit"
        resource = auditResource "pulsar-topic" "persistent://public/default/a"
    Right () <- auditPublish topic resource AuditProto.RECONCILE_ACTION_CREATED
    Right subscription <- pulsarSubscribe topic (SubscriptionName "audit-raw-reader") Shared
    Right (Just rawMessage) <- pulsarConsume subscription
    liftAssert
      "audit publish keys messages by resource"
      (pulsarMessageKey rawMessage == Just (auditResourceKey resource))

    Right replayed <- auditReplay topic
    liftAssert
      "audit replay returns published action"
      (Map.lookup resource replayed == Just AuditProto.RECONCILE_ACTION_CREATED)

    Right () <- auditPublish topic resource AuditProto.RECONCILE_ACTION_CONFIGURED
    Right () <- auditPublish topic resource AuditProto.RECONCILE_ACTION_DELETED
    Right latest <- auditReplay topic
    liftAssert
      "audit replay keeps latest action for resource"
      (Map.lookup resource latest == Just AuditProto.RECONCILE_ACTION_DELETED)

    let duplicateTopic = TopicName "audit.reconcile.duplicates"
        duplicateResource = auditResource "minio-bucket" "daemon-substrate-test-weights"
    Right () <- auditPublish duplicateTopic duplicateResource AuditProto.RECONCILE_ACTION_CREATED
    Right () <- auditPublish duplicateTopic duplicateResource AuditProto.RECONCILE_ACTION_CREATED
    Right duplicateReplay <- auditReplay duplicateTopic
    liftAssert
      "audit replay collapses duplicate compacted keys"
      (Map.size duplicateReplay == 1 && Map.lookup duplicateResource duplicateReplay == Just AuditProto.RECONCILE_ACTION_CREATED)

testConsumerWorkflowStateAndTopology :: IO ()
testConsumerWorkflowStateAndTopology = do
  testConsumerStep
  testConsumerMaterialization
  testWorkflowStateReplay
  testTopologyBuilders

testConsumerStep :: IO ()
testConsumerStep =
  withFilesystemPulsar do
    dedup <- liftIO newDedupCache
    handled <- liftIO (newIORef ([] :: [Text.Text]))
    let topic = TopicName "consumer.workflow"
        event = (wireWorkflowEvent 41) {WireWorkflow.workflowPayloadType = WireWorkflow.PayloadTypeUrl "type.daemon-substrate.test/request"}
        options =
          ConsumerOptions
            { consumerDedupCache = dedup,
              consumerHandlerRouter =
                handlerRouter
                  [ ("type.daemon-substrate.test/", \_ -> liftIO (modifyIORef' handled (<> ["long"])) >> pure (Right ())),
                    ("type.", \_ -> liftIO (modifyIORef' handled (<> ["short"])) >> pure (Right ()))
                  ],
              consumerObjectMaterializer = Nothing
            }
    Right _ <- publishWireWorkflowEvent topic event
    Right subscription <- pulsarSubscribe topic (SubscriptionName "consumer") Shared
    Right ConsumerDispatched <- consumerStep options subscription
    liftIO (readIORef handled) >>= liftAssert "consumer router uses longest prefix" . (== ["long"])
    Right Nothing <- pulsarConsume subscription

    Right _ <- publishWireWorkflowEvent topic event
    Right ConsumerDeduplicated <- consumerStep options subscription
    liftIO (readIORef handled) >>= liftAssert "consumer dedup skips duplicate handler" . (== ["long"])

    let failingEvent = (wireWorkflowEvent 42) {WireWorkflow.workflowEventId = WireWorkflow.EventId "consumer-failing"}
        failingOptions =
          options
            { consumerHandlerRouter =
                handlerRouter [("type.daemon-substrate.test/", \_ -> pure (Left (ConsumerHandlerFailed "forced")))]
            }
    Right failingId <- publishWireWorkflowEvent topic failingEvent
    Left (ConsumerHandlerFailed "forced") <- consumerStep failingOptions subscription
    Right (Just redelivered) <- pulsarConsume subscription
    liftAssert "consumer nacks failed handler" (pulsarMessageId redelivered == failingId)

testConsumerMaterialization :: IO ()
testConsumerMaterialization = do
  dedup <- newDedupCache
  let ref = wireObjectRef 77
      options =
        ConsumerOptions
          { consumerDedupCache = dedup,
            consumerHandlerRouter = emptyHandlerRouter,
            consumerObjectMaterializer = Just (\objectRef -> pure (Right (ByteString.Char8.pack (Text.unpack (WireWorkflow.objectRefKey objectRef)))))
          }
  Right materialized <- materializePayload options (WireWorkflow.WireObjectRef ref)
  liftAssert
    "consumer materializes object ref when configured"
    (materialized == ConsumerMaterialized ref (ByteString.Char8.pack (Text.unpack (WireWorkflow.objectRefKey ref))))

testWorkflowStateReplay :: IO ()
testWorkflowStateReplay =
  withFilesystemPulsar do
    let topic = TopicName "workflow.state"
        firstEvent = wireWorkflowEvent 100
        secondEvent = wireWorkflowEvent 101
    Right _ <- appendWorkflowEvent topic firstEvent
    Right _ <- appendWorkflowEvent topic secondEvent
    Right replayed <-
      rehydrateWorkflowState topic [] \events event ->
        Right (events <> [WireWorkflow.workflowEventId event])
    liftAssert
      "workflow state rehydrates in append order"
      (replayed == [WireWorkflow.workflowEventId firstEvent, WireWorkflow.workflowEventId secondEvent])

testTopologyBuilders :: IO ()
testTopologyBuilders = do
  let request =
        RequestResponse.requestResponse
          "request-response"
          (TopicName "topology.request")
          (TopicName "topology.response")
          (SubscriptionName "request-sub")
      fanOut =
        FanOut.fanOut
          "fan-out"
          (TopicName "topology.fanout.in")
          [TopicName "topology.fanout.a", TopicName "topology.fanout.b"]
          (SubscriptionName "fanout-sub")
      fanIn =
        FanIn.fanIn
          "fan-in"
          [TopicName "topology.fanin.a", TopicName "topology.fanin.b"]
          (TopicName "topology.fanin.out")
          (SubscriptionName "fanin-sub")
      stream =
        Stream.stream
          "stream"
          (TopicName "topology.stream")
          (SubscriptionName "stream-sub")
      pipelineTopology =
        Pipeline.toTopology
          "pipeline"
          (Pipeline.pipeline [RequestResponse.toTopology request, FanOut.toTopology fanOut, FanIn.toTopology fanIn, Stream.toTopology stream])
  liftAssert "request-response has two topics" (length (topologyTopics (RequestResponse.toTopology request)) == 2)
  liftAssert "fan-out includes input and outputs" (length (topologyTopics (FanOut.toTopology fanOut)) == 3)
  liftAssert "fan-in subscribes to every input" (length (topologySubscriptions (FanIn.toTopology fanIn)) == 2)
  liftAssert
    "stream defaults to shared subscription"
    ( case topologySubscriptions (Stream.toTopology stream) of
        [subscription] -> topologySubscriptionMode subscription == Shared
        _ -> False
    )
  liftAssert "pipeline merges topology inventories" (length (topologyTopics pipelineTopology) == 9)

testBatchingAndBatchedTopology :: IO ()
testBatchingAndBatchedTopology = do
  testBatcherFlushStrategies
  testBatcherDeadlinePreemption
  testSchedulerWFQAndDwell
  testBatcherBackpressureAndExpiredDrops
  testBatchedTopologyBuilders

testBatcherFlushStrategies :: IO ()
testBatcherFlushStrategies =
  traverse_ runStrategy [MaxFillOrTimeout, AdaptiveLatencyAware, WindowedFixed, DeadlineAware]
  where
    runStrategy strategy =
      traverse_ (testBatcherFlushStrategyIteration strategy) [0 .. 999 :: Int]

testBatcherFlushStrategyIteration :: FlushStrategy -> Int -> IO ()
testBatcherFlushStrategyIteration strategy index = do
  let now = addUTCTime (fromIntegral index) (wireTime 20000)
      flushAt = addUTCTime 10 now
      policy = testBatchingPolicy strategy Block 4 2 5 100 Nothing
      scheduler = testSchedulerPolicy Map.empty 5 0
      batcher0 = newBatcher policy scheduler textBatchingHooks
  case strategy of
    WindowedFixed -> do
      let waiting =
            enqueueTestRequests
              now
              [(index * 10 + offset, Nothing, "windowed") | offset <- [0 .. 2]]
              batcher0
      waitingAfterNoFlush <- expectNoBatch "windowed fixed waits for full batch" (flushReady flushAt waiting)
      let full =
            enqueueTestRequests
              now
              [(index * 10 + 3, Nothing, "windowed")]
              waitingAfterNoFlush
      (afterFlush, batch) <- expectBatch "windowed fixed flushes at max fill" (flushReady now full)
      liftAssert "windowed fixed batch size" (batcherBatchSize batch == 4)
      liftAssert "windowed fixed queue drains" (batcherQueuedCount afterFlush == 0)
    _ -> do
      let waited =
            enqueueTestRequests
              now
              [(index * 10 + offset, Nothing, "timeout") | offset <- [0 .. 1]]
              batcher0
      (_, batch) <- expectBatch "timeout-like strategy flushes after wait window" (flushReady flushAt waited)
      liftAssert "timeout-like batch size" (batcherBatchSize batch == 2)

testBatcherDeadlinePreemption :: IO ()
testBatcherDeadlinePreemption = do
  let now = wireTime 31000
      policy = testBatchingPolicy MaxFillOrTimeout Block 8 4 60 100 Nothing
      scheduler = testSchedulerPolicy Map.empty 5 0
      deadline = addUTCTime 2 now
      batcher =
        enqueueTestRequests
          now
          [(1, Just deadline, "deadline")]
          (newBatcher policy scheduler textBatchingHooks)
  (_, batch) <- expectBatch "deadline preemption flushes below min batch size" (flushReady now batcher)
  liftAssert "deadline preemption flag is set" (batcherBatchDeadlinePreempted batch)
  liftAssert "deadline preemption batch size" (batcherBatchSize batch == 1)

testSchedulerWFQAndDwell :: IO ()
testSchedulerWFQAndDwell = do
  let now = wireTime 32000
      hot = BucketKey "hot"
      cold = BucketKey "cold"
      policy = testSchedulerPolicy (Map.fromList [(hot, 3), (cold, 1)]) 0 0
      (hotCount, coldCount) = schedulerServiceCounts now policy hot cold 10000
  liftAssert "WFQ gives hot bucket 3/4 of service" (abs (hotCount - 7500) <= 1)
  liftAssert "WFQ gives cold bucket 1/4 of service" (abs (coldCount - 2500) <= 1)

  let dwellPolicy = testSchedulerPolicy Map.empty 0 10
      firstChoice =
        expectSchedulerChoice
          "scheduler selects initial dwell bucket"
          (selectBucket now dwellPolicy initialSchedulerState [schedulerBucket hot, schedulerBucket cold])
      firstState =
        recordService dwellPolicy (schedulerChoiceBucket firstChoice) 1 (schedulerChoiceState firstChoice)
      secondChoice =
        expectSchedulerChoice
          "scheduler honors dwell bucket"
          (selectBucket (addUTCTime 5 now) dwellPolicy firstState [schedulerBucket hot, schedulerBucket cold])
  liftAssert "bucket-affinity dwell keeps selected bucket" (schedulerChoiceBucket secondChoice == schedulerChoiceBucket firstChoice)

testBatcherBackpressureAndExpiredDrops :: IO ()
testBatcherBackpressureAndExpiredDrops = do
  let now = wireTime 33000
      scheduler = testSchedulerPolicy Map.empty 5 0
      blocked =
        expectBackpressure
          BackpressureBlock
          ( enqueueRequest
              now
              (batchingWorkflowEvent 1 Nothing)
              ("blocked" :: Text.Text)
              (newBatcher (testBatchingPolicy MaxFillOrTimeout Block 4 1 1 0 Nothing) scheduler textBatchingHooks)
          )
      shed =
        expectBackpressure
          BackpressureShedLoad
          ( enqueueRequest
              now
              (batchingWorkflowEvent 2 Nothing)
              ("shed" :: Text.Text)
              (newBatcher (testBatchingPolicy MaxFillOrTimeout ShedLoad 4 1 1 0 Nothing) scheduler textBatchingHooks)
          )
      redirected =
        expectBackpressure
          (BackpressureRedirect (Just "secondary.worker"))
          ( enqueueRequest
              now
              (batchingWorkflowEvent 3 Nothing)
              ("redirect" :: Text.Text)
              (newBatcher (testBatchingPolicy MaxFillOrTimeout Redirect 4 1 1 0 (Just "secondary.worker")) scheduler textBatchingHooks)
          )
  liftAssert "block telemetry emitted" (BatcherBackpressureEvent Block 0 `elem` batcherTelemetry blocked)
  liftAssert "shed telemetry emitted" (BatcherBackpressureEvent ShedLoad 0 `elem` batcherTelemetry shed)
  liftAssert "redirect telemetry emitted" (BatcherBackpressureEvent Redirect 0 `elem` batcherTelemetry redirected)

  let expiredDeadline = addUTCTime (-1) now
      expiredEvent = batchingWorkflowEvent 4 (Just expiredDeadline)
      expired =
        enqueueTestRequests
          now
          [(4, Just expiredDeadline, "expired")]
          (newBatcher (testBatchingPolicy DeadlineAware Block 4 1 1 100 Nothing) scheduler textBatchingHooks)
      (afterExpired, maybeBatch) = flushReady now expired
  liftAssert "expired request is not dispatched" (maybeBatch == Nothing)
  liftAssert "expired request is dropped from queue" (batcherQueuedCount afterExpired == 0)
  liftAssert
    "expired drop telemetry emitted"
    (BatcherDroppedExpired defaultBucketKey (WireWorkflow.workflowEventId expiredEvent) `elem` batcherTelemetry afterExpired)

testBatchedTopologyBuilders :: IO ()
testBatchedTopologyBuilders = do
  let policy = testBatchingPolicy MaxFillOrTimeout Block 4 1 1 100 Nothing
      scheduler = testSchedulerPolicy Map.empty 5 0
      fanOut =
        FanOut.fanOut
          "batched-fan-out"
          (TopicName "topology.batched.fanout.in")
          [TopicName "topology.batched.fanout.a", TopicName "topology.batched.fanout.b"]
          (SubscriptionName "batched-fanout-sub")
      batchedFanOut =
        BatchedFanOut.batchedFanOut fanOut policy scheduler textBatchingHooks
      fanIn =
        FanIn.fanIn
          "batched-fan-in"
          [TopicName "topology.batched.fanin.a", TopicName "topology.batched.fanin.b"]
          (TopicName "topology.batched.fanin.out")
          (SubscriptionName "batched-fanin-sub")
      batchedFanIn =
        BatchedFanIn.batchedFanIn fanIn policy scheduler textBatchingHooks
  liftAssert "batched fan-out preserves fan-out inventory" (BatchedFanOut.toTopology batchedFanOut == FanOut.toTopology fanOut)
  liftAssert "batched fan-in preserves fan-in inventory" (BatchedFanIn.toTopology batchedFanIn == FanIn.toTopology fanIn)
  liftAssert "batched fan-out retains batching policy" (BatchedFanOut.batchedFanOutBatchingPolicy batchedFanOut == policy)
  liftAssert "batched fan-in retains scheduler policy" (BatchedFanIn.batchedFanInSchedulerPolicy batchedFanIn == scheduler)

testBatchingPolicy ::
  FlushStrategy ->
  BackpressureMode ->
  Int ->
  Int ->
  NominalDiffTime ->
  Int ->
  Maybe Text.Text ->
  BatchingPolicy
testBatchingPolicy strategy mode maxBatchSize minBatchSize maxWait maxInFlight secondary =
  BatchingPolicy
    { batchingMaxBatchSize = maxBatchSize,
      batchingMaxWaitWindow = maxWait,
      batchingMinBatchSize = minBatchSize,
      batchingMaxInFlightBuffer = maxInFlight,
      batchingFlushStrategy = strategy,
      batchingBackpressureMode = mode,
      batchingSecondaryWorker = secondary
    }

testSchedulerPolicy ::
  Map.Map BucketKey Double ->
  NominalDiffTime ->
  NominalDiffTime ->
  SchedulerPolicy
testSchedulerPolicy weights epsilon dwell =
  SchedulerPolicy
    { schedulerBucketWeights = weights,
      schedulerDeadlinePreemptionEpsilon = epsilon,
      schedulerBucketDwellTime = dwell
    }

textBatchingHooks :: BatchingHooks Text.Text
textBatchingHooks =
  defaultBatchingHooks

enqueueTestRequests ::
  UTCTime ->
  [(Int, Maybe UTCTime, Text.Text)] ->
  Batcher Text.Text ->
  Batcher Text.Text
enqueueTestRequests enqueuedAt requests batcher0 =
  foldl
    ( \batcher (index, deadline, payload) ->
        expectEnqueued (enqueueRequest enqueuedAt (batchingWorkflowEvent index deadline) payload batcher)
    )
    batcher0
    requests

batchingWorkflowEvent :: Int -> Maybe UTCTime -> WireWorkflow.WorkflowEvent
batchingWorkflowEvent index deadline =
  (wireWorkflowEvent index)
    { WireWorkflow.workflowEventId = WireWorkflow.EventId ("batching-" <> Text.pack (show index)),
      WireWorkflow.workflowDeadlineAt = deadline,
      WireWorkflow.workflowPayloadType = WireWorkflow.PayloadTypeUrl "type.daemon-substrate.test/batching"
    }

expectEnqueued :: BatcherEnqueueResult req -> Batcher req
expectEnqueued result =
  case result of
    BatcherEnqueued batcher -> batcher
    BatcherBackpressured decision _ -> error ("expected enqueue, got backpressure: " <> show decision)

expectBackpressure :: BackpressureDecision -> BatcherEnqueueResult req -> Batcher req
expectBackpressure expected result =
  case result of
    BatcherBackpressured actual batcher
      | actual == expected -> batcher
      | otherwise -> error ("unexpected backpressure decision: " <> show actual)
    BatcherEnqueued _ -> error "expected backpressure, got enqueue"

expectBatch :: String -> (Batcher req, Maybe (BatcherBatch req)) -> IO (Batcher req, BatcherBatch req)
expectBatch label (batcher, maybeBatch) =
  case maybeBatch of
    Just batch -> pure (batcher, batch)
    Nothing -> error label

expectNoBatch :: String -> (Batcher req, Maybe (BatcherBatch req)) -> IO (Batcher req)
expectNoBatch label (batcher, maybeBatch) =
  case maybeBatch of
    Nothing -> pure batcher
    Just _ -> error label

schedulerServiceCounts ::
  UTCTime ->
  SchedulerPolicy ->
  BucketKey ->
  BucketKey ->
  Int ->
  (Int, Int)
schedulerServiceCounts now policy hot cold iterations =
  go iterations initialSchedulerState 0 0
  where
    go remaining state hotCount coldCount
      | remaining <= 0 = (hotCount, coldCount)
      | otherwise =
          let choice =
                expectSchedulerChoice
                  "scheduler selected no bucket"
                  (selectBucket now policy state [schedulerBucket hot, schedulerBucket cold])
              bucket = schedulerChoiceBucket choice
              stateAfterService = recordService policy bucket 1 (schedulerChoiceState choice)
           in go
                (remaining - 1)
                stateAfterService
                (if bucket == hot then hotCount + 1 else hotCount)
                (if bucket == cold then coldCount + 1 else coldCount)

schedulerBucket :: BucketKey -> SchedulerBucket
schedulerBucket bucket =
  SchedulerBucket
    { schedulerBucketKey = bucket,
      schedulerBucketDepth = 1,
      schedulerBucketEarliestDeadline = Nothing
    }

expectSchedulerChoice :: String -> Maybe SchedulerChoice -> SchedulerChoice
expectSchedulerChoice label maybeChoice =
  case maybeChoice of
    Just choice -> choice
    Nothing -> error label

data WorkerHarnessEnv = WorkerHarnessEnv
  { workerHarnessPulsar :: !FilesystemPulsarHandle,
    workerHarnessMinIO :: !FilesystemMinIOHandle,
    workerHarnessCache :: !Cache,
    workerHarnessBatchSizes :: !(IORef [Int])
  }

newtype WorkerHarness a = WorkerHarness
  {unWorkerHarness :: ReaderT WorkerHarnessEnv IO a}
  deriving newtype (Functor, Applicative, Monad, MonadFail, MonadIO)

runWorkerHarness :: WorkerHarnessEnv -> WorkerHarness a -> IO a
runWorkerHarness env action =
  runReaderT (unWorkerHarness action) env

instance HasPulsar WorkerHarness where
  pulsarPublish topic message = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) (pulsarPublish topic message))

  pulsarSubscribe topic name mode = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) (pulsarSubscribe topic name mode))

  pulsarConsume subscription = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) (pulsarConsume subscription))

  pulsarAcknowledge subscription messageId = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) (pulsarAcknowledge subscription messageId))

  pulsarNegativeAcknowledge subscription messageId = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) (pulsarNegativeAcknowledge subscription messageId))

  pulsarSeek subscription target = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) (pulsarSeek subscription target))

instance HasMinIO WorkerHarness where
  minioGet ref = do
    env <- WorkerHarness ask
    liftIO (runFilesystemMinIO (workerHarnessMinIO env) (minioGet ref))

  putBlobIfAbsent ref bytes = do
    env <- WorkerHarness ask
    liftIO (runFilesystemMinIO (workerHarnessMinIO env) (putBlobIfAbsent ref bytes))

  casPointer ref expected bytes = do
    env <- WorkerHarness ask
    liftIO (runFilesystemMinIO (workerHarnessMinIO env) (casPointer ref expected bytes))

  listObjects bucket prefix = do
    env <- WorkerHarness ask
    liftIO (runFilesystemMinIO (workerHarnessMinIO env) (listObjects bucket prefix))

  deleteObject ref = do
    env <- WorkerHarness ask
    liftIO (runFilesystemMinIO (workerHarnessMinIO env) (deleteObject ref))

instance HasPulsarAdmin WorkerHarness where
  createTopic topic = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) (createTopic topic))

  deleteTopic topic = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) (deleteTopic topic))

  terminateTopic topic = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) (terminateTopic topic))

  setRetention topic policy = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) (setRetention topic policy))

  setCompaction topic policy = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) (setCompaction topic policy))

  setDedupWindow topic window = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) (setDedupWindow topic window))

  listTopics = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) listTopics)

  exportTopicToObject topic objectRef = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) (exportTopicToObject topic objectRef))

  importTopicFromObject topic objectRef = do
    env <- WorkerHarness ask
    liftIO (runFilesystemPulsar (workerHarnessPulsar env) (importTopicFromObject topic objectRef))

instance HasMinIOAdmin WorkerHarness where
  createBucket bucket = do
    env <- WorkerHarness ask
    liftIO (runFilesystemMinIO (workerHarnessMinIO env) (createBucket bucket))

  setBucketLifecycle bucket lifecycle = do
    env <- WorkerHarness ask
    liftIO (runFilesystemMinIO (workerHarnessMinIO env) (setBucketLifecycle bucket lifecycle))

  listBuckets = do
    env <- WorkerHarness ask
    liftIO (runFilesystemMinIO (workerHarnessMinIO env) listBuckets)

  listObjectsByPrefix bucket prefix = do
    env <- WorkerHarness ask
    liftIO (runFilesystemMinIO (workerHarnessMinIO env) (listObjectsByPrefix bucket prefix))

  deleteObjectAdmin ref = do
    env <- WorkerHarness ask
    liftIO (runFilesystemMinIO (workerHarnessMinIO env) (deleteObjectAdmin ref))

instance HasEngine WorkerHarness where
  engineCall requests = do
    env <- WorkerHarness ask
    liftIO (modifyIORef' (workerHarnessBatchSizes env) (<> [NonEmpty.length requests]))
    nativeEngineCall (mockNativeEngine (MockEngine (workerHarnessCache env))) requests

testWorkerLoop :: IO ()
testWorkerLoop = do
  pulsarHandle <- newFilesystemPulsarHandle
  minIOHandle <- newFilesystemMinIOHandle
  cache <- newCache 4096
  batchSizes <- newIORef []
  let bucket = BucketName "worker-weights"
      weightRef = ObjectRef bucket (ObjectKey "mock/v1/worker.bin")
      requestObjectRef = ObjectRef bucket (ObjectKey "requests/singleton.bin")
      weightBytes = ByteString.Char8.pack "worker-weight"
      singletonRequest = mockRequestProto "worker-single" bucket "mock/v1/worker.bin" False "input-single"
      multiRequest = mockRequestProto "worker-multi" bucket "mock/v1/worker.bin" False "input-multi"
      forcedRequest = mockRequestProto "worker-forced" bucket "mock/v1/worker.bin" True "input-forced"
  runFilesystemMinIO minIOHandle do
    Right _ <- MinIOAdmin.createBucket bucket
    Right _ <- putBlobIfAbsent weightRef weightBytes
    Right _ <- putBlobIfAbsent requestObjectRef (encodeMessage singletonRequest)
    pure ()
  runWorkerHarness
    WorkerHarnessEnv
      { workerHarnessPulsar = pulsarHandle,
        workerHarnessMinIO = minIOHandle,
        workerHarnessCache = cache,
        workerHarnessBatchSizes = batchSizes
      }
    do
      let workTopic = TopicName "worker.batch"
          resultTopic = TopicName "worker.result"
          options =
            workerOptions
              workTopic
              (SubscriptionName "worker-sub")
              resultTopic
              "type.daemon-substrate.test/MockResult"
          singletonBatch =
            WireWorker.OrchestratorToWorker
              { WireWorker.orchestratorBatchId = "batch-single",
                WireWorker.orchestratorCohort = "linux-cpu",
                WireWorker.orchestratorEvents =
                  [workerObjectEvent 500 "worker-single" requestObjectRef]
              }
          multiBatch =
            WireWorker.OrchestratorToWorker
              { WireWorker.orchestratorBatchId = "batch-multi",
                WireWorker.orchestratorCohort = "linux-cpu",
                WireWorker.orchestratorEvents =
                  [ workerInlineEvent 501 multiRequest,
                    workerInlineEvent 502 forcedRequest
                  ]
              }

      Right _ <- publishWorkerHarnessBatch workTopic singletonBatch
      Right (WorkerProcessed "batch-single" 1) <- runWorker options
      Right resultSubscription <- pulsarSubscribe resultTopic (SubscriptionName "worker-result-sub") Shared
      Right (Just singletonMessage) <- pulsarConsume resultSubscription
      (singletonWorkerResult, singletonMockResult) <- expectWorkerMockSuccess "worker singleton result" singletonMessage
      liftAssert "worker singleton request id" (WireWorker.workerRequestId singletonWorkerResult == "worker-single")
      liftAssert
        "worker singleton object-ref payload materializes through MinIO"
        (singletonMockResult ^. MockProto.resultPayload == mockResultPayload singletonRequest weightBytes)

      Right _ <- publishWorkerHarnessBatch workTopic multiBatch
      Right (WorkerProcessed "batch-multi" 2) <- runWorker options
      Right (Just multiSuccessMessage) <- pulsarConsume resultSubscription
      Right (Just multiFailureMessage) <- pulsarConsume resultSubscription
      (_, multiMockResult) <- expectWorkerMockSuccess "worker multi success result" multiSuccessMessage
      multiFailure <- expectWorkerFailure "worker multi failure result" multiFailureMessage
      liftAssert
        "worker multi success payload is deterministic"
        (multiMockResult ^. MockProto.resultPayload == mockResultPayload multiRequest weightBytes)
      liftAssert
        "worker multi failure is typed"
        ( WireWorker.workerOutcome multiFailure
            == WireWorker.WorkerFailure
              WireWorker.FailurePayload
                { WireWorker.failureReason = "mock forced failure",
                  WireWorker.failureAttempt = 0
                }
        )
  observedBatchSizes <- readIORef batchSizes
  liftAssert "worker uses singleton and multi engine calls" (observedBatchSizes == [1, 2])

workerInlineEvent :: Int -> MockProto.MockRequest -> WireWorkflow.WorkflowEvent
workerInlineEvent index request =
  (wireWorkflowEvent index)
    { WireWorkflow.workflowEventId = WireWorkflow.EventId (request ^. MockProto.requestId),
      WireWorkflow.workflowPayloadType = WireWorkflow.PayloadTypeUrl "type.daemon-substrate.test/MockRequest",
      WireWorkflow.workflowPayload = WireWorkflow.WireInline (encodeMessage request)
    }

workerObjectEvent :: Int -> Text.Text -> ObjectRef -> WireWorkflow.WorkflowEvent
workerObjectEvent index requestId ref =
  (wireWorkflowEvent index)
    { WireWorkflow.workflowEventId = WireWorkflow.EventId requestId,
      WireWorkflow.workflowPayloadType = WireWorkflow.PayloadTypeUrl "type.daemon-substrate.test/MockRequest",
      WireWorkflow.workflowPayload =
        WireWorkflow.WireObjectRef
          WireWorkflow.ObjectRef
            { WireWorkflow.objectRefBucket = unBucketName (objectRefBucket ref),
              WireWorkflow.objectRefKey = unObjectKey (objectRefKey ref),
              WireWorkflow.objectRefETag = "test-etag"
            }
    }

publishWorkerHarnessBatch ::
  (HasPulsar m) =>
  TopicName ->
  WireWorker.OrchestratorToWorker ->
  m (Either PulsarError MessageId)
publishWorkerHarnessBatch topic batch =
  pulsarPublish topic (simpleProducerMessage (WireWorker.encodeOrchestratorToWorker batch))

expectWorkerMockSuccess ::
  String ->
  PulsarMessage ->
  WorkerHarness (WireWorker.WorkerResult, MockProto.MockResult)
expectWorkerMockSuccess label message =
  case WireWorker.decodeWorkerResult (pulsarMessagePayload message) of
    Right result ->
      case WireWorker.workerOutcome result of
        WireWorker.WorkerSuccess success ->
          case decodeMessage (WireWorker.successResultPayload success) of
            Right mockResultValue -> pure (result, mockResultValue)
            Left err -> error (label <> ": mock result decode failed: " <> err)
        WireWorker.WorkerFailure failure ->
          error (label <> ": expected success, got failure: " <> show failure)
    Left err -> error (label <> ": worker result decode failed: " <> show err)

expectWorkerFailure ::
  String ->
  PulsarMessage ->
  WorkerHarness WireWorker.WorkerResult
expectWorkerFailure label message =
  case WireWorker.decodeWorkerResult (pulsarMessagePayload message) of
    Right result ->
      case WireWorker.workerOutcome result of
        WireWorker.WorkerFailure _ -> pure result
        WireWorker.WorkerSuccess _ -> error (label <> ": expected failure, got success")
    Left err -> error (label <> ": worker result decode failed: " <> show err)

testOrchestratorLoop :: IO ()
testOrchestratorLoop = do
  testOrchestratorProvisionDispatchAndForward
  testOrchestratorSharedReplicaDispatch
  testOrchestratorBatchDispatchAndDrainOrder

testOrchestratorProvisionDispatchAndForward :: IO ()
testOrchestratorProvisionDispatchAndForward =
  withFilesystemPulsar do
    let options = orchestratorTestOptions "orchestrator-single"
        requestEvent = orchestratorWorkflowEvent 700 "orch-request-1"
        workerResult =
          WireWorker.WorkerResult
            { WireWorker.workerRequestId = "orch-request-1",
              WireWorker.workerBatchId = "orch-request-1",
              WireWorker.workerOutcome =
                WireWorker.WorkerSuccess
                  WireWorker.SuccessPayload
                    { WireWorker.successResultPayload = ByteString.Char8.pack "orchestrator-result",
                      WireWorker.successPayloadType = "type.daemon-substrate.test/Result",
                      WireWorker.successOutputObject = Nothing
                    }
            }
    Right runtime <- orchestratorAcquire options
    Right topics <- PulsarAdmin.listTopics
    liftAssert
      "orchestrator provisions required topics"
      ( all
          (`elem` topics)
          [ orchestratorIngressTopic options,
            orchestratorWorkerTopic options,
            orchestratorResultTopic options,
            orchestratorResponseTopic options
          ]
      )

    Right _ <- pulsarPublish (orchestratorIngressTopic options) (simpleProducerMessage (WireWorkflow.encodeWorkflowEvent requestEvent))
    Right (OrchestratorDispatched "orch-request-1" 1) <- orchestratorStep options runtime
    Right workerSubscription <- pulsarSubscribe (orchestratorWorkerTopic options) (SubscriptionName "worker-observer") Shared
    Right (Just workerMessage) <- pulsarConsume workerSubscription
    workerBatch <- expectOrchestratorWorkerBatch "orchestrator worker dispatch" workerMessage
    liftAssert "orchestrator dispatch preserves batch id" (WireWorker.orchestratorBatchId workerBatch == "orch-request-1")
    liftAssert "orchestrator dispatch preserves event" (WireWorker.orchestratorEvents workerBatch == [requestEvent])

    Right _ <- pulsarPublish (orchestratorResultTopic options) (simpleProducerMessage (WireWorker.encodeWorkerResult workerResult))
    Right (OrchestratorForwarded "orch-request-1") <- orchestratorStep options runtime
    Right responseSubscription <- pulsarSubscribe (orchestratorResponseTopic options) (SubscriptionName "response-observer") Shared
    Right (Just responseMessage) <- pulsarConsume responseSubscription
    forwarded <- expectForwardedWorkerResult "orchestrator response forward" responseMessage
    liftAssert "orchestrator forwards worker result bytes" (forwarded == workerResult)

testOrchestratorSharedReplicaDispatch :: IO ()
testOrchestratorSharedReplicaDispatch =
  withFilesystemPulsar do
    let options = orchestratorTestOptions "orchestrator-shared"
        firstEvent = orchestratorWorkflowEvent 710 "orch-shared-1"
        secondEvent = orchestratorWorkflowEvent 711 "orch-shared-2"
    Right firstRuntime <- orchestratorAcquire options
    Right secondRuntime <- orchestratorAcquire options
    Right _ <- pulsarPublish (orchestratorIngressTopic options) (simpleProducerMessage (WireWorkflow.encodeWorkflowEvent firstEvent))
    Right _ <- pulsarPublish (orchestratorIngressTopic options) (simpleProducerMessage (WireWorkflow.encodeWorkflowEvent secondEvent))
    Right (OrchestratorDispatched "orch-shared-1" 1) <- orchestratorStep options firstRuntime
    Right (OrchestratorDispatched "orch-shared-2" 1) <- orchestratorStep options secondRuntime
    Right workerSubscription <- pulsarSubscribe (orchestratorWorkerTopic options) (SubscriptionName "shared-worker-observer") Shared
    Right (Just firstWorkerMessage) <- pulsarConsume workerSubscription
    Right (Just secondWorkerMessage) <- pulsarConsume workerSubscription
    firstBatch <- expectOrchestratorWorkerBatch "shared first batch" firstWorkerMessage
    secondBatch <- expectOrchestratorWorkerBatch "shared second batch" secondWorkerMessage
    liftAssert
      "shared orchestrator replicas dispatch disjoint messages"
      (fmap WireWorker.orchestratorBatchId [firstBatch, secondBatch] == ["orch-shared-1", "orch-shared-2"])

testOrchestratorBatchDispatchAndDrainOrder :: IO ()
testOrchestratorBatchDispatchAndDrainOrder =
  withFilesystemPulsar do
    let options = orchestratorTestOptions "orchestrator-batch"
        firstEvent = orchestratorWorkflowEvent 720 "orch-batch-1"
        secondEvent = orchestratorWorkflowEvent 721 "orch-batch-2"
    Right _ <- orchestratorAcquire options
    Right _ <- orchestratorDispatchBatch options "manual-batch" (firstEvent :| [secondEvent])
    Right workerSubscription <- pulsarSubscribe (orchestratorWorkerTopic options) (SubscriptionName "manual-worker-observer") Shared
    Right (Just workerMessage) <- pulsarConsume workerSubscription
    workerBatch <- expectOrchestratorWorkerBatch "manual orchestrator batch" workerMessage
    liftAssert "manual orchestrator batch carries two events" (WireWorker.orchestratorEvents workerBatch == [firstEvent, secondEvent])
    liftAssert
      "orchestrator drain order is reverse topology subscription order"
      (orchestratorDrainOrder (orchestratorTopology options) == reverse (topologySubscriptions (orchestratorTopology options)))

orchestratorTestOptions :: Text.Text -> OrchestratorOptions
orchestratorTestOptions name =
  orchestratorOptions
    topology
    requestTopic
    (SubscriptionName (name <> "-request-sub"))
    resultTopic
    (SubscriptionName (name <> "-result-sub"))
    workerTopic
    responseTopic
    "linux-cpu"
  where
    requestTopic = TopicName (name <> ".request")
    resultTopic = TopicName (name <> ".result")
    workerTopic = TopicName (name <> ".worker")
    responseTopic = TopicName (name <> ".response")
    topology =
      Pipeline.toTopology
        (name <> "-topology")
        ( Pipeline.pipeline
            [ RequestResponse.toTopology
                (RequestResponse.requestResponse (name <> "-request-response") requestTopic responseTopic (SubscriptionName (name <> "-rr-sub"))),
              FanOut.toTopology
                (FanOut.fanOut (name <> "-fanout") requestTopic [workerTopic] (SubscriptionName (name <> "-fanout-sub"))),
              FanIn.toTopology
                (FanIn.fanIn (name <> "-fanin") [resultTopic] responseTopic (SubscriptionName (name <> "-fanin-sub")))
            ]
        )

orchestratorWorkflowEvent :: Int -> Text.Text -> WireWorkflow.WorkflowEvent
orchestratorWorkflowEvent index requestId =
  (wireWorkflowEvent index)
    { WireWorkflow.workflowEventId = WireWorkflow.EventId requestId,
      WireWorkflow.workflowPayloadType = WireWorkflow.PayloadTypeUrl "type.daemon-substrate.test/OrchestratorRequest",
      WireWorkflow.workflowPayload = WireWorkflow.WireInline (ByteString.Char8.pack (Text.unpack requestId))
    }

expectOrchestratorWorkerBatch ::
  String ->
  PulsarMessage ->
  FilesystemPulsar WireWorker.OrchestratorToWorker
expectOrchestratorWorkerBatch label message =
  case WireWorker.decodeOrchestratorToWorker (pulsarMessagePayload message) of
    Right batch -> pure batch
    Left err -> error (label <> ": worker batch decode failed: " <> show err)

expectForwardedWorkerResult ::
  String ->
  PulsarMessage ->
  FilesystemPulsar WireWorker.WorkerResult
expectForwardedWorkerResult label message =
  case WireWorker.decodeWorkerResult (pulsarMessagePayload message) of
    Right result -> pure result
    Left err -> error (label <> ": worker result decode failed: " <> show err)

testBridgeLoop :: IO ()
testBridgeLoop = do
  testBridgeIdentity
  testBridgePayloadTransform
  testBridgeTargetRouting

testBridgeIdentity :: IO ()
testBridgeIdentity =
  withFilesystemPulsar do
    let source = TopicName "bridge.identity.source"
        target = TopicName "bridge.identity.target"
        options = bridgeOptions source (SubscriptionName "bridge-identity")
        payload = ByteString.Char8.pack "identity-payload"
    Right sourceId <- pulsarPublish source (simpleProducerMessage payload)
    Right (BridgeForwarded forwardedSourceId _ targetTopic) <- runBridge options (identityBridge target)
    liftAssert "bridge identity reports source id" (forwardedSourceId == sourceId)
    liftAssert "bridge identity reports target topic" (targetTopic == target)
    Right targetSubscription <- pulsarSubscribe target (SubscriptionName "bridge-identity-target") Shared
    Right (Just forwarded) <- pulsarConsume targetSubscription
    liftAssert "bridge identity preserves payload" (pulsarMessagePayload forwarded == payload)

testBridgePayloadTransform :: IO ()
testBridgePayloadTransform =
  withFilesystemPulsar do
    let source = TopicName "bridge.transform.source"
        target = TopicName "bridge.transform.target"
        options = bridgeOptions source (SubscriptionName "bridge-transform")
    Right _ <- pulsarPublish source (simpleProducerMessage (ByteString.Char8.pack "payload"))
    Right (BridgeForwarded _ _ _) <-
      runBridge
        options
        (mapPayloadBridge target (ByteString.Char8.append (ByteString.Char8.pack "mapped:")))
    Right targetSubscription <- pulsarSubscribe target (SubscriptionName "bridge-transform-target") Shared
    Right (Just forwarded) <- pulsarConsume targetSubscription
    liftAssert "bridge transform maps payload" (pulsarMessagePayload forwarded == ByteString.Char8.pack "mapped:payload")

testBridgeTargetRouting :: IO ()
testBridgeTargetRouting =
  withFilesystemPulsar do
    let source = TopicName "bridge.route.source"
        targetA = TopicName "bridge.route.a"
        targetB = TopicName "bridge.route.b"
        options = bridgeOptions source (SubscriptionName "bridge-route")
        chooseTarget message =
          if pulsarMessagePayload message == ByteString.Char8.pack "a"
            then Right targetA
            else Right targetB
    Right _ <- pulsarPublish source (simpleProducerMessage (ByteString.Char8.pack "b"))
    Right (BridgeForwarded _ _ routedTopic) <- runBridge options (routeBridge chooseTarget)
    liftAssert "bridge route reports selected target" (routedTopic == targetB)
    Right targetBSubscription <- pulsarSubscribe targetB (SubscriptionName "bridge-route-target-b") Shared
    Right (Just forwarded) <- pulsarConsume targetBSubscription
    liftAssert "bridge route publishes to selected target" (pulsarMessagePayload forwarded == ByteString.Char8.pack "b")
    Right targetASubscription <- pulsarSubscribe targetA (SubscriptionName "bridge-route-target-a") Shared
    Right Nothing <- pulsarConsume targetASubscription
    pure ()

testFanInBootstrap :: IO ()
testFanInBootstrap = do
  pulsarHandle <- newFilesystemPulsarHandle
  minIOHandle <- newFilesystemMinIOHandle
  cache <- newCache 4096
  batchSizes <- newIORef []
  let bucket = BucketName "bootstrap-artifacts"
  runFilesystemMinIO minIOHandle do
    Right _ <- MinIOAdmin.createBucket bucket
    pure ()
  runWorkerHarness
    WorkerHarnessEnv
      { workerHarnessPulsar = pulsarHandle,
        workerHarnessMinIO = minIOHandle,
        workerHarnessCache = cache,
        workerHarnessBatchSizes = batchSizes
      }
    do
      let requestTopic = TopicName "bootstrap.request"
          readyTopic = TopicName "bootstrap.ready"
          options =
            bootstrapOptions
              requestTopic
              (SubscriptionName "bootstrap-sub")
              readyTopic
              bucket
              (WireWorkflow.PayloadTypeUrl "type.daemon-substrate.test/Ready")
          firstRequest = bootstrapRequestEvent 800 "bootstrap-one"
          retryRequest = bootstrapRequestEvent 801 "bootstrap-retry"

      Right _ <- publishBootstrapRequest requestTopic firstRequest
      Right (BootstrapPublished (WireWorkflow.EventId "bootstrap-one") firstRef _) <-
        runFanInBootstrap options successfulBootstrapHandler
      Right readySubscription <- pulsarSubscribe readyTopic (SubscriptionName "bootstrap-ready-sub") Shared
      Right (Just firstReadyMessage) <- pulsarConsume readySubscription
      firstReady <- expectBootstrapReady "bootstrap ready event" firstReadyMessage
      assertBootstrapReadyRef "bootstrap ready ref matches stored object" firstRef firstReady
      Right firstBytes <- readBlob firstRef
      liftAssert "bootstrap writes ready payload to MinIO" (firstBytes == ByteString.Char8.pack "ready:bootstrap-one")

      Right _ <- publishBootstrapRequest requestTopic firstRequest
      Right (BootstrapPublished (WireWorkflow.EventId "bootstrap-one") _ _) <-
        runFanInBootstrap options successfulBootstrapHandler
      Right Nothing <- pulsarConsume readySubscription

      Right _ <- publishBootstrapRequest requestTopic retryRequest
      Left (BootstrapHandlerFailed "forced") <-
        runFanInBootstrap options \_ -> pure (Left (BootstrapHandlerFailed "forced"))
      Right (BootstrapPublished (WireWorkflow.EventId "bootstrap-retry") retryRef _) <-
        runFanInBootstrap options successfulBootstrapHandler
      Right (Just retryReadyMessage) <- pulsarConsume readySubscription
      retryReady <- expectBootstrapReady "bootstrap retry ready event" retryReadyMessage
      assertBootstrapReadyRef "bootstrap retry ref matches stored object" retryRef retryReady

bootstrapRequestEvent :: Int -> Text.Text -> WireWorkflow.WorkflowEvent
bootstrapRequestEvent index requestId =
  (wireWorkflowEvent index)
    { WireWorkflow.workflowEventId = WireWorkflow.EventId requestId,
      WireWorkflow.workflowPayloadType = WireWorkflow.PayloadTypeUrl "type.daemon-substrate.test/BootstrapRequest",
      WireWorkflow.workflowPayload = WireWorkflow.WireInline (ByteString.Char8.pack (Text.unpack requestId))
    }

successfulBootstrapHandler :: BootstrapHandler WorkerHarness
successfulBootstrapHandler event =
  pure
    ( Right
        BootstrapOutput
          { bootstrapOutputName = WireWorkflow.unEventId (WireWorkflow.workflowEventId event),
            bootstrapOutputBytes =
              ByteString.Char8.pack ("ready:" <> Text.unpack (WireWorkflow.unEventId (WireWorkflow.workflowEventId event)))
          }
    )

publishBootstrapRequest ::
  (HasPulsar m) =>
  TopicName ->
  WireWorkflow.WorkflowEvent ->
  m (Either PulsarError MessageId)
publishBootstrapRequest topic event =
  pulsarPublish topic (simpleProducerMessage (WireWorkflow.encodeWorkflowEvent event))

expectBootstrapReady ::
  String ->
  PulsarMessage ->
  WorkerHarness WireWorkflow.WorkflowEvent
expectBootstrapReady label message =
  case WireWorkflow.decodeWorkflowEvent (pulsarMessagePayload message) of
    Right event -> pure event
    Left err -> error (label <> ": workflow decode failed: " <> show err)

assertBootstrapReadyRef ::
  String ->
  ObjectRef ->
  WireWorkflow.WorkflowEvent ->
  WorkerHarness ()
assertBootstrapReadyRef label ref event =
  case WireWorkflow.workflowPayload event of
    WireWorkflow.WireObjectRef wireRef ->
      liftAssert
        label
        ( WireWorkflow.objectRefBucket wireRef == unBucketName (objectRefBucket ref)
            && WireWorkflow.objectRefKey wireRef == unObjectKey (objectRefKey ref)
        )
    WireWorkflow.WireInline _ ->
      error (label <> ": expected object ref ready payload")

testReconcilerLoop :: IO ()
testReconcilerLoop = do
  pulsarHandle <- newFilesystemPulsarHandle
  minIOHandle <- newFilesystemMinIOHandle
  cache <- newCache 4096
  batchSizes <- newIORef []
  let policy = testLifecycleReconcilePolicy
      bucket = BucketName "reconcile-artifacts"
      reachableRef = ObjectRef bucket (ObjectKey "blobs/reachable")
      orphanRef = ObjectRef bucket (ObjectKey "blobs/orphan")
  runFilesystemMinIO minIOHandle do
    Right _ <- MinIOAdmin.createBucket bucket
    Right _ <- putBlobIfAbsent reachableRef (ByteString.Char8.pack "keep")
    Right _ <- putBlobIfAbsent orphanRef (ByteString.Char8.pack "delete")
    pure ()
  runWorkerHarness
    WorkerHarnessEnv
      { workerHarnessPulsar = pulsarHandle,
        workerHarnessMinIO = minIOHandle,
        workerHarnessCache = cache,
        workerHarnessBatchSizes = batchSizes
      }
    do
      Right leadership <- reconcilerAcquireLeadership policy
      liftAssert "reconciler leadership uses failover subscription" (subscriptionMode leadership == Failover)

      Right firstReport <- runReconciler policy
      liftAssert "reconciler changes declared topics" (not (null (reconcilerChangedTopics firstReport)))
      liftAssert "reconciler changes declared buckets" (reconcilerChangedBuckets firstReport == [bucket])
      liftAssert "reconciler deletes unreachable orphan" (reconcilerDeletedObjects firstReport == [orphanRef])

      Right topics <- listTopics
      liftAssert
        "reconciler creates lifecycle topics"
        ( all
            (`elem` topics)
            [ TopicName "reconcile.ephemeral",
              TopicName "reconcile.continuous",
              TopicName "reconcile.finite",
              TopicName "reconcile.online",
              TopicName "reconcile.session.control",
              lifecyclePolicyAuditTopic policy,
              lifecyclePolicyLeaderControlTopic policy
            ]
        )

      Right buckets <- listBuckets
      liftAssert "reconciler creates bucket" (bucket `elem` buckets)
      Right remainingObjects <- listObjects bucket (Just "blobs/")
      liftAssert "reconciler preserves reachable object" (ObjectKey "blobs/reachable" `elem` remainingObjects)
      liftAssert "reconciler removes unreachable object" (ObjectKey "blobs/orphan" `notElem` remainingObjects)

      Right replayed <- auditReplay (lifecyclePolicyAuditTopic policy)
      liftAssert "reconciler publishes audit records" (Map.size replayed >= 2)

      Right secondReport <- runReconciler policy
      liftAssert "reconciler second tick has audit replay state" (reconcilerAuditReplaySize secondReport >= 2)
      liftAssert "reconciler second tick is idempotent for topics" (null (reconcilerChangedTopics secondReport))
      liftAssert "reconciler second tick is idempotent for buckets" (null (reconcilerChangedBuckets secondReport))
      liftAssert "reconciler second tick has no orphan churn" (null (reconcilerDeletedObjects secondReport))

testConcurrentExecutionContract :: IO ()
testConcurrentExecutionContract = do
  testConcurrentLoopsStartTogether
  testConcurrentLoopsIsolateReconcilerFailure
  testConcurrentLoopsWaitForBoth
  testConcurrentLoopsCaptureExceptions

testConcurrentLoopsStartTogether :: IO ()
testConcurrentLoopsStartTogether = do
  orchestratorStarted <- newEmptyMVar
  reconcilerStarted <- newEmptyMVar
  result <-
    runOrchestratorWithReconciler
      (putMVar orchestratorStarted () >> takeMVar reconcilerStarted >> pure (Right OrchestratorNoMessage))
      (putMVar reconcilerStarted () >> takeMVar orchestratorStarted >> pure (Right emptyReconcileReport))
  liftAssert
    "concurrent runner starts orchestrator and reconciler together"
    ( result
        == ConcurrentLoopResult
          { concurrentOrchestratorResult = Right (Right OrchestratorNoMessage),
            concurrentReconcilerResult = Right (Right emptyReconcileReport)
          }
    )

testConcurrentLoopsIsolateReconcilerFailure :: IO ()
testConcurrentLoopsIsolateReconcilerFailure = do
  let reconcilerError = ReconcilerPulsarError (PulsarBackendUnavailable "forced reconciler failure")
  result <-
    runOrchestratorWithReconciler
      (pure (Right (OrchestratorDispatched "kept-working" 1)))
      (pure (Left reconcilerError))
  liftAssert
    "concurrent runner preserves orchestrator success when reconciler fails"
    (concurrentOrchestratorResult result == Right (Right (OrchestratorDispatched "kept-working" 1)))
  liftAssert
    "concurrent runner preserves typed reconciler failure"
    (concurrentReconcilerResult result == Right (Left reconcilerError))

testConcurrentLoopsWaitForBoth :: IO ()
testConcurrentLoopsWaitForBoth = do
  events <- newIORef []
  result <-
    runOrchestratorWithReconciler
      (recordEvent events "orchestrator-start" >> pure (Right OrchestratorNoMessage))
      (recordEvent events "reconciler-start" >> threadDelay 1000 >> recordEvent events "reconciler-finish" >> pure (Right emptyReconcileReport))
  observed <- readIORef events
  liftAssert
    "concurrent runner returns after both loops complete"
    ( result
        == ConcurrentLoopResult
          { concurrentOrchestratorResult = Right (Right OrchestratorNoMessage),
            concurrentReconcilerResult = Right (Right emptyReconcileReport)
          }
        && "reconciler-finish" `elem` observed
    )
  where
    recordEvent events label =
      modifyIORef' events (<> [label :: Text.Text])

testConcurrentLoopsCaptureExceptions :: IO ()
testConcurrentLoopsCaptureExceptions = do
  result <-
    runOrchestratorWithReconciler
      (throwIO (userError "orchestrator boom"))
      (pure (Right emptyReconcileReport))
  liftAssert
    "concurrent runner captures orchestrator exceptions"
    (case concurrentOrchestratorResult result of
      Left message -> "orchestrator boom" `Text.isInfixOf` message
      Right _ -> False)
  liftAssert
    "concurrent runner keeps peer result when one loop throws"
    (concurrentReconcilerResult result == Right (Right emptyReconcileReport))

testClusterLifecyclePlans :: IO ()
testClusterLifecyclePlans = do
  let linuxConfig = ClusterPlan.defaultClusterBringupConfig ClusterTypes.LinuxCpu
      linuxPlan = ClusterPlan.clusterBringupPlan linuxConfig
      linuxNames = ClusterTypes.clusterActionNames (ClusterTypes.clusterPlanActions linuxPlan)
      appleConfig = ClusterPlan.defaultClusterBringupConfig ClusterTypes.AppleSilicon
      applePlan = ClusterPlan.clusterBringupPlan appleConfig
      appleNames = ClusterTypes.clusterActionNames (ClusterTypes.clusterPlanActions applePlan)
      workerRollout = "worker-rollout"
  liftAssert "cluster plan records Linux cohort" (ClusterTypes.clusterPlanCohort linuxPlan == ClusterTypes.LinuxCpu)
  assertActionBefore "cluster creates kind before storage" "kind-create" "storage-class" linuxNames
  assertActionBefore "cluster reconciles storage before image build" "storage-class" "harbor-publish-image" linuxNames
  assertActionBefore "cluster loads image before Helm" "harbor-publish-image" "helm-dependency-build" linuxNames
  assertActionBefore "cluster builds Helm dependencies before release" "helm-dependency-build" "helm-upgrade-daemon-substrate-test" linuxNames
  assertActionBefore "cluster installs chart before waiting for registry" "helm-upgrade-daemon-substrate-test" "harbor-wait" linuxNames
  assertActionBefore "cluster creates Pulsar namespace before topics" "pulsar-namespace" "pulsar-topic-test.request" linuxNames
  assertActionBefore "cluster waits for MinIO before bucket creation" "minio-wait" "minio-bucket-daemon-substrate-test-weights" linuxNames
  assertActionBefore "cluster loads image before waiting for worker rollout" "harbor-publish-image" workerRollout linuxNames
  liftAssert "cluster edge-port discovery is last" (case reverse linuxNames of "edge-port-discovery" : _ -> True; _ -> False)
  liftAssert "linux cluster plan waits for worker deployment" (workerRollout `elem` linuxNames)
  liftAssert "apple cluster plan omits in-cluster worker deployment wait" (workerRollout `notElem` appleNames)
  liftAssert "linux cluster plan omits host edge forwarding" ("edge-port-forward" `notElem` linuxNames)
  assertActionBefore "apple cluster starts edge forwarding after discovery" "edge-port-discovery" "edge-port-forward" appleNames

  let linuxWorkerResources =
        [ resource
          | resource <- ClusterWorkload.workloadResources (ClusterPlan.clusterBringupWorkload linuxConfig),
            kubernetesResourceName resource == ResourceName "deployment/daemon-substrate-test-worker"
        ]
  case linuxWorkerResources of
    [resource] ->
      liftAssert
        "worker deployment renders required anti-affinity"
        ("podAntiAffinity" `Text.isInfixOf` kubernetesResourceBody resource)
    _ -> error "expected one worker Deployment resource in linux workload plan"

  let edgeConfig = ClusterEdgePort.defaultEdgePortConfig (ClusterTypes.defaultClusterPaths ClusterTypes.AppleSilicon)
  Right selectedPort <- pure (ClusterEdgePort.chooseEdgePort [9090, 9091] edgeConfig)
  liftAssert "edge port skips occupied ports" (selectedPort == 9092)
  let edgeRecordText = ClusterEdgePort.renderEdgePortRecord selectedPort
      parsedEdgeRecord = ClusterEdgePort.parseEdgePortRecord ".build/edge-port.json" edgeRecordText
  liftAssert "edge port record renders selected port" ("\"port\": 9092" `Text.isInfixOf` edgeRecordText)
  liftAssert "edge port record renders pulsar admin port" ("\"pulsarAdminPort\": 9093" `Text.isInfixOf` edgeRecordText)
  liftAssert
    "edge port record parses host-facing ports"
    ( case parsedEdgeRecord of
        Right ports ->
          ClusterEdgePort.edgePortRecordPulsarPort ports == 9092
            && ClusterEdgePort.edgePortRecordPulsarAdminPort ports == 9093
            && ClusterEdgePort.edgePortRecordMinIOPort ports == 9094
        Left _ -> False
    )
  let existingKind =
        ClusterRunner.subprocessResultToAction
          "kind-create"
          ( Right
              SubprocessResult
                { subprocessExitCode = ExitFailure 1,
                  subprocessStdout = "",
                  subprocessStderr = "ERROR: failed to create cluster: node(s) already exist for a cluster with the name \"daemon-substrate-apple-silicon\""
                }
          )
  liftAssert
    "kind create treats existing cluster as idempotent"
    (case existingKind of
      Right result -> not (ClusterRunner.clusterActionResultChanged result)
      Left _ -> False)

assertActionBefore :: String -> Text.Text -> Text.Text -> [Text.Text] -> IO ()
assertActionBefore label earlier later names =
  liftAssert label $
    case (elemIndex earlier names, elemIndex later names) of
      (Just earlierIndex, Just laterIndex) -> earlierIndex < laterIndex
      _ -> False

testLifecycleReconcilePolicy :: LifecyclePolicy
testLifecycleReconcilePolicy =
  LifecyclePolicy
    { lifecyclePolicyReconcileEverySeconds = 1,
      lifecyclePolicyTopics =
        [ TopicLifecycleEntry (TopicName "reconcile.ephemeral") (Ephemeral 5 30),
          TopicLifecycleEntry
            (TopicName "reconcile.continuous")
            ( ContinuousWithArchive
                12
                (BucketName "reconcile-archive")
                "archives/"
                14
                60
            ),
          TopicLifecycleEntry
            (TopicName "reconcile.finite")
            ( FiniteSession
                (TopicName "reconcile.session.control")
                True
                (Just (BucketName "reconcile-archive"))
                (Just "sessions/")
                True
            ),
          TopicLifecycleEntry
            (TopicName "reconcile.online")
            (OnlineLearning 6 24 (BucketName "reconcile-archive") "online/" 21)
        ],
      lifecyclePolicyBuckets =
        [ BucketLifecycle
            { bucketLifecycleBucket = BucketName "reconcile-artifacts",
              bucketLifecycleLayout =
                BucketLayout
                  { bucketLayoutBlobs = RetainedPrefixLayout "blobs/" (Just 7),
                    bucketLayoutManifests = RetainedPrefixLayout "manifests/" Nothing,
                    bucketLayoutPointers = PrefixLayout "pointers/",
                    bucketLayoutArchives = Just (ArchiveLayout "archives/" 30)
                  },
              bucketLifecycleOrphanScan = EveryHours 1 0,
              bucketLifecycleReachableFromPointers = ["blobs/reachable"],
              bucketLifecycleDeleteOnUndeclare = False
            }
        ],
      lifecyclePolicyAuditTopic = TopicName "reconcile.audit",
      lifecyclePolicyLeaderControlTopic = TopicName "reconcile.leader"
    }

publishWireWorkflowEvent ::
  (HasPulsar m) =>
  TopicName ->
  WireWorkflow.WorkflowEvent ->
  m (Either PulsarError MessageId)
publishWireWorkflowEvent topic event =
  pulsarPublish topic (simpleProducerMessage (encodeMessage (WireWorkflow.toProto event)))

serviceNoop :: ServiceBootConfig HarnessWorkerApp -> LiveConfig -> IO ()
serviceNoop _ _ =
  pure ()

serviceCallback :: IORef Bool -> ServiceBootConfig HarnessWorkerApp -> LiveConfig -> IO ()
serviceCallback invoked serviceBoot live = do
  case serviceBoot of
    ServiceWorkerBootConfig boot -> do
      liftAssert "runService callback receives worker boot config" (bootConfigRole boot == Worker)
      liftAssert "runService callback receives live config" (liveConfigDrainDeadlineSeconds live == 30)
    ServiceOrchestratorBootConfig _ ->
      error "expected worker service config"
  modifyIORef' invoked (const True)

workerServiceArgs :: [String]
workerServiceArgs =
  [ "--role",
    "worker",
    "--boot-config",
    "dhall/worker.dhall",
    "--live-config",
    "dhall/live.dhall",
    "--lifecycle-policy",
    "dhall/lifecycle-policy.dhall"
  ]

replaceBootConfigPath :: FilePath -> [String] -> [String]
replaceBootConfigPath replacement args =
  case args of
    "--boot-config" : _old : remaining ->
      "--boot-config" : replacement : remaining
    item : remaining ->
      item : replaceBootConfigPath replacement remaining
    [] ->
      []

testPulsarAdminIdempotency :: IO ()
testPulsarAdminIdempotency =
  withFilesystemPulsar do
    let topic = TopicName "admin.topic"
    Right created <- PulsarAdmin.createTopic topic
    liftAssert "topic create changes first time" (PulsarAdmin.adminActionChanged created)
    Right createdAgain <- PulsarAdmin.createTopic topic
    liftAssert "topic create is idempotent" (not (PulsarAdmin.adminActionChanged createdAgain))
    Right configured <-
      PulsarAdmin.setRetention
        topic
        (PulsarAdmin.RetentionPolicy (Just 1024) (Just 60))
    liftAssert "retention changes first time" (PulsarAdmin.adminActionChanged configured)
    Right configuredAgain <-
      PulsarAdmin.setRetention
        topic
        (PulsarAdmin.RetentionPolicy (Just 1024) (Just 60))
    liftAssert "retention is idempotent" (not (PulsarAdmin.adminActionChanged configuredAgain))
    Right topics <- PulsarAdmin.listTopics
    liftAssert "listTopics includes created topic" (topic `elem` topics)

testPulsarAdminHttpPayloads :: IO ()
testPulsarAdminHttpPayloads = do
  liftAssert
    "retention body uses Pulsar admin JSON"
    ( PulsarAdminHttp.retentionPolicyBody
        (PulsarAdmin.RetentionPolicy (Just (2 * 1024 * 1024)) (Just 90))
        == "{\"retentionTimeInMinutes\":2,\"retentionSizeInMB\":2}"
    )
  liftAssert
    "retention body preserves admin unlimited sentinel"
    ( PulsarAdminHttp.retentionPolicyBody
        (PulsarAdmin.RetentionPolicy Nothing Nothing)
        == "{\"retentionTimeInMinutes\":-1,\"retentionSizeInMB\":-1}"
    )
  liftAssert
    "compaction body is numeric"
    (PulsarAdminHttp.compactionPolicyBody (PulsarAdmin.CompactionPolicy 1048576) == "1048576")
  liftAssert
    "dedup body is numeric"
    (PulsarAdminHttp.dedupWindowBody (PulsarAdmin.DedupWindow 300) == "300")

testPulsarNativeProtocolHelpers :: IO ()
testPulsarNativeProtocolHelpers = do
  let connect = Native.connectCommand "daemon-substrate-test"
      connectFrame = Native.PulsarFrame connect Nothing
  Right decodedConnect <- pure (Native.decodePulsarFrame (Native.encodePulsarFrame connectFrame))
  liftAssert "native connect frame round-trips" (decodedConnect == connectFrame)

  let subscription =
        Subscription
          { subscriptionTopic = TopicName "persistent://public/default/test",
            subscriptionName = SubscriptionName "worker",
            subscriptionMode = KeyShared
          }
      subscribe =
        Native.subscribeCommand
          subscription
          (Native.ConsumerId 7)
          "daemon-substrate-native-test"
          42
      payloadFrame =
        Native.PulsarFrame
          subscribe
          (Just (ByteString.Char8.pack "payload"))
  Right decodedPayload <- pure (Native.decodePulsarFrame (Native.encodePulsarFrame payloadFrame))
  liftAssert "native frame preserves payload bytes" (decodedPayload == payloadFrame)
  liftAssert
    "native subscribe includes consumer name"
    (subscribe ^. PulsarApi.subscribe . PulsarApi.consumerName == "daemon-substrate-native-test")

  let producer =
        Native.producerCommand
          (TopicName "persistent://public/default/test")
          (Native.ProducerId 9)
          43
      send = Native.sendCommand (Native.ProducerId 9) 1
      ack =
        Native.ackCommand
          (Native.ConsumerId 7)
          (MessageId 3 4)
  Right decodedProducer <-
    pure (Native.decodePulsarFrame (Native.encodePulsarFrame (Native.PulsarFrame producer Nothing)))
  Right decodedSend <-
    pure (Native.decodePulsarFrame (Native.encodePulsarFrame (Native.PulsarFrame send Nothing)))
  Right decodedAck <-
    pure (Native.decodePulsarFrame (Native.encodePulsarFrame (Native.PulsarFrame ack Nothing)))
  liftAssert "producer command frame round-trips" (Native.pulsarFrameCommand decodedProducer == producer)
  liftAssert "send command frame round-trips" (Native.pulsarFrameCommand decodedSend == send)
  liftAssert "ack command frame round-trips" (Native.pulsarFrameCommand decodedAck == ack)

  let metadata =
        Native.messageMetadata
          "producer"
          1
          1234
          ProducerMessage
            { producerKey = Just "key",
              producerPayload = ByteString.Char8.pack "payload",
              producerProperties = Map.singleton "property" "value",
              producerDeduplicationKey = Just "dedup"
            }
      nativePayload =
        Native.PulsarPayload
          { Native.pulsarPayloadMetadata = metadata,
            Native.pulsarPayloadBytes = ByteString.Char8.pack "payload"
          }
  Right decodedNativePayload <- pure (Native.decodePulsarPayload (Native.encodePulsarPayload nativePayload))
  liftAssert "native payload metadata and bytes round-trip" (decodedNativePayload == nativePayload)

  Left (PulsarBackendUnavailable invalidUrl) <-
    Native.runNativePulsarT
      ( Native.NativePulsar
          { Native.nativePulsarServiceUrl = "http://broker:6650",
            Native.nativePulsarOperationTimeoutMicros = 1000
          }
      )
      (pulsarSubscribe (TopicName "invalid-url") (SubscriptionName "worker") Shared)
  liftAssert "native invalid url is typed error" ("invalid Pulsar service URL" `Text.isPrefixOf` invalidUrl)

testMinIOStoreCacheAndAdmin :: IO ()
testMinIOStoreCacheAndAdmin =
  withFilesystemMinIO do
    let bucket = BucketName "bucket"
        ref = ObjectRef bucket (ObjectKey "blobs/direct")
        pointer = ObjectRef bucket (ObjectKey "pointers/current")
    Right True <- MinIOAdmin.createBucket bucket
    Right False <- MinIOAdmin.createBucket bucket
    Right etag <- putBlobIfAbsent ref (ByteString.Char8.pack "payload")
    Right body <- minioGet ref
    liftAssert "minio get returns bytes" (objectBodyBytes body == ByteString.Char8.pack "payload")
    liftAssert "etag round-trips" (objectBodyETag body == etag)
    Left (ObjectAlreadyExists _) <- putBlobIfAbsent ref (ByteString.Char8.pack "payload")
    Right pointerEtag <- casPointer pointer Nothing (ByteString.Char8.pack "v1")
    Left (ETagMismatch _) <- casPointer pointer Nothing (ByteString.Char8.pack "v2")
    Right _ <- casPointer pointer (Just pointerEtag) (ByteString.Char8.pack "v2")
    Right storedRef <- putBlob bucket (ByteString.Char8.pack "blob")
    Right storedBytes <- readBlob storedRef
    liftAssert "store readBlob returns putBlob payload" (storedBytes == ByteString.Char8.pack "blob")
    cache <- liftIO (newCache 256)
    Right cached <- readWithCache cache ref
    liftAssert "cache cold path returns payload" (cached == ByteString.Char8.pack "payload")
    pin cache ref
    pinned <- isPinned cache ref
    liftAssert "pin state round-trips" pinned
    unpin cache ref
    pinnedAfterUnpin <- isPinned cache ref
    liftAssert "unpin clears pin" (not pinnedAfterUnpin)
    let pinnedRef = ObjectRef bucket (ObjectKey "blobs/pinned")
        evictedRef = ObjectRef bucket (ObjectKey "blobs/evicted")
    Right _ <- putBlobIfAbsent pinnedRef (ByteString.Char8.pack "pinned")
    Right _ <- putBlobIfAbsent evictedRef (ByteString.Char8.pack "evict")
    smallCache <- liftIO (newCache 6)
    Right _ <- readWithCache smallCache pinnedRef
    pin smallCache pinnedRef
    Right _ <- readWithCache smallCache evictedRef
    Right () <- deleteObject pinnedRef
    Right () <- deleteObject evictedRef
    Right pinnedBytes <- readWithCache smallCache pinnedRef
    liftAssert "pinned object survives eviction pressure" (pinnedBytes == ByteString.Char8.pack "pinned")
    Left (ObjectNotFound _) <- readWithCache smallCache evictedRef
    Right keys <- MinIOAdmin.listObjectsByPrefix bucket "blobs/"
    liftAssert "prefix listing includes direct key" (ObjectKey "blobs/direct" `elem` keys)

testHarborFilesystem :: IO ()
testHarborFilesystem =
  withFilesystemHarbor do
    let image = ImageRef "registry.local/daemon-substrate-test:local"
    Right existsBefore <- harborImageExists image
    liftAssert "image does not exist initially" (not existsBefore)
    Right pushed <- harborPushImage image
    liftAssert "push changes first time" pushed
    Right pushedAgain <- harborPushImage image
    liftAssert "push is idempotent" (not pushedAgain)
    Right () <- harborPullImage image
    Right images <- harborListImages
    liftAssert "list images includes pushed image" (image `elem` images)

testMinIOSigV4Args :: IO ()
testMinIOSigV4Args = do
  let config =
        SubprocessMinIO
          { subprocessMinIOEndpoint = "http://minio.local:9000",
            subprocessMinIOCurl = "/usr/bin/curl",
            subprocessMinIOExtraCurlArgs = ["--silent"],
            subprocessMinIOSigV4 =
              Just
                SigV4Credentials
                  { sigV4AccessKey = "access",
                    sigV4SecretKey = "secret",
                    sigV4Region = "us-east-1",
                    sigV4Service = "s3"
                  }
          }
  liftAssert "sigv4 curl args are typed" ("--aws-sigv4" `elem` minioAuthArgs config)
  liftAssert
    "MinIO lifecycle body is S3 XML"
    ( "<Expiration><Days>7</Days></Expiration>"
        `Text.isInfixOf` Text.pack (bucketLifecycleBody (MinIOAdmin.BucketLifecycle "archive<bucket>" (Just 7)))
    )
  liftAssert
    "MinIO list parser extracts S3 keys"
    ( listObjectsKeys
        ( ByteString.Char8.pack
            "<ListBucketResult><Contents><Key>blobs/mock-weight</Key></Contents><Contents><Key>blobs/other</Key></Contents></ListBucketResult>"
        )
        == ["blobs/mock-weight", "blobs/other"]
    )
  liftAssert
    "base64 encoder matches standard vector"
    (base64Encode (ByteString.Char8.pack "abc") == "YWJj")

testKubectlFilesystem :: IO ()
testKubectlFilesystem =
  withFilesystemKubectl do
    let resource =
          KubernetesResource
            { kubernetesResourceName = ResourceName "deployment/daemon-substrate-test",
              kubernetesResourceBody = "kind: Deployment"
            }
        name = kubernetesResourceName resource
    Right applied <- kubectlApply resource
    liftAssert "apply changes first time" applied
    Right appliedAgain <- kubectlApply resource
    liftAssert "apply is idempotent" (not appliedAgain)
    Right status <- kubectlStatus name
    liftAssert "status reports ready" (resourceReady status)
    Right fetched <- kubectlGet name
    liftAssert "get returns applied resource" (fetched == resource)
    Right deleted <- kubectlDelete name
    liftAssert "delete reports existing resource" deleted
