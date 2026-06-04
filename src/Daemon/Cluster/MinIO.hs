module Daemon.Cluster.MinIO where

import Data.Text (Text)
import Daemon.Cluster.Types
import Daemon.Kubectl
import Daemon.MinIO

data SeedObject = SeedObject
  { seedObjectRef :: !ObjectRef,
    seedObjectDescription :: !Text
  }
  deriving stock (Eq, Show)

data MinIOBootstrapConfig = MinIOBootstrapConfig
  { minIONamespace :: !Text,
    minIOResource :: !ResourceName,
    minIOBuckets :: ![BucketName],
    minIOSeedObjects :: ![SeedObject]
  }
  deriving stock (Eq, Show)

defaultMinIOBootstrapConfig :: MinIOBootstrapConfig
defaultMinIOBootstrapConfig =
  MinIOBootstrapConfig
    { minIONamespace = "default",
      minIOResource = ResourceName "statefulset/daemon-substrate-test-minio",
      minIOBuckets =
        [ BucketName "daemon-substrate-test-weights",
          BucketName "daemon-substrate-test-artifacts",
          BucketName "daemon-substrate-test-archives"
        ],
      minIOSeedObjects =
        [ SeedObject
            (ObjectRef (BucketName "daemon-substrate-test-weights") (ObjectKey "blobs/mock-weight"))
            "deterministic mock weight blob"
        ]
    }

minIOBootstrapPlan :: MinIOBootstrapConfig -> [ClusterAction]
minIOBootstrapPlan config =
  [ clusterAction
      "minio-wait"
      "Wait for MinIO readiness before bucket creation and object seeding."
      (WaitForKubernetesResource (minIOResource config))
  ]
    <> fmap bucketAction (minIOBuckets config)
    <> fmap seedAction (minIOSeedObjects config)

bucketAction :: BucketName -> ClusterAction
bucketAction bucket =
  clusterAction
    ("minio-bucket-" <> unBucketName bucket)
    "Ensure a required MinIO bucket exists."
    (MinIOAdminOperation ("create bucket " <> unBucketName bucket))

seedAction :: SeedObject -> ClusterAction
seedAction seed =
  clusterAction
    ("minio-seed-" <> unObjectKey (objectRefKey (seedObjectRef seed)))
    ("Seed " <> seedObjectDescription seed <> ".")
    (MinIOAdminOperation ("put object " <> objectRefText (seedObjectRef seed)))

objectRefText :: ObjectRef -> Text
objectRefText ref = unBucketName (objectRefBucket ref) <> "/" <> unObjectKey (objectRefKey ref)
