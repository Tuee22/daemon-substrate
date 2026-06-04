{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Daemon.Test.FilesystemKubectl where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Daemon.Kubectl

newtype FilesystemKubectl a = FilesystemKubectl
  {unFilesystemKubectl :: ReaderT FilesystemKubectlHandle IO a}
  deriving newtype (Functor, Applicative, Monad, MonadFail, MonadIO)

newtype FilesystemKubectlHandle = FilesystemKubectlHandle
  {filesystemKubectlResources :: TVar ResourceMap}

newFilesystemKubectlHandle :: IO FilesystemKubectlHandle
newFilesystemKubectlHandle = FilesystemKubectlHandle <$> newTVarIO mempty

runFilesystemKubectl :: FilesystemKubectlHandle -> FilesystemKubectl a -> IO a
runFilesystemKubectl handle action = runReaderT (unFilesystemKubectl action) handle

withFilesystemKubectl :: FilesystemKubectl a -> IO a
withFilesystemKubectl action = do
  handle <- newFilesystemKubectlHandle
  runFilesystemKubectl handle action

instance HasKubectl FilesystemKubectl where
  kubectlApply resource = do
    resourcesVar <- askResources
    atomicallyLift do
      resources <- readTVar resourcesVar
      let name = kubernetesResourceName resource
          changed = Map.lookup name resources /= Just resource
      writeTVar resourcesVar (Map.insert name resource resources)
      pure (Right changed)

  kubectlStatus name = do
    resourcesVar <- askResources
    atomicallyLift do
      resources <- readTVar resourcesVar
      pure case Map.lookup name resources of
        Nothing -> Left (ResourceNotFound name)
        Just _ -> Right (ResourceStatus True "ready")

  kubectlGet name = do
    resourcesVar <- askResources
    atomicallyLift do
      resources <- readTVar resourcesVar
      pure case Map.lookup name resources of
        Nothing -> Left (ResourceNotFound name)
        Just resource -> Right resource

  kubectlDelete name = do
    resourcesVar <- askResources
    atomicallyLift do
      resources <- readTVar resourcesVar
      let existed = Map.member name resources
      writeTVar resourcesVar (Map.delete name resources)
      pure (Right existed)

askResources :: FilesystemKubectl (TVar (Map ResourceName KubernetesResource))
askResources = filesystemKubectlResources <$> FilesystemKubectl ask

atomicallyLift :: (MonadIO m) => STM a -> m a
atomicallyLift = liftIO . atomically
