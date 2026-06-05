module Daemon.Test.CLI.Types where

import Daemon.Test.Matrix
import Data.Text (Text)
import qualified Data.Text as Text

data CliCommand
  = CliHelp
  | CliCluster !ClusterCommand
  | CliTest !HarnessTestCommand
  | CliService !ServiceCommand
  | CliCheckCode
  deriving stock (Eq, Show)

data ClusterCommand
  = ClusterUp !ClusterOptions
  | ClusterDown !ClusterOptions
  | ClusterDelete !ClusterOptions
  | ClusterStatus !ClusterOptions
  deriving stock (Eq, Show)

data ClusterOptions = ClusterOptions
  { clusterOptionsModel :: !HarnessExecutionModel,
    clusterOptionsModelExplicit :: !Bool,
    clusterOptionsStayResident :: !Bool
  }
  deriving stock (Eq, Show)

data HarnessTestCommand
  = TestUnit
  | TestLifecycle
  | TestIntegration
  | TestLint
  | TestAll
  deriving stock (Eq, Show)

data ServiceRoleArg
  = ServiceWorkerArg
  | ServiceOrchestratorArg
  deriving stock (Eq, Show)

data ServiceCommand = ServiceCommand
  { serviceCommandRole :: !ServiceRoleArg,
    serviceCommandConfigPath :: !FilePath,
    serviceCommandLiveConfigPath :: !FilePath,
    serviceCommandLifecyclePolicyPath :: !FilePath
  }
  deriving stock (Eq, Show)

parseCliCommand :: [String] -> Either Text CliCommand
parseCliCommand [] = Right CliHelp
parseCliCommand ["--help"] = Right CliHelp
parseCliCommand ["-h"] = Right CliHelp
parseCliCommand ("cluster" : rest) = CliCluster <$> parseClusterCommand rest
parseCliCommand ("test" : rest) = CliTest <$> parseHarnessTestCommand rest
parseCliCommand ("service" : rest) = CliService <$> parseServiceCommand rest
parseCliCommand ["check-code"] = Right CliCheckCode
parseCliCommand _ = Left renderCliHelp

parseClusterCommand :: [String] -> Either Text ClusterCommand
parseClusterCommand ("up" : rest) = ClusterUp <$> parseClusterOptions True rest
parseClusterCommand ("down" : rest) = ClusterDown <$> parseClusterOptions False rest
parseClusterCommand ("delete" : rest) = ClusterDelete <$> parseClusterOptions False rest
parseClusterCommand ("status" : rest) = ClusterStatus <$> parseClusterOptions False rest
parseClusterCommand _ = Left renderCliHelp

parseClusterOptions :: Bool -> [String] -> Either Text ClusterOptions
parseClusterOptions allowStayResident =
  go defaultClusterOptions
  where
    go options [] = Right options
    go options ("--model" : value : rest) =
      case parseExecutionModel (Text.pack value) of
        Just model -> go options{clusterOptionsModel = model, clusterOptionsModelExplicit = True} rest
        Nothing -> Left "cluster --model must be container, host-binary, or host-daemon"
    go options ("--stay-resident" : rest)
      | allowStayResident = go options{clusterOptionsStayResident = True} rest
      | otherwise = Left "--stay-resident is only supported by cluster up"
    go _ _ = Left renderCliHelp

defaultClusterOptions :: ClusterOptions
defaultClusterOptions =
  ClusterOptions
    { clusterOptionsModel = ExecutionContainer,
      clusterOptionsModelExplicit = False,
      clusterOptionsStayResident = False
    }

parseHarnessTestCommand :: [String] -> Either Text HarnessTestCommand
parseHarnessTestCommand ["unit"] = Right TestUnit
parseHarnessTestCommand ["lifecycle"] = Right TestLifecycle
parseHarnessTestCommand ["integration"] = Right TestIntegration
parseHarnessTestCommand ["lint"] = Right TestLint
parseHarnessTestCommand ["all"] = Right TestAll
parseHarnessTestCommand _ = Left renderCliHelp

parseServiceCommand :: [String] -> Either Text ServiceCommand
parseServiceCommand args =
  build Nothing Nothing "dhall/live.dhall" "dhall/lifecycle-policy.dhall" args
  where
    build role config live lifecycle [] =
      ServiceCommand
        <$> maybe (Left "--role is required") Right role
        <*> maybe (Left "--config is required") Right config
        <*> Right live
        <*> Right lifecycle
    build _ config live lifecycle ("--role" : value : rest) =
      case value of
        "worker" -> build (Just ServiceWorkerArg) config live lifecycle rest
        "orchestrator" -> build (Just ServiceOrchestratorArg) config live lifecycle rest
        _ -> Left "service --role must be worker or orchestrator"
    build role _ live lifecycle ("--config" : value : rest) =
      build role (Just value) live lifecycle rest
    build role config _ lifecycle ("--live-config" : value : rest) =
      build role config value lifecycle rest
    build role config live _ ("--lifecycle-policy" : value : rest) =
      build role config live value rest
    build _ _ _ _ _ =
      Left renderCliHelp

renderCliHelp :: Text
renderCliHelp =
  Text.unlines
    [ "daemon-substrate-test",
      "",
      "Commands:",
      "  cluster up [--model <container|host-binary|host-daemon>] [--stay-resident]",
      "  cluster down [--model <container|host-binary|host-daemon>]",
      "  cluster delete [--model <container|host-binary|host-daemon>]",
      "  cluster status [--model <container|host-binary|host-daemon>]",
      "  test unit",
      "  test lifecycle",
      "  test integration",
      "  test lint",
      "  test all",
      "  service --role <worker|orchestrator> --config <path> [--live-config <path>] [--lifecycle-policy <path>]",
      "  check-code"
    ]
