module Daemon.Test.CLI where

import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO
import Daemon.Test.CLI.Cluster
import Daemon.Test.CLI.Service
import Daemon.Test.CLI.Tests
import Daemon.Test.CLI.Types

runCliCommand :: CliCommand -> IO (Either Text.Text ())
runCliCommand CliHelp = do
  Text.IO.putStrLn renderCliHelp
  pure (Right ())
runCliCommand (CliCluster command) =
  runClusterCommand command
runCliCommand (CliTest command) =
  runHarnessTestCommand command
runCliCommand (CliService command) = do
  result <- runHarnessService command
  pure case result of
    Right () -> Right ()
    Left err -> Left (Text.pack (show err))
