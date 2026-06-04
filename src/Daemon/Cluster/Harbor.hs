module Daemon.Cluster.Harbor where

import Daemon.Cluster.Types
import Daemon.Harbor
import Daemon.Kubectl
import Data.Text (Text)

data HarborBootstrapConfig = HarborBootstrapConfig
    { harborNamespace :: !Text
    , harborCoreResource :: !ResourceName
    , harborImageRef :: !ImageRef
    }
    deriving stock (Eq, Show)

defaultHarborBootstrapConfig :: HarborBootstrapConfig
defaultHarborBootstrapConfig =
    HarborBootstrapConfig
        { harborNamespace = "default"
        , harborCoreResource = ResourceName "statefulset/daemon-substrate-test-harbor"
        , harborImageRef = ImageRef "daemon-substrate-test:local"
        }

harborBootstrapPlan :: HarborBootstrapConfig -> [ClusterAction]
harborBootstrapPlan config =
    harborImagePlan config <> harborReadinessPlan config

harborImagePlan :: HarborBootstrapConfig -> [ClusterAction]
harborImagePlan config =
    [ clusterAction
        "harbor-publish-image"
        "Build the local daemon-substrate-test image and load it into kind."
        (PublishHarborImage (harborImageRef config))
    ]

harborReadinessPlan :: HarborBootstrapConfig -> [ClusterAction]
harborReadinessPlan config =
    [ clusterAction
        "harbor-wait"
        "Wait for the harness registry dependency to become ready."
        (WaitForKubernetesResource (harborCoreResource config))
    ]
