module Daemon.Cluster.Helm where

import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.Cluster.Types

data HelmRelease = HelmRelease
  { helmReleaseName :: !Text,
    helmReleaseNamespace :: !Text,
    helmReleaseChart :: !Text,
    helmReleaseValuesFiles :: ![FilePath]
  }
  deriving stock (Eq, Show)

data HelmConfig = HelmConfig
  { helmChartDirectory :: !FilePath,
    helmReleases :: ![HelmRelease]
  }
  deriving stock (Eq, Show)

defaultHelmConfig :: ClusterCohort -> HelmConfig
defaultHelmConfig cohort =
  HelmConfig
    { helmChartDirectory = "chart",
      helmReleases =
        [ release "daemon-substrate-test" "default" "./chart"
        ]
    }
  where
    valuesFile = "chart/values/" <> Text.unpack (clusterCohortName cohort) <> ".yaml"
    release name namespace chart =
      HelmRelease
        { helmReleaseName = name,
          helmReleaseNamespace = namespace,
          helmReleaseChart = chart,
          helmReleaseValuesFiles = ["chart/values.yaml", valuesFile]
        }

helmRolloutPlan :: HelmConfig -> [ClusterAction]
helmRolloutPlan config =
  helmDependencyBuildPlan config <> fmap helmReleaseAction (helmReleases config)

helmDependencyBuildPlan :: HelmConfig -> [ClusterAction]
helmDependencyBuildPlan config =
  [ clusterAction
      "helm-dependency-build"
      "Build or refresh chart dependencies before any release upgrade."
      ( InvokeClusterTool
          ClusterInvocation
            { clusterInvocationTool = HelmTool,
              clusterInvocationArguments = ["dependency", "build", Text.pack (helmChartDirectory config)],
              clusterInvocationInput = Nothing
            }
      )
  ]

helmReleaseAction :: HelmRelease -> ClusterAction
helmReleaseAction release =
  clusterAction
    ("helm-upgrade-" <> helmReleaseName release)
              "Install or upgrade the harness Helm release."
    ( InvokeClusterTool
        ClusterInvocation
          { clusterInvocationTool = HelmTool,
            clusterInvocationArguments =
              [ "upgrade",
                "--install",
                helmReleaseName release,
                helmReleaseChart release,
                "--namespace",
                helmReleaseNamespace release,
                "--create-namespace"
              ]
                <> concatMap (\path -> ["-f", Text.pack path]) (helmReleaseValuesFiles release),
            clusterInvocationInput = Nothing
          }
    )
