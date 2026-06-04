module Daemon.Test.CLI.Cluster where

import Data.Foldable (traverse_)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO
import Daemon.Cluster.Plan
import Daemon.Cluster.Runner
import Daemon.Cluster.Types
import Daemon.Test.CLI.Types
import System.IO (hFlush, stdout)
import qualified System.Info as System

runClusterCommand :: ClusterCommand -> IO (Either Text.Text ())
runClusterCommand command = do
  let cohort = detectClusterCohort
      config = defaultClusterBringupConfig cohort
      plan = clusterCommandPlan config command
  Text.IO.putStrLn (renderClusterCommandFor cohort command)
  hFlush stdout
  result <-
    runClusterPlanWithProgress
      (clusterBringupPaths config)
      plan
      \actionName -> do
        Text.IO.putStrLn (actionName <> ": running")
        hFlush stdout
  case result of
    Left err -> pure (Left (renderClusterRunnerError err))
    Right actions -> do
      traverse_
        ( \action -> do
            Text.IO.putStrLn (renderClusterActionResult action)
            hFlush stdout
        )
        actions
      pure (Right ())

renderClusterCommand :: ClusterCommand -> Text.Text
renderClusterCommand command =
  renderClusterCommandFor LinuxCpu command

renderClusterCommandFor :: ClusterCohort -> ClusterCommand -> Text.Text
renderClusterCommandFor cohort command =
  Text.unlines
    ( header
        : fmap ("  " <>) (clusterActionNames (clusterPlanActions plan))
    )
  where
    config = defaultClusterBringupConfig cohort
    header =
      case command of
        ClusterUp -> "cluster up plan:"
        ClusterDown -> "cluster down plan:"
        ClusterStatus -> "cluster status plan:"
    plan = clusterCommandPlan config command

clusterCommandPlan :: ClusterBringupConfig -> ClusterCommand -> ClusterPlan
clusterCommandPlan config command =
  case command of
    ClusterUp -> clusterBringupPlan config
    ClusterDown -> clusterTeardownPlan config
    ClusterStatus -> clusterStatusPlan config

detectClusterCohort :: ClusterCohort
detectClusterCohort
  | System.os == "darwin" && System.arch == "aarch64" = AppleSilicon
  | System.os == "darwin" && System.arch == "arm64" = AppleSilicon
  | otherwise = LinuxCpu
