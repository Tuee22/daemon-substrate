{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Daemon.Test.CLI.Service where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO
import Daemon.Config.BootConfig
import Daemon.Config.LifecyclePolicy
import Daemon.Config.LiveConfig
import Daemon.Cluster.EdgePort
import Daemon.Engine
import Daemon.Lifecycle
import Daemon.MinIO
import qualified Daemon.MinIO.Admin as MinIOAdmin
import Daemon.MinIO.Subprocess
import Daemon.Orchestrator
import Daemon.Pulsar
import qualified Daemon.Pulsar.Admin as PulsarAdmin
import Daemon.Pulsar.Admin.Http
import qualified Daemon.Pulsar.Native as Native
import Daemon.Reconciler
import Daemon.Test.CLI.Types
import Daemon.Topology.Types
import Daemon.Worker
import qualified Dhall
import GHC.Generics (Generic)
import System.Directory (findExecutable)
import System.IO (hFlush, stdout)

data HarnessWorkerTopic = HarnessWorkerTopic
  { harnessWorkerTopicCohort :: !Dhall.Text,
    harnessWorkerTopicName :: !Dhall.Text
  }
  deriving stock (Eq, Show, Generic)

instance Dhall.FromDhall HarnessWorkerTopic

data HarnessOrchestratorApp = HarnessOrchestratorApp
  { harnessOrchestratorIngressTopic :: !Dhall.Text,
    harnessOrchestratorResultTopic :: !Dhall.Text,
    harnessOrchestratorResponseTopic :: !Dhall.Text,
    harnessOrchestratorControlTopic :: !Dhall.Text,
    harnessOrchestratorAuditTopic :: !Dhall.Text,
    harnessOrchestratorLifecyclePolicyPath :: !Dhall.Text,
    harnessOrchestratorLiveConfigPath :: !Dhall.Text,
    harnessOrchestratorWorkerTopics :: ![HarnessWorkerTopic]
  }
  deriving stock (Eq, Show, Generic)

instance Dhall.FromDhall HarnessOrchestratorApp

data HarnessWorkerApp = HarnessWorkerApp
  { harnessWorkerCohort :: !Dhall.Text,
    harnessWorkerWorkTopic :: !Dhall.Text,
    harnessWorkerResultTopic :: !Dhall.Text,
    harnessWorkerControlTopic :: !Dhall.Text,
    harnessWorkerCacheDirectory :: !Dhall.Text
  }
  deriving stock (Eq, Show, Generic)

instance Dhall.FromDhall HarnessWorkerApp

data HarnessRuntime = HarnessRuntime
  { harnessRuntimePulsar :: !Native.NativePulsar,
    harnessRuntimePulsarAdmin :: !PulsarAdminHttp,
    harnessRuntimeMinIO :: !SubprocessMinIO
  }
  deriving stock (Eq, Show)

newtype HarnessRuntimeT a = HarnessRuntimeT
  {unHarnessRuntimeT :: ReaderT HarnessRuntime IO a}
  deriving newtype (Functor, Applicative, Monad, MonadIO)

runHarnessRuntimeT :: HarnessRuntime -> HarnessRuntimeT a -> IO a
runHarnessRuntimeT runtime action =
  runReaderT (unHarnessRuntimeT action) runtime

instance HasPulsar HarnessRuntimeT where
  pulsarPublish topic message =
    runNativePulsarAction (pulsarPublish topic message)
  pulsarSubscribe topic name mode =
    runNativePulsarAction (pulsarSubscribe topic name mode)
  pulsarWaitActive subscription =
    runNativePulsarAction (pulsarWaitActive subscription)
  pulsarConsume subscription =
    runNativePulsarAction (pulsarConsume subscription)
  pulsarAcknowledge subscription messageId =
    runNativePulsarAction (pulsarAcknowledge subscription messageId)
  pulsarNegativeAcknowledge subscription messageId =
    runNativePulsarAction (pulsarNegativeAcknowledge subscription messageId)
  pulsarSeek subscription target =
    runNativePulsarAction (pulsarSeek subscription target)

instance PulsarAdmin.HasPulsarAdmin HarnessRuntimeT where
  createTopic topic =
    runPulsarAdminAction (PulsarAdmin.createTopic topic)
  deleteTopic topic =
    runPulsarAdminAction (PulsarAdmin.deleteTopic topic)
  terminateTopic topic =
    runPulsarAdminAction (PulsarAdmin.terminateTopic topic)
  setRetention topic policy =
    runPulsarAdminAction (PulsarAdmin.setRetention topic policy)
  setCompaction topic policy =
    runPulsarAdminAction (PulsarAdmin.setCompaction topic policy)
  setDedupWindow topic window =
    runPulsarAdminAction (PulsarAdmin.setDedupWindow topic window)
  listTopics =
    runPulsarAdminAction PulsarAdmin.listTopics
  exportTopicToObject topic objectRef =
    runPulsarAdminAction (PulsarAdmin.exportTopicToObject topic objectRef)
  importTopicFromObject topic objectRef =
    runPulsarAdminAction (PulsarAdmin.importTopicFromObject topic objectRef)

instance HasMinIO HarnessRuntimeT where
  minioGet ref =
    runMinIOAction (minioGet ref)
  putBlobIfAbsent ref bytes =
    runMinIOAction (putBlobIfAbsent ref bytes)
  casPointer ref expected bytes =
    runMinIOAction (casPointer ref expected bytes)
  listObjects bucket prefix =
    runMinIOAction (listObjects bucket prefix)
  deleteObject ref =
    runMinIOAction (deleteObject ref)

instance MinIOAdmin.HasMinIOAdmin HarnessRuntimeT where
  createBucket bucket =
    runMinIOAction (MinIOAdmin.createBucket bucket)
  setBucketLifecycle bucket lifecycle =
    runMinIOAction (MinIOAdmin.setBucketLifecycle bucket lifecycle)
  listBuckets =
    runMinIOAction MinIOAdmin.listBuckets
  listObjectsByPrefix bucket prefix =
    runMinIOAction (MinIOAdmin.listObjectsByPrefix bucket prefix)
  deleteObjectAdmin ref =
    runMinIOAction (MinIOAdmin.deleteObjectAdmin ref)

instance HasEngine HarnessRuntimeT where
  engineCall requests =
    pure (Right . echoResponse <$> requests)

runNativePulsarAction :: Native.NativePulsarT IO a -> HarnessRuntimeT a
runNativePulsarAction action = do
  runtime <- HarnessRuntimeT ask
  liftIO (Native.runNativePulsarT (harnessRuntimePulsar runtime) action)

runPulsarAdminAction :: PulsarAdminHttpT IO a -> HarnessRuntimeT a
runPulsarAdminAction action = do
  runtime <- HarnessRuntimeT ask
  liftIO (runPulsarAdminHttpT (harnessRuntimePulsarAdmin runtime) action)

runMinIOAction :: SubprocessMinIOT IO a -> HarnessRuntimeT a
runMinIOAction action = do
  runtime <- HarnessRuntimeT ask
  liftIO (runSubprocessMinIOT (harnessRuntimeMinIO runtime) action)

runHarnessService :: ServiceCommand -> IO (Either RunServiceError ())
runHarnessService command =
  case serviceCommandRole command of
    ServiceWorkerArg ->
      runServiceWithArgs (serviceArgs "worker" command) workerCallback
    ServiceOrchestratorArg ->
      runServiceWithArgs (serviceArgs "orchestrator" command) orchestratorCallback

serviceArgs :: String -> ServiceCommand -> [String]
serviceArgs role command =
  [ "--role",
    role,
    "--boot-config",
    serviceCommandConfigPath command,
    "--live-config",
    serviceCommandLiveConfigPath command,
    "--lifecycle-policy",
    serviceCommandLifecyclePolicyPath command
  ]

workerCallback :: ServiceBootConfig HarnessWorkerApp -> LiveConfig -> IO ()
workerCallback serviceBoot _live =
  case serviceBoot of
    ServiceWorkerBootConfig boot ->
      runHarnessWorkerLoop boot
    ServiceOrchestratorBootConfig _ ->
      fail "expected worker boot config"

orchestratorCallback :: ServiceBootConfig HarnessOrchestratorApp -> LiveConfig -> IO ()
orchestratorCallback serviceBoot _live =
  case serviceBoot of
    ServiceOrchestratorBootConfig boot ->
      runHarnessOrchestratorLoop boot
    ServiceWorkerBootConfig _ ->
      fail "expected orchestrator boot config"

runHarnessWorkerLoop :: BootConfig WorkerRole HarnessWorkerApp -> IO ()
runHarnessWorkerLoop boot0 = do
  boot <- hostWorkerBootConfig boot0
  runtime <- harnessRuntimeFromBoot boot
  let app = bootConfigApp boot
      options =
        workerOptions
          (harnessTopicName (harnessWorkerWorkTopic app))
          (SubscriptionName ("daemon-substrate-worker-" <> harnessWorkerCohort app))
          (harnessTopicName (harnessWorkerResultTopic app))
          "application/octet-stream"
  putStatus ("worker ready: " <> harnessWorkerCohort app)
  forever do
    result <- runHarnessRuntimeT runtime (runWorker options)
    putStatus ("worker step: " <> Text.pack (show result))
    threadDelay (loopDelayMicros result)

hostWorkerBootConfig :: BootConfig WorkerRole HarnessWorkerApp -> IO (BootConfig WorkerRole HarnessWorkerApp)
hostWorkerBootConfig boot
  | harnessWorkerCohort (bootConfigApp boot) /= "apple-silicon" =
      pure boot
  | otherwise = do
      edge <- readEdgePortRecord ".build/edge-port.json"
      case edge of
        Left err -> fail ("edge port record unavailable for Apple host worker: " <> show err)
        Right ports ->
          pure
            boot
              { bootConfigPulsarServiceUrl =
                  "pulsar://127.0.0.1:" <> Text.pack (show (edgePortRecordPulsarPort ports)),
                bootConfigPulsarAdminUrl =
                  "http://127.0.0.1:" <> Text.pack (show (edgePortRecordPulsarAdminPort ports)),
                bootConfigMinIOEndpoint =
                  "http://127.0.0.1:" <> Text.pack (show (edgePortRecordMinIOPort ports))
              }

runHarnessOrchestratorLoop :: BootConfig OrchestratorRole HarnessOrchestratorApp -> IO ()
runHarnessOrchestratorLoop boot = do
  runtime <- harnessRuntimeFromBoot boot
  policyResult <- decodeLifecyclePolicyFile (Text.unpack (harnessOrchestratorLifecyclePolicyPath (bootConfigApp boot)))
  policy <-
    case policyResult of
      Left err -> fail ("LifecyclePolicy decode failed: " <> show err)
      Right value -> pure (normalizeHarnessLifecyclePolicy value)
  (workerTopic, workerCohort) <-
    case harnessOrchestratorWorkerTopics (bootConfigApp boot) of
      [] -> fail "orchestrator requires at least one worker topic"
      firstTopic : _ ->
        pure
          ( harnessTopicName (harnessWorkerTopicName firstTopic),
            harnessWorkerTopicCohort firstTopic
          )
  let app = bootConfigApp boot
      ingress = harnessTopicName (harnessOrchestratorIngressTopic app)
      resultTopic = harnessTopicName (harnessOrchestratorResultTopic app)
      responseTopic = harnessTopicName (harnessOrchestratorResponseTopic app)
      topology =
        Topology
          { topologyName = "daemon-substrate-test",
            topologyTopics = TopologyTopic <$> [ingress, resultTopic, responseTopic, workerTopic],
            topologySubscriptions = []
          }
      options =
        orchestratorOptions
          topology
          ingress
          (SubscriptionName "daemon-substrate-orchestrator-ingress")
          resultTopic
          (SubscriptionName "daemon-substrate-orchestrator-results")
          workerTopic
          responseTopic
          workerCohort
  putStatus ("orchestrator ready: " <> harnessOrchestratorIngressTopic app)
  forever do
    orchestratorResult <- runHarnessRuntimeT runtime (runOrchestrator options)
    reconcilerResult <- runHarnessRuntimeT runtime (runReconciler policy)
    putStatus ("orchestrator step: " <> Text.pack (show orchestratorResult))
    putStatus ("reconciler step: " <> Text.pack (show reconcilerResult))
    threadDelay (loopDelayMicros orchestratorResult)

putStatus :: Text -> IO ()
putStatus message = do
  Text.IO.putStrLn message
  hFlush stdout

harnessRuntimeFromBoot :: BootConfig r app -> IO HarnessRuntime
harnessRuntimeFromBoot boot = do
  curlPath <- findExecutable "curl"
  curl <-
    case curlPath of
      Just path -> pure path
      Nothing -> fail "curl executable not found on PATH"
  pure
    HarnessRuntime
      { harnessRuntimePulsar =
          Native.NativePulsar
            { Native.nativePulsarServiceUrl = bootConfigPulsarServiceUrl boot,
              Native.nativePulsarOperationTimeoutMicros = 1000000
            },
        harnessRuntimePulsarAdmin =
          PulsarAdminHttp
            { pulsarAdminBaseUrl = bootConfigPulsarAdminUrl boot,
              pulsarAdminTimeoutMicros = 1000000,
              pulsarAdminBearerToken = Nothing
            },
        harnessRuntimeMinIO =
          SubprocessMinIO
            { subprocessMinIOEndpoint = bootConfigMinIOEndpoint boot,
              subprocessMinIOCurl = curl,
              subprocessMinIOExtraCurlArgs = ["--silent", "--show-error"],
              subprocessMinIOSigV4 =
                Just
                  SigV4Credentials
                    { sigV4AccessKey = "minioadmin",
                      sigV4SecretKey = "minioadmin",
                      sigV4Region = "us-east-1",
                      sigV4Service = "s3"
                    }
            }
      }

harnessTopicName :: Text -> TopicName
harnessTopicName raw
  | "persistent://" `Text.isPrefixOf` raw = TopicName raw
  | otherwise = TopicName ("persistent://daemon-substrate-test/workflows/" <> raw)

normalizeHarnessLifecyclePolicy :: LifecyclePolicy -> LifecyclePolicy
normalizeHarnessLifecyclePolicy policy =
  policy
    { lifecyclePolicyTopics = normalizeEntry <$> lifecyclePolicyTopics policy,
      lifecyclePolicyAuditTopic = normalizeTopic (lifecyclePolicyAuditTopic policy),
      lifecyclePolicyLeaderControlTopic = normalizeTopic (lifecyclePolicyLeaderControlTopic policy)
    }
  where
    normalizeEntry entry =
      entry
        { topicLifecycleEntryTopic = normalizeTopic (topicLifecycleEntryTopic entry),
          topicLifecycleEntryLifecycle = normalizeLifecycle (topicLifecycleEntryLifecycle entry)
        }
    normalizeLifecycle lifecycle =
      case lifecycle of
        FiniteSession controlTopic export archiveBucket archivePrefix reopen ->
          FiniteSession (normalizeTopic controlTopic) export archiveBucket archivePrefix reopen
        _ -> lifecycle
    normalizeTopic =
      harnessTopicName . unTopicName

loopDelayMicros :: Either err step -> Int
loopDelayMicros result =
  case result of
    Right _ -> 100000
    Left _ -> 1000000
