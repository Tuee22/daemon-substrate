module Main (main) where

import qualified Data.Text.IO as Text.IO
import qualified Data.Text as Text
import Daemon.Test.CLI
import Daemon.Test.CLI.Types
import System.Environment (getArgs)
import System.Exit (exitFailure)

main :: IO ()
main = do
  args <- getArgs
  case parseCliCommand args of
    Left help -> do
      Text.IO.putStrLn help
      exitFailure
    Right command -> do
      result <- runCliCommand command
      case result of
        Right () -> pure ()
        Left err -> do
          Text.IO.putStrLn (Text.pack (show err))
          exitFailure
