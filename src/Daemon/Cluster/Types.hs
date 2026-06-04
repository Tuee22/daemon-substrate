module Daemon.Cluster.Types where

import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.Harbor (ImageRef)
import Daemon.Kubectl (KubernetesResource, ResourceName)

data ClusterCohort
  = AppleSilicon
  | LinuxCpu
  deriving stock (Eq, Show)

clusterCohortName :: ClusterCohort -> Text
clusterCohortName AppleSilicon = "apple-silicon"
clusterCohortName LinuxCpu = "linux-cpu"

data ClusterPaths = ClusterPaths
  { clusterBuildDir :: !FilePath,
    clusterDataDir :: !FilePath,
    clusterKubeconfigPath :: !FilePath,
    clusterEdgePortPath :: !FilePath
  }
  deriving stock (Eq, Show)

defaultClusterPaths :: ClusterCohort -> ClusterPaths
defaultClusterPaths cohort =
  case cohort of
    AppleSilicon ->
      ClusterPaths
        { clusterBuildDir = ".build",
          clusterDataDir = ".data",
          clusterKubeconfigPath = ".build/daemon-substrate.kubeconfig",
          clusterEdgePortPath = ".build/edge-port.json"
        }
    LinuxCpu ->
      ClusterPaths
        { clusterBuildDir = ".data/runtime",
          clusterDataDir = ".data",
          clusterKubeconfigPath = ".data/runtime/daemon-substrate.kubeconfig",
          clusterEdgePortPath = ".data/runtime/edge-port.json"
        }

data ClusterTool
  = KindTool
  | KubectlTool
  | HelmTool
  | DockerTool
  deriving stock (Eq, Show)

clusterToolName :: ClusterTool -> Text
clusterToolName KindTool = "kind"
clusterToolName KubectlTool = "kubectl"
clusterToolName HelmTool = "helm"
clusterToolName DockerTool = "docker"

data ClusterInvocation = ClusterInvocation
  { clusterInvocationTool :: !ClusterTool,
    clusterInvocationArguments :: ![Text],
    clusterInvocationInput :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data ClusterOperation
  = InvokeClusterTool !ClusterInvocation
  | ApplyKubernetesResource !KubernetesResource
  | WaitForKubernetesResource !ResourceName
  | PublishHarborImage !ImageRef
  | PulsarAdminOperation !Text
  | MinIOAdminOperation !Text
  | DiscoverEdgePort !Int !FilePath
  | PersistEdgePort !Int !FilePath
  | StartEdgePortForwards !FilePath
  | StopEdgePortForwards !FilePath
  deriving stock (Eq, Show)

data ClusterAction = ClusterAction
  { clusterActionName :: !Text,
    clusterActionDescription :: !Text,
    clusterActionOperation :: !ClusterOperation
  }
  deriving stock (Eq, Show)

clusterAction :: Text -> Text -> ClusterOperation -> ClusterAction
clusterAction name description operation =
  ClusterAction
    { clusterActionName = name,
      clusterActionDescription = description,
      clusterActionOperation = operation
    }

clusterActionNames :: [ClusterAction] -> [Text]
clusterActionNames = fmap clusterActionName

data ClusterPlan = ClusterPlan
  { clusterPlanCohort :: !ClusterCohort,
    clusterPlanActions :: ![ClusterAction]
  }
  deriving stock (Eq, Show)

emptyClusterPlan :: ClusterCohort -> ClusterPlan
emptyClusterPlan cohort =
  ClusterPlan
    { clusterPlanCohort = cohort,
      clusterPlanActions = []
    }

appendClusterPlan :: ClusterPlan -> [ClusterAction] -> ClusterPlan
appendClusterPlan plan actions =
  plan {clusterPlanActions = clusterPlanActions plan <> actions}

textShow :: (Show a) => a -> Text
textShow = Text.pack . show
