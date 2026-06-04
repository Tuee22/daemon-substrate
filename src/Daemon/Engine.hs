module Daemon.Engine where

import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as ByteString.Char8
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.Sub
import System.Exit (ExitCode)
import System.Timeout (timeout)

data EngineRequest = EngineRequest
  { engineRequestId :: !Text,
    engineRequestPayload :: !ByteString
  }
  deriving stock (Eq, Show)

data EngineResponse = EngineResponse
  { engineResponseRequestId :: !Text,
    engineResponsePayload :: !ByteString
  }
  deriving stock (Eq, Show)

data EngineError
  = EngineRequestFailed
      { engineErrorRequestId :: !Text,
        engineErrorDetail :: !Text
      }
  | EngineBatchFailed !Text
  | EngineSubprocessUnavailable
      { engineErrorRequestId :: !Text,
        engineErrorDetail :: !Text
      }
  | EngineSubprocessFailed
      { engineErrorRequestId :: !Text,
        engineSubprocessExitCode :: !ExitCode,
        engineErrorDetail :: !Text
      }
  | EngineTimedOut
      { engineErrorRequestId :: !Text,
        engineTimeoutMicros :: !Int
      }
  deriving stock (Eq, Show)

class (Monad m) => HasEngine m where
  engineCall :: NonEmpty EngineRequest -> m (NonEmpty (Either EngineError EngineResponse))

newtype NativeEngine m = NativeEngine
  { nativeEngineCall :: NonEmpty EngineRequest -> m (NonEmpty (Either EngineError EngineResponse))
  }

newtype NativeEngineT m a = NativeEngineT
  {unNativeEngineT :: ReaderT (NativeEngine m) m a}
  deriving newtype (Functor, Applicative, Monad, MonadIO)

runNativeEngineT :: NativeEngine m -> NativeEngineT m a -> m a
runNativeEngineT engine action =
  runReaderT (unNativeEngineT action) engine

instance (Monad m) => HasEngine (NativeEngineT m) where
  engineCall requests = NativeEngineT do
    engine <- ask
    lift (nativeEngineCall engine requests)

data SubprocessEngine = SubprocessEngine
  { subprocessEngineExecutable :: !FilePath,
    subprocessEngineArguments :: ![String],
    subprocessEngineTimeoutMicros :: !Int
  }
  deriving stock (Eq, Show)

newtype SubprocessEngineT a = SubprocessEngineT
  {unSubprocessEngineT :: ReaderT SubprocessEngine IO a}
  deriving newtype (Functor, Applicative, Monad, MonadIO)

runSubprocessEngineT :: SubprocessEngine -> SubprocessEngineT a -> IO a
runSubprocessEngineT engine action =
  runReaderT (unSubprocessEngineT action) engine

instance HasEngine SubprocessEngineT where
  engineCall requests = SubprocessEngineT do
    engine <- ask
    liftIO (runSubprocessEngine engine requests)

data EngineHandle m
  = NativeEngineHandle (NativeEngine m)
  | SubprocessEngineHandle SubprocessEngine

runEngineHandle ::
  EngineHandle IO ->
  NonEmpty EngineRequest ->
  IO (NonEmpty (Either EngineError EngineResponse))
runEngineHandle handle requests =
  case handle of
    NativeEngineHandle engine ->
      nativeEngineCall engine requests
    SubprocessEngineHandle engine ->
      runSubprocessEngine engine requests

runSubprocessEngine ::
  SubprocessEngine ->
  NonEmpty EngineRequest ->
  IO (NonEmpty (Either EngineError EngineResponse))
runSubprocessEngine engine =
  traverse (runSubprocessEngineRequest engine)

runSubprocessEngineRequest ::
  SubprocessEngine ->
  EngineRequest ->
  IO (Either EngineError EngineResponse)
runSubprocessEngineRequest engine request = do
  result <-
    timeout
      (subprocessEngineTimeoutMicros engine)
      ( runSubprocess
          Subprocess
            { subprocessExecutable = subprocessEngineExecutable engine,
              subprocessArguments = subprocessEngineArguments engine,
              subprocessInput = engineRequestPayload request
            }
      )
  pure case result of
    Nothing ->
      Left
        EngineTimedOut
          { engineErrorRequestId = engineRequestId request,
            engineTimeoutMicros = subprocessEngineTimeoutMicros engine
          }
    Just (Left err) ->
      Left
        EngineSubprocessUnavailable
          { engineErrorRequestId = engineRequestId request,
            engineErrorDetail = Text.pack (show err)
          }
    Just (Right completed)
      | subprocessSucceeded completed ->
          Right
            EngineResponse
              { engineResponseRequestId = engineRequestId request,
                engineResponsePayload = ByteString.Char8.pack (subprocessStdout completed)
              }
      | otherwise ->
          Left
            EngineSubprocessFailed
              { engineErrorRequestId = engineRequestId request,
                engineSubprocessExitCode = subprocessExitCode completed,
                engineErrorDetail = Text.pack (subprocessStderr completed)
              }

echoResponse :: EngineRequest -> EngineResponse
echoResponse request =
  EngineResponse
    { engineResponseRequestId = engineRequestId request,
      engineResponsePayload = engineRequestPayload request
    }
