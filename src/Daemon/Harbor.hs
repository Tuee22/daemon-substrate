module Daemon.Harbor where

import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.Sub

newtype ImageRef = ImageRef {unImageRef :: Text}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

data HarborError
  = HarborImageNotFound ImageRef
  | HarborBackendUnavailable Text
  deriving stock (Eq, Show)

class (Monad m) => HasHarbor m where
  harborImageExists :: ImageRef -> m (Either HarborError Bool)
  harborPushImage :: ImageRef -> m (Either HarborError Bool)
  harborPullImage :: ImageRef -> m (Either HarborError ())
  harborListImages :: m (Either HarborError [ImageRef])

data SubprocessHarbor = SubprocessHarbor
  { subprocessHarborDocker :: FilePath,
    subprocessHarborCurl :: FilePath,
    subprocessHarborApiBaseUrl :: Text,
    subprocessHarborExtraCurlArgs :: [String]
  }
  deriving stock (Eq, Show)

newtype SubprocessHarborT m a = SubprocessHarborT
  {unSubprocessHarborT :: ReaderT SubprocessHarbor m a}
  deriving newtype (Functor, Applicative, Monad, MonadIO)

runSubprocessHarborT :: SubprocessHarbor -> SubprocessHarborT m a -> m a
runSubprocessHarborT config action = runReaderT (unSubprocessHarborT action) config

instance (MonadIO m) => HasHarbor (SubprocessHarborT m) where
  harborImageExists ref = do
    config <- SubprocessHarborT ask
    result <- runDocker config ["manifest", "inspect", Text.unpack (unImageRef ref)]
    pure case result of
      Left (HarborImageNotFound _) -> Right False
      Left err -> Left err
      Right _ -> Right True

  harborPushImage ref = do
    config <- SubprocessHarborT ask
    result <- runDocker config ["push", Text.unpack (unImageRef ref)]
    pure case result of
      Left err -> Left err
      Right _ -> Right True

  harborPullImage ref = do
    config <- SubprocessHarborT ask
    result <- runDocker config ["pull", Text.unpack (unImageRef ref)]
    pure case result of
      Left err -> Left err
      Right _ -> Right ()

  harborListImages = do
    config <- SubprocessHarborT ask
    result <- runCurl config ["--fail-with-body", "-X", "GET", Text.unpack (subprocessHarborApiBaseUrl config)]
    pure case result of
      Left err -> Left err
      Right output -> Right (ImageRef . Text.pack <$> lines output)

runDocker :: (MonadIO m) => SubprocessHarbor -> [String] -> m (Either HarborError String)
runDocker config args = do
  result <-
    runSubprocess
      Subprocess
        { subprocessExecutable = subprocessHarborDocker config,
          subprocessArguments = args,
          subprocessInput = mempty
        }
  pure case result of
    Left err -> Left (HarborBackendUnavailable (Text.pack (show err)))
    Right completed
      | subprocessSucceeded completed -> Right (subprocessStdout completed)
      | otherwise -> Left (HarborImageNotFound (ImageRef (Text.pack (unwords args))))

runCurl :: (MonadIO m) => SubprocessHarbor -> [String] -> m (Either HarborError String)
runCurl config args = do
  result <-
    runSubprocess
      Subprocess
        { subprocessExecutable = subprocessHarborCurl config,
          subprocessArguments = subprocessHarborExtraCurlArgs config <> args,
          subprocessInput = mempty
        }
  pure case result of
    Left err -> Left (HarborBackendUnavailable (Text.pack (show err)))
    Right completed
      | subprocessSucceeded completed -> Right (subprocessStdout completed)
      | otherwise -> Left (HarborBackendUnavailable (Text.pack (subprocessStderr completed)))
