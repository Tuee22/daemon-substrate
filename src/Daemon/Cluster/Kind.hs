module Daemon.Cluster.Kind where

import Daemon.Cluster.Types
import Data.Text (Text)
import Data.Text qualified as Text

data KindConfig = KindConfig
    { kindClusterName :: !Text
    , kindCohort :: !ClusterCohort
    , kindWorkerNodeCount :: !Int
    , kindImage :: !(Maybe Text)
    , kindKubeconfigPath :: !FilePath
    , kindDataMountHostPath :: !FilePath
    , kindDataMountContainerPath :: !FilePath
    }
    deriving stock (Eq, Show)

defaultKindConfig :: ClusterCohort -> ClusterPaths -> KindConfig
defaultKindConfig cohort paths =
    KindConfig
        { kindClusterName = "daemon-substrate-" <> clusterCohortName cohort
        , kindCohort = cohort
        , kindWorkerNodeCount = defaultKindWorkerNodeCount cohort
        , kindImage = Nothing
        , kindKubeconfigPath = clusterKubeconfigPath paths
        , kindDataMountHostPath = clusterDataDir paths <> "/kind/" <> Text.unpack (clusterCohortName cohort) <> "/daemon-substrate"
        , kindDataMountContainerPath = kindDataMountRoot cohort
        }

defaultKindWorkerNodeCount :: ClusterCohort -> Int
defaultKindWorkerNodeCount cohort =
    case cohort of
        AppleSilicon -> 1
        LinuxCpu -> 3

kindCreatePlan :: KindConfig -> [ClusterAction]
kindCreatePlan config =
    [ clusterAction
        "kind-create"
        "Create the kind cluster when it is missing."
        ( InvokeClusterTool
            ClusterInvocation
                { clusterInvocationTool = KindTool
                , clusterInvocationArguments =
                    [ "create"
                    , "cluster"
                    , "--name"
                    , kindClusterName config
                    , "--kubeconfig"
                    , Text.pack (kindKubeconfigPath config)
                    , "--config"
                    , "-"
                    ]
                        <> maybe [] (\image -> ["--image", image]) (kindImage config)
                , clusterInvocationInput = Just (renderKindConfig config)
                }
        )
    ]
        <> linuxOnly
            [ clusterAction
                "kind-network-connect"
                "Attach the current Linux harness container to Docker's kind network."
                (ConnectCurrentContainerToDockerNetwork "kind")
            ]
        <> [ clusterAction
                "kind-export-kubeconfig"
                "Export the repo-local kubeconfig without mutating the operator kubeconfig."
                ( InvokeClusterTool
                    ClusterInvocation
                        { clusterInvocationTool = KindTool
                        , clusterInvocationArguments =
                            [ "export"
                            , "kubeconfig"
                            ]
                                <> linuxOnly ["--internal"]
                                <> [ "--name"
                                   , kindClusterName config
                                   , "--kubeconfig"
                                   , Text.pack (kindKubeconfigPath config)
                                   ]
                        , clusterInvocationInput = Nothing
                        }
                )
           , clusterAction
                "kind-wait-ready"
                "Wait until the kind API server reports every node Ready before applying resources."
                ( InvokeClusterTool
                    ClusterInvocation
                        { clusterInvocationTool = KubectlTool
                        , clusterInvocationArguments =
                            [ "--kubeconfig"
                            , Text.pack (kindKubeconfigPath config)
                            , "wait"
                            , "--for=condition=Ready"
                            , "nodes"
                            , "--all"
                            , "--timeout=180s"
                            ]
                        , clusterInvocationInput = Nothing
                        }
                )
           ]
  where
    linuxOnly values =
        case kindCohort config of
            AppleSilicon -> []
            LinuxCpu -> values

kindDeletePlan :: KindConfig -> [ClusterAction]
kindDeletePlan config =
    [ clusterAction
        "kind-delete"
        "Delete the kind cluster while preserving repo-local durable state."
        ( InvokeClusterTool
            ClusterInvocation
                { clusterInvocationTool = KindTool
                , clusterInvocationArguments = ["delete", "cluster", "--name", kindClusterName config]
                , clusterInvocationInput = Nothing
                }
        )
    ]

kindStatusPlan :: KindConfig -> [ClusterAction]
kindStatusPlan config =
    [ clusterAction
        "kind-status-clusters"
        "List known kind clusters."
        ( InvokeClusterTool
            ClusterInvocation
                { clusterInvocationTool = KindTool
                , clusterInvocationArguments = ["get", "clusters"]
                , clusterInvocationInput = Nothing
                }
        )
    ]
        <> linuxOnly
            [ clusterAction
                "kind-network-connect"
                "Attach the current Linux harness container to Docker's kind network."
                (ConnectCurrentContainerToDockerNetwork "kind")
            ]
        <> [ clusterAction
                "kind-status-nodes"
                "Read node readiness through the repo-local kubeconfig."
                ( InvokeClusterTool
                    ClusterInvocation
                        { clusterInvocationTool = KubectlTool
                        , clusterInvocationArguments = ["--kubeconfig", Text.pack (kindKubeconfigPath config), "get", "nodes"]
                        , clusterInvocationInput = Nothing
                        }
                )
           ]
  where
    linuxOnly values =
        case kindCohort config of
            AppleSilicon -> []
            LinuxCpu -> values

renderKindConfig :: KindConfig -> Text
renderKindConfig config =
    Text.unlines
        ( [ "kind: Cluster"
          , "apiVersion: kind.x-k8s.io/v1alpha4"
          , "nodes:"
          ]
            <> renderKindNode config "control-plane"
            <> concat (replicate (max 0 (kindWorkerNodeCount config)) (renderKindNode config "worker"))
        )

renderKindNode :: KindConfig -> Text -> [Text]
renderKindNode config role =
    [ "- role: " <> role
    , "  extraMounts:"
    , "    - hostPath: " <> Text.pack (kindDataMountHostPath config)
    , "      containerPath: " <> Text.pack (kindDataMountContainerPath config)
    ]

kindDataMountRoot :: ClusterCohort -> FilePath
kindDataMountRoot cohort =
    "/daemon-substrate-data/" <> Text.unpack (clusterCohortName cohort) <> "/daemon-substrate"
