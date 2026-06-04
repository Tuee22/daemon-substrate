{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Daemon.Test.FilesystemMinIO where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.MinIO
import Daemon.MinIO.Admin
import Daemon.MinIO.Store (stableETag)

newtype FilesystemMinIO a = FilesystemMinIO
  {unFilesystemMinIO :: ReaderT FilesystemMinIOHandle IO a}
  deriving newtype (Functor, Applicative, Monad, MonadFail, MonadIO)

newtype FilesystemMinIOHandle = FilesystemMinIOHandle
  {filesystemMinIOState :: TVar MinIOState}

data MinIOState = MinIOState
  { minioBuckets :: Set BucketName,
    minioObjects :: Map ObjectRef ObjectBody,
    minioLifecycles :: Map BucketName BucketLifecycle
  }

emptyMinIOState :: MinIOState
emptyMinIOState =
  MinIOState
    { minioBuckets = mempty,
      minioObjects = mempty,
      minioLifecycles = mempty
    }

newFilesystemMinIOHandle :: IO FilesystemMinIOHandle
newFilesystemMinIOHandle = FilesystemMinIOHandle <$> newTVarIO emptyMinIOState

runFilesystemMinIO :: FilesystemMinIOHandle -> FilesystemMinIO a -> IO a
runFilesystemMinIO handle action = runReaderT (unFilesystemMinIO action) handle

withFilesystemMinIO :: FilesystemMinIO a -> IO a
withFilesystemMinIO action = do
  handle <- newFilesystemMinIOHandle
  runFilesystemMinIO handle action

instance HasMinIO FilesystemMinIO where
  minioGet ref = do
    stateVar <- askMinIOState
    atomicallyLift do
      state <- readTVar stateVar
      pure case Map.lookup ref (minioObjects state) of
        Nothing -> Left (ObjectNotFound ref)
        Just body -> Right body

  putBlobIfAbsent ref bytes = do
    stateVar <- askMinIOState
    atomicallyLift do
      state <- readTVar stateVar
      if not (Set.member (objectRefBucket ref) (minioBuckets state))
        then pure (Left (BucketNotFound (objectRefBucket ref)))
        else
          if Map.member ref (minioObjects state)
            then pure (Left (ObjectAlreadyExists ref))
            else do
              let etag = stableETag bytes
                  body = ObjectBody bytes etag
              writeTVar stateVar state {minioObjects = Map.insert ref body (minioObjects state)}
              pure (Right etag)

  casPointer ref expected bytes = do
    stateVar <- askMinIOState
    atomicallyLift do
      state <- readTVar stateVar
      if not (Set.member (objectRefBucket ref) (minioBuckets state))
        then pure (Left (BucketNotFound (objectRefBucket ref)))
        else do
          let current = Map.lookup ref (minioObjects state)
          case (expected, current) of
            (Nothing, Just _) -> pure (Left (ETagMismatch ref))
            (Just etag, Just body) | objectBodyETag body /= etag -> pure (Left (ETagMismatch ref))
            (Just _, Nothing) -> pure (Left (ObjectNotFound ref))
            _ -> do
              let etag = stableETag bytes
              writeTVar stateVar state {minioObjects = Map.insert ref (ObjectBody bytes etag) (minioObjects state)}
              pure (Right etag)

  listObjects bucket prefix = do
    stateVar <- askMinIOState
    atomicallyLift do
      state <- readTVar stateVar
      if not (Set.member bucket (minioBuckets state))
        then pure (Left (BucketNotFound bucket))
        else
          pure
            ( Right
                [ objectRefKey ref
                | ref <- Map.keys (minioObjects state),
                  objectRefBucket ref == bucket,
                  prefixMatches prefix (objectRefKey ref)
                ]
            )

  deleteObject ref = do
    stateVar <- askMinIOState
    atomicallyLift do
      state <- readTVar stateVar
      writeTVar stateVar state {minioObjects = Map.delete ref (minioObjects state)}
      pure (Right ())

instance HasMinIOAdmin FilesystemMinIO where
  createBucket bucket = do
    stateVar <- askMinIOState
    atomicallyLift do
      state <- readTVar stateVar
      let existed = Set.member bucket (minioBuckets state)
      writeTVar stateVar state {minioBuckets = Set.insert bucket (minioBuckets state)}
      pure (Right (not existed))

  setBucketLifecycle bucket lifecycle = do
    stateVar <- askMinIOState
    atomicallyLift do
      state <- readTVar stateVar
      if Set.member bucket (minioBuckets state)
        then do
          let changed = Map.lookup bucket (minioLifecycles state) /= Just lifecycle
          writeTVar stateVar state {minioLifecycles = Map.insert bucket lifecycle (minioLifecycles state)}
          pure (Right changed)
        else pure (Left (MinIOAdminBucketNotFound bucket))

  listBuckets = do
    stateVar <- askMinIOState
    atomicallyLift do
      state <- readTVar stateVar
      pure (Right (Set.toList (minioBuckets state)))

  listObjectsByPrefix bucket prefix = do
    result <- listObjects bucket (Just prefix)
    pure case result of
      Left (BucketNotFound missing) -> Left (MinIOAdminBucketNotFound missing)
      Left err -> Left (MinIOAdminBackendUnavailable (Text.pack (show err)))
      Right keys -> Right keys

  deleteObjectAdmin ref = do
    result <- deleteObject ref
    pure case result of
      Left err -> Left (MinIOAdminBackendUnavailable (Text.pack (show err)))
      Right () -> Right True

askMinIOState :: FilesystemMinIO (TVar MinIOState)
askMinIOState = filesystemMinIOState <$> FilesystemMinIO ask

prefixMatches :: Maybe Text -> ObjectKey -> Bool
prefixMatches Nothing _ = True
prefixMatches (Just prefix) key = prefix `Text.isPrefixOf` unObjectKey key

atomicallyLift :: (MonadIO m) => STM a -> m a
atomicallyLift = liftIO . atomically
