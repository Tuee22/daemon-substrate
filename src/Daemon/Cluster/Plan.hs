module Daemon.Cluster.Plan where

import Daemon.Cluster.EdgePort
import Daemon.Cluster.Harbor
import Daemon.Cluster.Helm
import Daemon.Cluster.Kind
import Daemon.Cluster.MinIO
import Daemon.Cluster.Pulsar
import Daemon.Cluster.Storage
import Daemon.Cluster.Types
import Daemon.Cluster.Workload

data ClusterBringupConfig = ClusterBringupConfig
  { clusterBringupCohort :: !ClusterCohort,
    clusterBringupPaths :: !ClusterPaths,
    clusterBringupKind :: !KindConfig,
    clusterBringupStorage :: !StorageConfig,
    clusterBringupHelm :: !HelmConfig,
    clusterBringupHarbor :: !HarborBootstrapConfig,
    clusterBringupPulsar :: !PulsarBootstrapConfig,
    clusterBringupMinIO :: !MinIOBootstrapConfig,
    clusterBringupWorkload :: !WorkloadConfig,
    clusterBringupEdgePort :: !EdgePortConfig
  }
  deriving stock (Eq, Show)

defaultClusterBringupConfig :: ClusterCohort -> ClusterBringupConfig
defaultClusterBringupConfig cohort =
  ClusterBringupConfig
    { clusterBringupCohort = cohort,
      clusterBringupPaths = paths,
      clusterBringupKind = defaultKindConfig cohort paths,
      clusterBringupStorage = defaultStorageConfig cohort paths,
      clusterBringupHelm = defaultHelmConfig cohort,
      clusterBringupHarbor = defaultHarborBootstrapConfig,
      clusterBringupPulsar = defaultPulsarBootstrapConfig,
      clusterBringupMinIO = defaultMinIOBootstrapConfig,
      clusterBringupWorkload = defaultWorkloadConfig cohort,
      clusterBringupEdgePort = defaultEdgePortConfig paths
    }
  where
    paths = defaultClusterPaths cohort

clusterBringupPlan :: ClusterBringupConfig -> ClusterPlan
clusterBringupPlan config =
  ClusterPlan
    { clusterPlanCohort = clusterBringupCohort config,
      clusterPlanActions =
        kindCreatePlan (clusterBringupKind config)
          <> storageReconcilePlan (clusterBringupStorage config)
          <> harborImagePlan (clusterBringupHarbor config)
          <> helmRolloutPlan (clusterBringupHelm config)
          <> harborReadinessPlan (clusterBringupHarbor config)
          <> pulsarBootstrapPlan (clusterBringupPulsar config)
          <> minIOBootstrapPlan (clusterBringupMinIO config)
          <> workloadPlan (clusterBringupWorkload config)
          <> edgePortDiscoveryPlan (clusterBringupEdgePort config)
          <> appleOnly (edgePortForwardPlan (clusterBringupEdgePort config))
    }
  where
    appleOnly actions =
      case clusterBringupCohort config of
        AppleSilicon -> actions
        LinuxCpu -> []

clusterTeardownPlan :: ClusterBringupConfig -> ClusterPlan
clusterTeardownPlan config =
  ClusterPlan
    { clusterPlanCohort = clusterBringupCohort config,
      clusterPlanActions =
        appleOnly (edgePortStopPlan (clusterBringupEdgePort config))
          <> kindDeletePlan (clusterBringupKind config)
    }
  where
    appleOnly actions =
      case clusterBringupCohort config of
        AppleSilicon -> actions
        LinuxCpu -> []

clusterStatusPlan :: ClusterBringupConfig -> ClusterPlan
clusterStatusPlan config =
  ClusterPlan
    { clusterPlanCohort = clusterBringupCohort config,
      clusterPlanActions = kindStatusPlan (clusterBringupKind config)
    }
