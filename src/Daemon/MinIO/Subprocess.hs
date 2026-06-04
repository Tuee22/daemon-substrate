module Daemon.MinIO.Subprocess where

import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import Data.Bits ((.&.), shiftL, shiftR, (.|.))
import qualified Data.ByteString.Char8 as ByteString.Char8
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as Text.Read
import Data.Word (Word8)
import qualified Crypto.Hash.SHA256 as SHA256
import Daemon.MinIO
import Daemon.MinIO.Admin
import Daemon.MinIO.Store (stableETag)
import Daemon.Sub

data SubprocessMinIO = SubprocessMinIO
  { subprocessMinIOEndpoint :: Text,
    subprocessMinIOCurl :: FilePath,
    subprocessMinIOExtraCurlArgs :: [String],
    subprocessMinIOSigV4 :: Maybe SigV4Credentials
  }
  deriving stock (Eq, Show)

data SigV4Credentials = SigV4Credentials
  { sigV4AccessKey :: Text,
    sigV4SecretKey :: Text,
    sigV4Region :: Text,
    sigV4Service :: Text
  }
  deriving stock (Eq, Show)

newtype SubprocessMinIOT m a = SubprocessMinIOT
  {unSubprocessMinIOT :: ReaderT SubprocessMinIO m a}
  deriving newtype (Functor, Applicative, Monad, MonadIO)

runSubprocessMinIOT :: SubprocessMinIO -> SubprocessMinIOT m a -> m a
runSubprocessMinIOT config action = runReaderT (unSubprocessMinIOT action) config

instance (MonadIO m) => HasMinIO (SubprocessMinIOT m) where
  minioGet ref = do
    config <- SubprocessMinIOT ask
    result <- runCurl config ["--fail-with-body", "-X", "GET", objectUrl config ref] mempty
    pure case result of
      Left err -> Left err
      Right body -> Right (ObjectBody body (stableETag body))

  putBlobIfAbsent ref bytes = do
    config <- SubprocessMinIOT ask
    result <-
      runCurl
        config
        ["--fail-with-body", "-X", "PUT", "-H", "If-None-Match: *", "--data-binary", "@-", objectUrl config ref]
        bytes
    pure case result of
      Left err -> Left err
      Right _ -> Right (stableETag bytes)

  casPointer ref expected bytes = do
    config <- SubprocessMinIOT ask
    let condition =
          case expected of
            Nothing -> "If-None-Match: *"
            Just etag -> "If-Match: " <> Text.unpack (unETag etag)
    result <-
      runCurl
        config
        ["--fail-with-body", "-X", "PUT", "-H", condition, "--data-binary", "@-", objectUrl config ref]
        bytes
    pure case result of
      Left _ -> Left (ETagMismatch ref)
      Right _ -> Right (stableETag bytes)

  listObjects bucket prefix = do
    config <- SubprocessMinIOT ask
    let url = bucketUrl config bucket <> "?list-type=2" <> maybe "" (("&prefix=" <>) . Text.unpack) prefix
    result <- runCurl config ["--fail-with-body", "-X", "GET", url] mempty
    pure case result of
      Left err -> Left err
      Right body -> Right (ObjectKey <$> listObjectsKeys body)

  deleteObject ref = do
    config <- SubprocessMinIOT ask
    result <- runCurl config ["--fail-with-body", "-X", "DELETE", objectUrl config ref] mempty
    pure case result of
      Left err -> Left err
      Right _ -> Right ()

