module Daemon.Test.CLI.Tests where

import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO
import Daemon.Cluster.Runner
  ( connectCurrentContainerToDockerNetwork,
    renderClusterRunnerError,
  )
import Daemon.Sub
import Daemon.Test.CLI.Types
import Daemon.Test.Matrix
import System.Directory (doesFileExist, findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode)

data HarnessTestError
  = HarnessTestCabalNotFound
  | HarnessTestKindNetworkFailed !Text.Text
  | HarnessTestSubprocessError !SubprocessError
  | HarnessTestFailed !ExitCode !Text.Text !Text.Text
  deriving stock (Show)

runHarnessTestCommand :: HarnessTestCommand -> IO (Either Text.Text ())
runHarnessTestCommand command = do
  Text.IO.putStrLn (renderHarnessTestCommand command)
  prepared <- prepareHarnessTestCommand command
  case prepared of
    Left err -> pure (Left (renderHarnessTestError err))
    Right () -> runCabalHarnessTest command

runCabalHarnessTest :: HarnessTestCommand -> IO (Either Text.Text ())
runCabalHarnessTest command = do
  cabal <- findExecutable "cabal"
  case cabal of
    Nothing ->
      pure (Left (renderHarnessTestError HarnessTestCabalNotFound))
    Just cabalPath -> do
      result <-
        runSubprocess
          Subprocess
            { subprocessExecutable = cabalPath,
              subprocessArguments = "test" : fmap Text.unpack (testSuites command),
              subprocessInput = ByteString.empty
            }
      pure case result of
        Left err ->
          Left (renderHarnessTestError (HarnessTestSubprocessError err))
        Right completed
          | subprocessSucceeded completed ->
              Right ()
          | otherwise ->
              Left
                ( renderHarnessTestError
                    ( HarnessTestFailed
                        (subprocessExitCode completed)
                        (Text.pack (subprocessStdout completed))
                        (Text.pack (subprocessStderr completed))
                    )
                )

prepareHarnessTestCommand :: HarnessTestCommand -> IO (Either HarnessTestError ())
prepareHarnessTestCommand command
  | not (testCommandRequiresIntegration command) = pure (Right ())
  | otherwise = do
      attach <- shouldAttachKindNetwork
      if not attach
        then pure (Right ())
        else do
          connected <- connectCurrentContainerToDockerNetwork "kind-network-connect" "kind"
          pure case connected of
            Left err -> Left (HarnessTestKindNetworkFailed (renderClusterRunnerError err))
            Right _ -> Right ()

testCommandRequiresIntegration :: HarnessTestCommand -> Bool
testCommandRequiresIntegration command =
  case command of
    TestIntegration -> True
    TestAll -> True
    _ -> False

shouldAttachKindNetwork :: IO Bool
shouldAttachKindNetwork = do
  selected <- selectedExecutionModelFromEnv
  inContainer <- runningInContainer
  pure case selected of
    Just ExecutionContainer -> True
    Just _ -> False
    Nothing -> inContainer

selectedExecutionModelFromEnv :: IO (Maybe HarnessExecutionModel)
selectedExecutionModelFromEnv = do
  modelEnv <- lookupEnv "HOSTBOOTSTRAP_MODEL"
  targetEnv <- lookupEnv "HOSTBOOTSTRAP_TARGET"
  pure case modelEnv >>= parseExecutionModel . Text.pack of
    Just model -> Just model
    Nothing -> targetEnv >>= executionModelForHostbootstrapTarget . Text.pack

runningInContainer :: IO Bool
runningInContainer = do
  dockerEnv <- doesFileExist "/.dockerenv"
  containerEnv <- doesFileExist "/run/.containerenv"
  pure (dockerEnv || containerEnv)

renderHarnessTestCommand :: HarnessTestCommand -> Text.Text
renderHarnessTestCommand command =
  Text.unlines
    [ "cabal test command:",
      "  " <> Text.unwords ("cabal" : "test" : testSuites command)
    ]

testSuites :: HarnessTestCommand -> [Text.Text]
testSuites TestUnit = ["daemon-substrate-unit"]
testSuites TestLifecycle = ["daemon-substrate-lifecycle"]
testSuites TestIntegration = ["daemon-substrate-integration"]
testSuites TestLint = ["daemon-substrate-haskell-style"]
testSuites TestAll =
  [ "daemon-substrate-haskell-style",
    "daemon-substrate-unit",
    "daemon-substrate-lifecycle",
    "daemon-substrate-integration"
  ]

renderHarnessTestError :: HarnessTestError -> Text.Text
renderHarnessTestError err =
  case err of
    HarnessTestCabalNotFound ->
      "cabal executable not found on PATH"
    HarnessTestKindNetworkFailed detail ->
      "could not attach test container to Docker kind network: " <> detail
    HarnessTestSubprocessError detail ->
      "cabal test could not start: " <> Text.pack (show detail)
    HarnessTestFailed code stdout stderr ->
      Text.unlines
        [ "cabal test failed",
          "exit: " <> Text.pack (show code),
          "stdout:",
          stdout,
          "stderr:",
          stderr
        ]
