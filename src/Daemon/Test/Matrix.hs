module Daemon.Test.Matrix where

import Daemon.Cluster.Types
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import System.FilePath (takeDirectory, (</>))

data HarnessExecutionModel
  = ExecutionContainer
  | ExecutionHostBinary
  | ExecutionHostDaemon
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data WorkerPlacement
  = InClusterWorker
  | HostNativeWorker
  deriving stock (Eq, Show)

data WorkflowArchetype
  = ContinuousBatchedInference
  | FiniteTrainingJob
  | ContinuousOnlineRL
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data HarnessMatrixCase = HarnessMatrixCase
  { matrixExecutionModel :: !HarnessExecutionModel,
    matrixWorkflowArchetype :: !WorkflowArchetype,
    matrixAuditRows :: ![Int]
  }
  deriving stock (Eq, Show)

allExecutionModels :: [HarnessExecutionModel]
allExecutionModels = [minBound .. maxBound]

allWorkflowArchetypes :: [WorkflowArchetype]
allWorkflowArchetypes = [minBound .. maxBound]

harnessMatrixCases :: [HarnessMatrixCase]
harnessMatrixCases =
  [ HarnessMatrixCase
      { matrixExecutionModel = model,
        matrixWorkflowArchetype = archetype,
        matrixAuditRows = workflowArchetypeAuditRows archetype
      }
    | model <- allExecutionModels,
      archetype <- allWorkflowArchetypes
  ]

matrixCaseCount :: Int
matrixCaseCount = length harnessMatrixCases

matrixCoversEveryPair :: Bool
matrixCoversEveryPair =
  length pairs == length (nub pairs)
    && length pairs == length allExecutionModels * length allWorkflowArchetypes
  where
    pairs =
      [ (matrixExecutionModel testCase, matrixWorkflowArchetype testCase)
        | testCase <- harnessMatrixCases
      ]

executionModelName :: HarnessExecutionModel -> Text
executionModelName model =
  case model of
    ExecutionContainer -> "container"
    ExecutionHostBinary -> "host-binary"
    ExecutionHostDaemon -> "host-daemon"

parseExecutionModel :: Text -> Maybe HarnessExecutionModel
parseExecutionModel raw =
  case Text.strip (Text.toLower raw) of
    "container" -> Just ExecutionContainer
    "host-binary" -> Just ExecutionHostBinary
    "hostbinary" -> Just ExecutionHostBinary
    "host-daemon" -> Just ExecutionHostDaemon
    "hostdaemon" -> Just ExecutionHostDaemon
    _ -> Nothing

executionModelForHostbootstrapTarget :: Text -> Maybe HarnessExecutionModel
executionModelForHostbootstrapTarget raw =
  case Text.strip (Text.toLower raw) of
    "apple-silicon" -> Just ExecutionHostDaemon
    "linux-cpu" -> Just ExecutionContainer
    "linux-gpu" -> Just ExecutionContainer
    _ -> Nothing

executionModelWorkerPlacement :: HarnessExecutionModel -> WorkerPlacement
executionModelWorkerPlacement model =
  case model of
    ExecutionContainer -> InClusterWorker
    ExecutionHostBinary -> InClusterWorker
    ExecutionHostDaemon -> HostNativeWorker

executionModelClusterCohort :: HarnessExecutionModel -> ClusterCohort
executionModelClusterCohort model =
  case executionModelWorkerPlacement model of
    InClusterWorker -> LinuxCpu
    HostNativeWorker -> AppleSilicon

executionModelClusterPaths :: HarnessExecutionModel -> ClusterPaths
executionModelClusterPaths model =
  case model of
    ExecutionContainer -> defaultClusterPaths LinuxCpu
    ExecutionHostBinary -> hostPaths
    ExecutionHostDaemon -> hostPaths
  where
    hostPaths =
      ClusterPaths
        { clusterBuildDir = ".build",
          clusterDataDir = ".data",
          clusterKubeconfigPath = ".build/daemon-substrate.kubeconfig",
          clusterEdgePortPath = ".build/edge-port.json"
        }

executionModelRecordPath :: ClusterPaths -> FilePath
executionModelRecordPath paths =
  takeDirectory (clusterEdgePortPath paths) </> "execution-model"

workflowArchetypeName :: WorkflowArchetype -> Text
workflowArchetypeName archetype =
  case archetype of
    ContinuousBatchedInference -> "continuous-batched-inference"
    FiniteTrainingJob -> "finite-training-job"
    ContinuousOnlineRL -> "continuous-online-rl"

workflowArchetypeAuditRows :: WorkflowArchetype -> [Int]
workflowArchetypeAuditRows archetype =
  case archetype of
    ContinuousBatchedInference ->
      [3, 4, 8, 10, 11, 12, 13, 14, 15, 26, 33, 34, 35, 36]
    FiniteTrainingJob ->
      [3, 4, 6, 7, 8, 13, 14, 27, 29, 30, 31, 32, 33, 34, 35, 36]
    ContinuousOnlineRL ->
      [3, 4, 6, 7, 13, 14, 21, 22, 28, 29, 30, 31, 32, 33, 34, 35]
