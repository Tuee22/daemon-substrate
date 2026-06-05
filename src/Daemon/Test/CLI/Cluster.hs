module Daemon.Test.CLI.Cluster where

import Control.Concurrent (threadDelay)
import Control.Monad (forever, when)
import Data.Foldable (traverse_)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO
import Daemon.Cluster.Plan
import Daemon.Cluster.Runner
import Daemon.Cluster.Types
import Daemon.Test.CLI.Types
import Daemon.Test.Matrix
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import System.IO (hFlush, stdout)

runClusterCommand :: ClusterCommand -> IO (Either Text.Text ())
runClusterCommand command = do
  let options = clusterCommandOptions command
      model = clusterOptionsModel options
      config = defaultClusterBringupConfigForModel model
      plan = clusterCommandPlan config command
  Text.IO.putStrLn (renderClusterCommandFor model command)
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
      when (isClusterUp command) do
        persistExecutionModel config model
      when (isClusterUp command && clusterOptionsStayResident options) do
        Text.IO.putStrLn "cluster up complete; staying resident"
        hFlush stdout
        forever (threadDelay maxBound)
      pure (Right ())

renderClusterCommand :: ClusterCommand -> Text.Text
renderClusterCommand command =
  renderClusterCommandFor (clusterOptionsModel (clusterCommandOptions command)) command

renderClusterCommandFor :: HarnessExecutionModel -> ClusterCommand -> Text.Text
renderClusterCommandFor model command =
  Text.unlines
    ( header
        : fmap ("  " <>) (clusterActionNames (clusterPlanActions plan))
    )
  where
    config = defaultClusterBringupConfigForModel model
    header =
      case command of
        ClusterUp _ -> "cluster up plan (" <> executionModelName model <> "):"
        ClusterDown _ -> "cluster down plan (" <> executionModelName model <> "):"
        ClusterStatus _ -> "cluster status plan (" <> executionModelName model <> "):"
    plan = clusterCommandPlan config command

clusterCommandPlan :: ClusterBringupConfig -> ClusterCommand -> ClusterPlan
clusterCommandPlan config command =
  case command of
    ClusterUp _ -> clusterBringupPlan config
    ClusterDown _ -> clusterTeardownPlan config
    ClusterStatus _ -> clusterStatusPlan config

clusterCommandOptions :: ClusterCommand -> ClusterOptions
clusterCommandOptions command =
  case command of
    ClusterUp options -> options
    ClusterDown options -> options
    ClusterStatus options -> options

isClusterUp :: ClusterCommand -> Bool
isClusterUp command =
  case command of
    ClusterUp _ -> True
    _ -> False

defaultClusterBringupConfigForModel :: HarnessExecutionModel -> ClusterBringupConfig
defaultClusterBringupConfigForModel model =
  defaultClusterBringupConfigWithPaths
    (executionModelClusterCohort model)
    (executionModelClusterPaths model)

persistExecutionModel :: ClusterBringupConfig -> HarnessExecutionModel -> IO ()
persistExecutionModel config model = do
  let path = executionModelRecordPath (clusterBringupPaths config)
  createDirectoryIfMissing True (takeDirectory path)
  Text.IO.writeFile path (executionModelName model <> "\n")
