module Daemon.Test.CLI.Tests where

import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO
import Daemon.Sub
import Daemon.Test.CLI.Types
import System.Directory (findExecutable)
import System.Exit (ExitCode)

data HarnessTestError
  = HarnessTestCabalNotFound
  | HarnessTestSubprocessError !SubprocessError
  | HarnessTestFailed !ExitCode !Text.Text !Text.Text
  deriving stock (Show)

runHarnessTestCommand :: HarnessTestCommand -> IO (Either Text.Text ())
runHarnessTestCommand command = do
  Text.IO.putStrLn (renderHarnessTestCommand command)
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
