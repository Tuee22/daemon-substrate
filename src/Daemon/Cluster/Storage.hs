module Daemon.Cluster.Storage where

import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.Cluster.Kind (kindDataMountRoot)
import Daemon.Cluster.Types
import Daemon.Kubectl

data PersistentVolumeSpec = PersistentVolumeSpec
  { persistentVolumeName :: !Text,
    persistentVolumeCapacityGi :: !Int,
    persistentVolumeHostPath :: !FilePath
  }
  deriving stock (Eq, Show)

data StorageConfig = StorageConfig
  { storageClassName :: !Text,
    storagePersistentVolumes :: ![PersistentVolumeSpec]
  }
  deriving stock (Eq, Show)

defaultStorageConfig :: ClusterCohort -> ClusterPaths -> StorageConfig
defaultStorageConfig cohort _paths =
  StorageConfig
    { storageClassName = "daemon-substrate-manual",
      storagePersistentVolumes =
        [ PersistentVolumeSpec "daemon-substrate-harbor" 10 (root </> "harbor"),
          PersistentVolumeSpec "daemon-substrate-pulsar" 10 (root </> "pulsar"),
          PersistentVolumeSpec "daemon-substrate-minio" 10 (root </> "minio")
        ]
    }
  where
    root = kindDataMountRoot cohort
    (</>) left right = left <> "/" <> right

storageReconcilePlan :: StorageConfig -> [ClusterAction]
storageReconcilePlan config =
  clusterAction
    "storage-class"
    "Apply the manual StorageClass before any PersistentVolume."
    (ApplyKubernetesResource (manualStorageClassResource config))
    : fmap (persistentVolumeAction config) (storagePersistentVolumes config)

manualStorageClassResource :: StorageConfig -> KubernetesResource
manualStorageClassResource config =
  KubernetesResource
    { kubernetesResourceName = ResourceName ("storageclass/" <> storageClassName config),
      kubernetesResourceBody =
        Text.unlines
          [ "apiVersion: storage.k8s.io/v1",
            "kind: StorageClass",
            "metadata:",
            "  name: " <> storageClassName config,
            "provisioner: kubernetes.io/no-provisioner",
            "volumeBindingMode: WaitForFirstConsumer"
          ]
    }

persistentVolumeResource :: StorageConfig -> PersistentVolumeSpec -> KubernetesResource
persistentVolumeResource config volume =
  KubernetesResource
    { kubernetesResourceName = ResourceName ("persistentvolume/" <> persistentVolumeName volume),
      kubernetesResourceBody =
        Text.unlines
          [ "apiVersion: v1",
            "kind: PersistentVolume",
            "metadata:",
            "  name: " <> persistentVolumeName volume,
            "spec:",
            "  capacity:",
            "    storage: " <> textShow (persistentVolumeCapacityGi volume) <> "Gi",
            "  accessModes:",
            "    - ReadWriteOnce",
            "  storageClassName: " <> storageClassName config,
            "  hostPath:",
            "    path: " <> Text.pack (persistentVolumeHostPath volume)
          ]
    }

persistentVolumeAction :: StorageConfig -> PersistentVolumeSpec -> ClusterAction
persistentVolumeAction config volume =
  clusterAction
    ("persistent-volume-" <> persistentVolumeName volume)
    "Apply a manual PersistentVolume backed by repo-local durable state."
    (ApplyKubernetesResource (persistentVolumeResource config volume))
