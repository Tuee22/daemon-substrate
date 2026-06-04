module Daemon.MinIO.Store where

import Data.Bits (xor)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Daemon.MinIO

putBlob :: (HasMinIO m) => BucketName -> ByteString -> m (Either MinIOError ObjectRef)
putBlob bucket bytes = do
  let ref = ObjectRef bucket (ObjectKey ("blobs/" <> unETag (stableETag bytes)))
  result <- putBlobIfAbsent ref bytes
  pure case result of
    Left (ObjectAlreadyExists _) -> Right ref
    Left err -> Left err
    Right _ -> Right ref

readBlob :: (HasMinIO m) => ObjectRef -> m (Either MinIOError ByteString)
readBlob ref = fmap objectBodyBytes <$> minioGet ref

putManifest :: (HasMinIO m) => BucketName -> Text -> ByteString -> m (Either MinIOError ObjectRef)
putManifest bucket name bytes = do
  let ref = ObjectRef bucket (ObjectKey ("manifests/" <> name))
  result <- putBlobIfAbsent ref bytes
  pure case result of
    Left (ObjectAlreadyExists _) -> Right ref
    Left err -> Left err
    Right _ -> Right ref

readManifest :: (HasMinIO m) => ObjectRef -> m (Either MinIOError ByteString)
readManifest = readBlob

writePointer :: (HasMinIO m) => BucketName -> Text -> Maybe ETag -> ByteString -> m (Either MinIOError ETag)
writePointer bucket name expected =
  casPointer (ObjectRef bucket (ObjectKey ("pointers/" <> name))) expected

stableETag :: ByteString -> ETag
stableETag bytes =
  ETag (Text.pack (show (ByteString.foldl' step (14695981039346656037 :: Word64) bytes)))
  where
    step acc byte = (acc `xor` fromIntegral byte) * 1099511628211
