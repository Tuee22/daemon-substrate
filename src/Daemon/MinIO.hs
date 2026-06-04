module Daemon.MinIO where

import Data.ByteString (ByteString)
import Data.Text (Text)

newtype BucketName = BucketName {unBucketName :: Text}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

newtype ObjectKey = ObjectKey {unObjectKey :: Text}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

data ObjectRef = ObjectRef
  { objectRefBucket :: BucketName,
    objectRefKey :: ObjectKey
  }
  deriving stock (Eq, Ord, Show)

newtype ETag = ETag {unETag :: Text}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

data ObjectBody = ObjectBody
  { objectBodyBytes :: ByteString,
    objectBodyETag :: ETag
  }
  deriving stock (Eq, Show)

data MinIOError
  = BucketNotFound BucketName
  | ObjectNotFound ObjectRef
  | ObjectAlreadyExists ObjectRef
  | ETagMismatch ObjectRef
  | InvalidObjectKey ObjectKey
  | MinIOBackendUnavailable Text
  deriving stock (Eq, Show)

class (Monad m) => HasMinIO m where
  minioGet :: ObjectRef -> m (Either MinIOError ObjectBody)
  putBlobIfAbsent :: ObjectRef -> ByteString -> m (Either MinIOError ETag)
  casPointer :: ObjectRef -> Maybe ETag -> ByteString -> m (Either MinIOError ETag)
  listObjects :: BucketName -> Maybe Text -> m (Either MinIOError [ObjectKey])
  deleteObject :: ObjectRef -> m (Either MinIOError ())
