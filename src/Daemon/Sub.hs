module Daemon.Sub where

import Control.Exception (IOException, try)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (isAbsolute)
import System.IO (hClose, hPutStr)
import System.Process (StdStream (CreatePipe, Inherit), createProcess, proc, readCreateProcessWithExitCode, std_err, std_in, std_out, waitForProcess)

data Subprocess = Subprocess
  { subprocessExecutable :: FilePath,
    subprocessArguments :: [String],
    subprocessInput :: ByteString
  }
  deriving stock (Eq, Show)

data SubprocessResult = SubprocessResult
  { subprocessExitCode :: ExitCode,
    subprocessStdout :: String,
    subprocessStderr :: String
  }
  deriving stock (Eq, Show)

data SubprocessError
  = SubprocessExecutableNotAbsolute FilePath
  | SubprocessIOException IOException
  deriving stock (Show)

runSubprocess :: (MonadIO m) => Subprocess -> m (Either SubprocessError SubprocessResult)
runSubprocess request
  | not (isAbsolute (subprocessExecutable request)) =
      pure (Left (SubprocessExecutableNotAbsolute (subprocessExecutable request)))
  | otherwise = liftIO do
      result <-
        try
          ( readCreateProcessWithExitCode
              (proc (subprocessExecutable request) (subprocessArguments request))
              (bytesToString (subprocessInput request))
          )
      pure case result of
        Left err -> Left (SubprocessIOException err)
        Right (code, out, err) -> Right (SubprocessResult code out err)

runSubprocessStreaming :: (MonadIO m) => Subprocess -> m (Either SubprocessError SubprocessResult)
runSubprocessStreaming request
  | not (isAbsolute (subprocessExecutable request)) =
      pure (Left (SubprocessExecutableNotAbsolute (subprocessExecutable request)))
  | otherwise = liftIO do
      result <-
        try do
          (stdinHandle, _, _, processHandle) <-
            createProcess
              (proc (subprocessExecutable request) (subprocessArguments request))
                { std_in = CreatePipe,
                  std_out = Inherit,
                  std_err = Inherit
                }
          case stdinHandle of
            Nothing -> pure ()
            Just handle -> do
              hPutStr handle (bytesToString (subprocessInput request))
              hClose handle
          code <- waitForProcess processHandle
          pure (SubprocessResult code mempty mempty)
      pure case result of
        Left err -> Left (SubprocessIOException err)
        Right completed -> Right completed

bytesToString :: ByteString -> String
bytesToString = fmap (toEnum . fromEnum) . ByteString.unpack

subprocessSucceeded :: SubprocessResult -> Bool
subprocessSucceeded result = subprocessExitCode result == ExitSuccess
