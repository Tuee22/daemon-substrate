module Daemon.MinIO.Admin where

import Data.Text (Text)
import Daemon.MinIO

data BucketLifecycle = BucketLifecycle
  { bucketLifecycleName :: Text,
    bucketLifecycleRetentionDays :: Maybe Int
  }
  deriving stock (Eq, Show)

data MinIOAdminError
  = MinIOAdminBucketNotFound BucketName
  | MinIOAdminBackendUnavailable Text
  deriving stock (Eq, Show)

class (Monad m) => HasMinIOAdmin m where
  createBucket :: BucketName -> m (Either MinIOAdminError Bool)
  setBucketLifecycle :: BucketName -> BucketLifecycle -> m (Either MinIOAdminError Bool)
  listBuckets :: m (Either MinIOAdminError [BucketName])
  listObjectsByPrefix :: BucketName -> Text -> m (Either MinIOAdminError [ObjectKey])
  deleteObjectAdmin :: ObjectRef -> m (Either MinIOAdminError Bool)