instance (MonadIO m) => HasMinIOAdmin (SubprocessMinIOT m) where
  createBucket bucket = do
    config <- SubprocessMinIOT ask
    result <- runCurlStatus config ["-X", "PUT", bucketUrl config bucket] mempty
    pure case result of
      Left err -> Left (toAdminError err)
      Right status
        | httpStatusSuccessful status -> Right True
        | status == 409 -> Right False
        | otherwise -> Left (MinIOAdminBackendUnavailable ("unexpected MinIO create-bucket status: " <> Text.pack (show status)))

  setBucketLifecycle bucket lifecycle = do
    config <- SubprocessMinIOT ask
    case bucketLifecycleRetentionDays lifecycle of
      Nothing -> pure (Right False)
      Just _ -> do
        let body = ByteString.Char8.pack (bucketLifecycleBody lifecycle)
            checksum = base64Encode (SHA256.hash body)
        result <-
          runCurlStatus
            config
            [ "-X",
              "PUT",
              "-H",
              "Content-Type: application/xml",
              "-H",
              "x-amz-checksum-sha256: " <> checksum,
              "--data-binary",
              "@-",
              bucketUrl config bucket <> "?lifecycle"
            ]
            body
        pure case result of
          Left err -> Left (toAdminError err)
          Right status
            | httpStatusSuccessful status -> Right True
            | status == 404 -> Left (MinIOAdminBucketNotFound bucket)
            | otherwise -> Left (MinIOAdminBackendUnavailable ("unexpected MinIO lifecycle status: " <> Text.pack (show status)))

  listBuckets = do
    config <- SubprocessMinIOT ask
    result <- runCurl config ["--fail-with-body", "-X", "GET", Text.unpack (subprocessMinIOEndpoint config)] mempty
    pure case result of
      Left err -> Left (toAdminError err)
      Right body -> Right (BucketName . Text.pack <$> lines (ByteString.Char8.unpack body))

  listObjectsByPrefix bucket prefix = do
    result <- listObjects bucket (Just prefix)
    pure case result of
      Left err -> Left (toAdminError err)
      Right keys -> Right keys

  deleteObjectAdmin ref = do
    result <- deleteObject ref
    pure case result of
      Left err -> Left (toAdminError err)
      Right () -> Right True

runCurl :: (MonadIO m) => SubprocessMinIO -> [String] -> ByteString.Char8.ByteString -> m (Either MinIOError ByteString.Char8.ByteString)
runCurl config args input = do
  result <-
    runSubprocess
      Subprocess
        { subprocessExecutable = subprocessMinIOCurl config,
          subprocessArguments = subprocessMinIOExtraCurlArgs config <> minioAuthArgs config <> args,
          subprocessInput = input
        }
  pure case result of
    Left err -> Left (MinIOBackendUnavailable (Text.pack (show err)))
    Right completed
      | subprocessSucceeded completed -> Right (ByteString.Char8.pack (subprocessStdout completed))
      | otherwise -> Left (MinIOBackendUnavailable (Text.pack (subprocessStderr completed)))

runCurlStatus :: (MonadIO m) => SubprocessMinIO -> [String] -> ByteString.Char8.ByteString -> m (Either MinIOError Int)
runCurlStatus config args input = do
  result <-
    runSubprocess
      Subprocess
        { subprocessExecutable = subprocessMinIOCurl config,
          subprocessArguments = subprocessMinIOExtraCurlArgs config <> minioAuthArgs config <> ["--output", "/dev/null", "--write-out", "%{http_code}"] <> args,
          subprocessInput = input
        }
  pure case result of
    Left err -> Left (MinIOBackendUnavailable (Text.pack (show err)))
    Right completed
      | subprocessSucceeded completed ->
          case Text.Read.decimal (Text.strip (Text.pack (subprocessStdout completed))) of
            Right (status, trailing)
              | Text.null trailing -> Right status
            _ -> Left (MinIOBackendUnavailable ("curl returned non-numeric HTTP status: " <> Text.pack (subprocessStdout completed)))
      | otherwise -> Left (MinIOBackendUnavailable (Text.pack (subprocessStderr completed)))

objectUrl :: SubprocessMinIO -> ObjectRef -> String
objectUrl config ref = bucketUrl config (objectRefBucket ref) <> "/" <> Text.unpack (unObjectKey (objectRefKey ref))

bucketUrl :: SubprocessMinIO -> BucketName -> String
bucketUrl config bucket =
  trimTrailingSlash (Text.unpack (subprocessMinIOEndpoint config)) <> "/" <> Text.unpack (unBucketName bucket)

trimTrailingSlash :: String -> String
trimTrailingSlash = reverse . dropWhile (== '/') . reverse

