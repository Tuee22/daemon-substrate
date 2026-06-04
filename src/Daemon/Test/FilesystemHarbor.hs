{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Daemon.Test.FilesystemHarbor where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import Data.Set (Set)
import qualified Data.Set as Set
import Daemon.Harbor

newtype FilesystemHarbor a = FilesystemHarbor
  {unFilesystemHarbor :: ReaderT FilesystemHarborHandle IO a}
  deriving newtype (Functor, Applicative, Monad, MonadFail, MonadIO)

newtype FilesystemHarborHandle = FilesystemHarborHandle
  {filesystemHarborImages :: TVar (Set ImageRef)}

newFilesystemHarborHandle :: IO FilesystemHarborHandle
newFilesystemHarborHandle = FilesystemHarborHandle <$> newTVarIO mempty

runFilesystemHarbor :: FilesystemHarborHandle -> FilesystemHarbor a -> IO a
runFilesystemHarbor handle action = runReaderT (unFilesystemHarbor action) handle

withFilesystemHarbor :: FilesystemHarbor a -> IO a
withFilesystemHarbor action = do
  handle <- newFilesystemHarborHandle
  runFilesystemHarbor handle action

instance HasHarbor FilesystemHarbor where
  harborImageExists ref = do
    imagesVar <- askImages
    atomicallyLift do
      Right . Set.member ref <$> readTVar imagesVar

  harborPushImage ref = do
    imagesVar <- askImages
    atomicallyLift do
      images <- readTVar imagesVar
      let changed = not (Set.member ref images)
      writeTVar imagesVar (Set.insert ref images)
      pure (Right changed)

  harborPullImage ref = do
    imagesVar <- askImages
    atomicallyLift do
      images <- readTVar imagesVar
      pure
        if Set.member ref images
          then Right ()
          else Left (HarborImageNotFound ref)

  harborListImages = do
    imagesVar <- askImages
    atomicallyLift do
      Right . Set.toList <$> readTVar imagesVar

askImages :: FilesystemHarbor (TVar (Set ImageRef))
askImages = filesystemHarborImages <$> FilesystemHarbor ask

atomicallyLift :: (MonadIO m) => STM a -> m a
atomicallyLift = liftIO . atomically
