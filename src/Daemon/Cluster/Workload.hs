module Daemon.Cluster.Workload where

import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.Cluster.Types
import Daemon.Harbor
import Daemon.Kubectl

data WorkloadConfig = WorkloadConfig
  { workloadCohort :: !ClusterCohort,
    workloadNamespace :: !Text,
    workloadImage :: !ImageRef,
    workloadOrchestratorReplicas :: !Int,
    workloadWorkerEnabled :: !Bool,
    workloadWorkerReplicas :: !Int
  }
  deriving stock (Eq, Show)

defaultWorkloadConfig :: ClusterCohort -> WorkloadConfig
defaultWorkloadConfig cohort =
  WorkloadConfig
    { workloadCohort = cohort,
      workloadNamespace = "daemon-substrate-test",
      workloadImage = ImageRef "registry.local/daemon-substrate-test:local",
      workloadOrchestratorReplicas = 2,
      workloadWorkerEnabled = cohort == LinuxCpu,
      workloadWorkerReplicas = 2
    }

workloadPlan :: WorkloadConfig -> [ClusterAction]
workloadPlan config =
  [ waitAction "orchestrator-rollout" (ResourceName "deployment/daemon-substrate-test-orchestrator")
  ]
    <> if workloadWorkerEnabled config
      then [waitAction "worker-rollout" (ResourceName "deployment/daemon-substrate-test-worker")]
      else []

workloadResources :: WorkloadConfig -> [KubernetesResource]
workloadResources config =
  [ configMapResource "daemon-substrate-orchestrator-config" "orchestrator.dhall",
    orchestratorDeploymentResource config
  ]
    <> if workloadWorkerEnabled config
      then
        [ configMapResource "daemon-substrate-worker-config" "worker.dhall",
          workerDeploymentResource config
        ]
      else []

configMapResource :: Text -> Text -> KubernetesResource
configMapResource name fileName =
  KubernetesResource
    { kubernetesResourceName = ResourceName ("configmap/" <> name),
      kubernetesResourceBody =
        Text.unlines
          [ "apiVersion: v1",
            "kind: ConfigMap",
            "metadata:",
            "  name: " <> name,
            "data:",
            "  " <> fileName <> ": |",
            "    ${" <> fileName <> "}"
          ]
    }

orchestratorDeploymentResource :: WorkloadConfig -> KubernetesResource
orchestratorDeploymentResource config =
  deploymentResource
    "daemon-substrate-test-orchestrator"
    (workloadOrchestratorReplicas config)
    (workloadImage config)
    ["service", "--role", "orchestrator", "--config", "/etc/daemon-substrate/orchestrator.dhall"]
    []

workerDeploymentResource :: WorkloadConfig -> KubernetesResource
workerDeploymentResource config =
  deploymentResource
    "daemon-substrate-test-worker"
    (workloadWorkerReplicas config)
    (workloadImage config)
    ["service", "--role", "worker", "--config", "/etc/daemon-substrate/worker.dhall"]
    workerAntiAffinity

deploymentResource :: Text -> Int -> ImageRef -> [Text] -> [Text] -> KubernetesResource
deploymentResource name replicas image command antiAffinity =
  KubernetesResource
    { kubernetesResourceName = ResourceName ("deployment/" <> name),
      kubernetesResourceBody =
        Text.unlines
          ( [ "apiVersion: apps/v1",
              "kind: Deployment",
              "metadata:",
              "  name: " <> name,
              "spec:",
              "  replicas: " <> textShow replicas,
              "  selector:",
              "    matchLabels:",
              "      app: " <> name,
              "  template:",
              "    metadata:",
              "      labels:",
              "        app: " <> name,
              "    spec:",
              "      containers:",
              "        - name: daemon-substrate-test",
              "          image: " <> unImageRef image,
              "          args:"
            ]
              <> fmap ("            - " <>) command
              <> antiAffinity
          )
    }

workerAntiAffinity :: [Text]
workerAntiAffinity =
  [ "      affinity:",
    "        podAntiAffinity:",
    "          requiredDuringSchedulingIgnoredDuringExecution:",
    "            - labelSelector:",
    "                matchLabels:",
    "                  app: daemon-substrate-test-worker",
    "              topologyKey: kubernetes.io/hostname"
  ]

applyResource :: KubernetesResource -> ClusterAction
applyResource resource =
  clusterAction
    ("apply-" <> unResourceName (kubernetesResourceName resource))
    "Apply a workload Kubernetes resource."
    (ApplyKubernetesResource resource)

waitAction :: Text -> ResourceName -> ClusterAction
waitAction name resource =
  clusterAction
    name
    "Wait for workload readiness."
    (WaitForKubernetesResource resource)