minioAuthArgs :: SubprocessMinIO -> [String]
minioAuthArgs config =
  case subprocessMinIOSigV4 config of
    Nothing -> []
    Just credentials ->
      [ "--aws-sigv4",
        "aws:amz:" <> Text.unpack (sigV4Region credentials) <> ":" <> Text.unpack (sigV4Service credentials),
        "-u",
        Text.unpack (sigV4AccessKey credentials) <> ":" <> Text.unpack (sigV4SecretKey credentials)
      ]

toAdminError :: MinIOError -> MinIOAdminError
toAdminError (BucketNotFound bucket) = MinIOAdminBucketNotFound bucket
toAdminError err = MinIOAdminBackendUnavailable (Text.pack (show err))

httpStatusSuccessful :: Int -> Bool
httpStatusSuccessful status = status >= 200 && status < 300

bucketLifecycleBody :: BucketLifecycle -> String
bucketLifecycleBody lifecycle =
  case bucketLifecycleRetentionDays lifecycle of
    Nothing ->
      "<LifecycleConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"/>"
    Just days ->
      "<LifecycleConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
        <> "<Rule>"
        <> "<ID>"
        <> Text.unpack (xmlEscape (bucketLifecycleName lifecycle))
        <> "</ID>"
        <> "<Status>Enabled</Status>"
        <> "<Filter><Prefix></Prefix></Filter>"
        <> "<Expiration><Days>"
        <> show days
        <> "</Days></Expiration>"
        <> "</Rule>"
        <> "</LifecycleConfiguration>"

listObjectsKeys :: ByteString.Char8.ByteString -> [Text]
listObjectsKeys body =
  extractXmlTag "Key" (Text.pack (ByteString.Char8.unpack body))

extractXmlTag :: Text -> Text -> [Text]
extractXmlTag tag input =
  case Text.breakOn open input of
    (_, rest)
      | Text.null rest -> []
      | otherwise ->
          let afterOpen = Text.drop (Text.length open) rest
              (value, afterValue) = Text.breakOn close afterOpen
           in if Text.null afterValue
                then []
                else xmlUnescape value : extractXmlTag tag (Text.drop (Text.length close) afterValue)
  where
    open = "<" <> tag <> ">"
    close = "</" <> tag <> ">"

xmlEscape :: Text -> Text
xmlEscape =
  Text.concatMap \char ->
    case char of
      '&' -> "&amp;"
      '<' -> "&lt;"
      '>' -> "&gt;"
      '"' -> "&quot;"
      '\'' -> "&apos;"
      _ -> Text.singleton char

xmlUnescape :: Text -> Text
xmlUnescape =
  Text.replace "&apos;" "'"
    . Text.replace "&quot;" "\""
    . Text.replace "&gt;" ">"
    . Text.replace "&lt;" "<"
    . Text.replace "&amp;" "&"

base64Encode :: ByteString.Char8.ByteString -> String
base64Encode input =
  encodeBytes (ByteString.Char8.unpack input)
  where
    encodeBytes [] = []
    encodeBytes [a] =
      [ alphabetChar (byte a `shiftR` 2),
        alphabetChar ((byte a .&. 0x03) `shiftL` 4),
        '=',
        '='
      ]
    encodeBytes [a, b] =
      [ alphabetChar (byte a `shiftR` 2),
        alphabetChar (((byte a .&. 0x03) `shiftL` 4) .|. (byte b `shiftR` 4)),
        alphabetChar ((byte b .&. 0x0f) `shiftL` 2),
        '='
      ]
    encodeBytes (a : b : c : rest) =
      [ alphabetChar (byte a `shiftR` 2),
        alphabetChar (((byte a .&. 0x03) `shiftL` 4) .|. (byte b `shiftR` 4)),
        alphabetChar (((byte b .&. 0x0f) `shiftL` 2) .|. (byte c `shiftR` 6)),
        alphabetChar (byte c .&. 0x3f)
      ]
        <> encodeBytes rest

    byte = fromIntegral . fromEnum

alphabetChar :: Word8 -> Char
alphabetChar index =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" !! fromIntegral index
