module Daemon.Pulsar.Admin.Http where

import Control.Exception (try)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import qualified Data.ByteString.Char8 as ByteString.Char8
import qualified Data.ByteString.Lazy.Char8 as LazyByteString.Char8
import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.Pulsar (TopicName (TopicName, unTopicName))
import Daemon.Pulsar.Admin
import Numeric.Natural (Natural)
import Network.HTTP.Client
  ( HttpException,
    Manager,
    Request (method, requestBody, requestHeaders, responseTimeout),
    RequestBody (RequestBodyLBS),
    Response,
    httpLbs,
    newManager,
    parseRequest,
    responseBody,
    responseStatus,
    responseTimeoutMicro,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Header (RequestHeaders, hAuthorization, hContentType)
import Network.HTTP.Types.Status (statusCode)

data PulsarAdminHttp = PulsarAdminHttp
  { pulsarAdminBaseUrl :: Text,
    pulsarAdminTimeoutMicros :: Int,
    pulsarAdminBearerToken :: Maybe Text
  }
  deriving stock (Eq, Show)

newtype PulsarAdminHttpT m a = PulsarAdminHttpT
  {unPulsarAdminHttpT :: ReaderT PulsarAdminHttp m a}
  deriving newtype (Functor, Applicative, Monad, MonadIO)

data HttpAdminResponse = HttpAdminResponse
  { httpAdminStatus :: Int,
    httpAdminBody :: String
  }
  deriving stock (Eq, Show)

runPulsarAdminHttpT :: PulsarAdminHttp -> PulsarAdminHttpT m a -> m a
runPulsarAdminHttpT config action = runReaderT (unPulsarAdminHttpT action) config

instance (MonadIO m) => HasPulsarAdmin (PulsarAdminHttpT m) where
  createTopic topic = do
    response <- adminRequest "PUT" (topicPath topic) ""
    pure (statusResult topic "topic created" response)

  deleteTopic topic = do
    response <- adminRequest "DELETE" (topicPath topic) ""
    pure (statusResult topic "topic deleted" response)

  terminateTopic topic = do
    response <- adminRequest "POST" (topicPath topic <> "/terminate") ""
    pure (statusResult topic "topic terminated" response)

  setRetention topic policy = do
    response <- adminRequest "POST" (topicPath topic <> "/retention") (retentionPolicyBody policy)
    pure (statusResult topic "retention configured" response)

  setCompaction topic policy = do
    response <- adminRequest "POST" (topicPath topic <> "/compactionThreshold") (compactionPolicyBody policy)
    pure (statusResult topic "compaction configured" response)

  setDedupWindow topic window = do
    response <- adminRequest "POST" (topicPath topic <> "/deduplicationSnapshotInterval") (dedupWindowBody window)
    pure (statusResult topic "dedup window configured" response)

  listTopics = do
    response <- adminRequest "GET" "/admin/v2/persistent" ""
    pure case response of
      Left err -> Left err
      Right ok
        | successStatus (httpAdminStatus ok) ->
            Right (TopicName . Text.pack <$> lines (httpAdminBody ok))
        | otherwise ->
            Left (PulsarAdminBackendUnavailable (Text.pack (httpAdminBody ok)))

  exportTopicToObject topic objectRef = do
    response <- adminRequest "POST" (topicPath topic <> "/export") (Text.unpack objectRef)
    pure (statusResult topic "topic exported" response)

  importTopicFromObject topic objectRef = do
    response <- adminRequest "POST" (topicPath topic <> "/import") (Text.unpack objectRef)
    pure (statusResult topic "topic imported" response)

adminRequest :: (MonadIO m) => String -> String -> String -> PulsarAdminHttpT m (Either PulsarAdminError HttpAdminResponse)
adminRequest httpMethod path body = do
  config <- PulsarAdminHttpT ask
  liftIO do
    manager <- newManager tlsManagerSettings
    response <- try (sendHttp manager config httpMethod path body) :: IO (Either HttpException HttpAdminResponse)
    pure case response of
      Left err -> Left (PulsarAdminBackendUnavailable (Text.pack (show err)))
      Right ok -> Right ok

sendHttp :: Manager -> PulsarAdminHttp -> String -> String -> String -> IO HttpAdminResponse
sendHttp manager config httpMethod path body = do
  baseRequest <- parseRequest (adminUrl config path)
  let request =
        baseRequest
          { method = ByteString.Char8.pack httpMethod,
            requestBody = RequestBodyLBS (LazyByteString.Char8.pack body),
            requestHeaders = authHeaders config <> [(hContentType, "application/json")],
            responseTimeout = responseTimeoutMicro (pulsarAdminTimeoutMicros config)
          }
  response <- httpLbs request manager
  pure (fromResponse response)

fromResponse :: Response LazyByteString.Char8.ByteString -> HttpAdminResponse
fromResponse response =
  HttpAdminResponse
    { httpAdminStatus = statusCode (responseStatus response),
      httpAdminBody = LazyByteString.Char8.unpack (responseBody response)
    }

adminUrl :: PulsarAdminHttp -> String -> String
adminUrl config path =
  trimTrailingSlash (Text.unpack (pulsarAdminBaseUrl config)) <> "/" <> dropWhile (== '/') path

authHeaders :: PulsarAdminHttp -> RequestHeaders
authHeaders config =
  case pulsarAdminBearerToken config of
    Nothing -> []
    Just token ->
      [ ( hAuthorization,
          "Bearer " <> ByteString.Char8.pack (Text.unpack token)
        )
      ]

trimTrailingSlash :: String -> String
trimTrailingSlash = reverse . dropWhile (== '/') . reverse

topicPath :: TopicName -> String
topicPath topic =
  "/admin/v2/" <> Text.unpack (topicRestPath (unTopicName topic))

topicRestPath :: Text -> Text
topicRestPath topic =
  case Text.stripPrefix "persistent://" topic of
    Just rest -> "persistent/" <> rest
    Nothing -> topic

retentionPolicyBody :: RetentionPolicy -> String
retentionPolicyBody policy =
  "{"
    <> "\"retentionTimeInMinutes\":"
    <> show (maybe (-1) secondsToMinutes (retentionTimeSeconds policy))
    <> ",\"retentionSizeInMB\":"
    <> show (maybe (-1) bytesToMegabytes (retentionSizeBytes policy))
    <> "}"

secondsToMinutes :: Int -> Int
secondsToMinutes secondsValue =
  ceilingDiv (max 0 secondsValue) 60

bytesToMegabytes :: Int -> Int
bytesToMegabytes bytesValue =
  ceilingDiv (max 0 bytesValue) (1024 * 1024)

compactionPolicyBody :: CompactionPolicy -> String
compactionPolicyBody policy =
  show (compactionThresholdBytes policy)

dedupWindowBody :: DedupWindow -> String
dedupWindowBody window =
  show (dedupWindowSeconds window)

ceilingDiv :: Int -> Int -> Int
ceilingDiv numerator denominator =
  fromIntegral (toNatural numerator + toNatural denominator - 1) `div` denominator

toNatural :: Int -> Natural
toNatural value =
  fromIntegral (max 0 value)

statusResult :: TopicName -> Text -> Either PulsarAdminError HttpAdminResponse -> Either PulsarAdminError AdminActionResult
statusResult topic detail response =
  case response of
    Left err -> Left err
    Right ok
      | successStatus (httpAdminStatus ok) -> Right (AdminActionResult True detail)
      | httpAdminStatus ok == 404 -> Left (PulsarAdminTopicNotFound topic)
      | httpAdminStatus ok == 409 -> Right (AdminActionResult False detail)
      | otherwise -> Left (PulsarAdminBackendUnavailable (Text.pack (httpAdminBody ok)))

successStatus :: Int -> Bool
successStatus status = status >= 200 && status < 300
