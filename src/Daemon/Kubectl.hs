module Daemon.Kubectl where

import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as ByteString.Char8
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.Sub

newtype ResourceName = ResourceName {unResourceName :: Text}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

data KubernetesResource = KubernetesResource
  { kubernetesResourceName :: ResourceName,
    kubernetesResourceBody :: Text
  }
  deriving stock (Eq, Show)

data ResourceStatus = ResourceStatus
  { resourceReady :: Bool,
    resourceDetail :: Text
  }
  deriving stock (Eq, Show)

data KubectlError
  = ResourceNotFound ResourceName
  | KubectlBackendUnavailable Text
  deriving stock (Eq, Show)

class (Monad m) => HasKubectl m where
  kubectlApply :: KubernetesResource -> m (Either KubectlError Bool)
  kubectlStatus :: ResourceName -> m (Either KubectlError ResourceStatus)
  kubectlGet :: ResourceName -> m (Either KubectlError KubernetesResource)
  kubectlDelete :: ResourceName -> m (Either KubectlError Bool)

type ResourceMap = Map ResourceName KubernetesResource

data SubprocessKubectl = SubprocessKubectl
  { subprocessKubectlExecutable :: FilePath,
    subprocessKubectlKubeconfig :: FilePath
  }
  deriving stock (Eq, Show)

newtype SubprocessKubectlT m a = SubprocessKubectlT
  {unSubprocessKubectlT :: ReaderT SubprocessKubectl m a}
  deriving newtype (Functor, Applicative, Monad, MonadIO)

runSubprocessKubectlT :: SubprocessKubectl -> SubprocessKubectlT m a -> m a
runSubprocessKubectlT config action = runReaderT (unSubprocessKubectlT action) config

instance (MonadIO m) => HasKubectl (SubprocessKubectlT m) where
  kubectlApply resource = do
    config <- SubprocessKubectlT ask
    result <-
      runKubectl
        config
        ["--kubeconfig", subprocessKubectlKubeconfig config, "apply", "-f", "-"]
        (textInput (kubernetesResourceBody resource))
    pure case result of
      Left err -> Left err
      Right _ -> Right True

  kubectlStatus name = do
    config <- SubprocessKubectlT ask
    result <-
      runKubectl
        config
        ["--kubeconfig", subprocessKubectlKubeconfig config, "rollout", "status", Text.unpack (unResourceName name)]
        mempty
    pure case result of
      Left err -> Left err
      Right output -> Right (ResourceStatus True (Text.pack output))

  kubectlGet name = do
    config <- SubprocessKubectlT ask
    result <-
      runKubectl
        config
        ["--kubeconfig", subprocessKubectlKubeconfig config, "get", Text.unpack (unResourceName name), "-o", "yaml"]
        mempty
    pure case result of
      Left err -> Left err
      Right output ->
        Right
          KubernetesResource
            { kubernetesResourceName = name,
              kubernetesResourceBody = Text.pack output
            }

  kubectlDelete name = do
    config <- SubprocessKubectlT ask
    result <-
      runKubectl
        config
        ["--kubeconfig", subprocessKubectlKubeconfig config, "delete", Text.unpack (unResourceName name), "--ignore-not-found=true"]
        mempty
    pure case result of
      Left err -> Left err
      Right _ -> Right True

runKubectl :: (MonadIO m) => SubprocessKubectl -> [String] -> ByteString -> m (Either KubectlError String)
runKubectl config args input = do
  result <-
    runSubprocess
      Subprocess
        { subprocessExecutable = subprocessKubectlExecutable config,
          subprocessArguments = args,
          subprocessInput = input
        }
  pure case result of
    Left err -> Left (KubectlBackendUnavailable (Text.pack (show err)))
    Right completed
      | subprocessSucceeded completed -> Right (subprocessStdout completed)
      | otherwise -> Left (KubectlBackendUnavailable (Text.pack (subprocessStderr completed)))

textInput :: Text -> ByteString
textInput = ByteString.Char8.pack . Text.unpack
