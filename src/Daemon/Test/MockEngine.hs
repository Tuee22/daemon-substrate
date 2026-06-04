module Daemon.Test.MockEngine where

import Control.Monad.IO.Class (MonadIO)
import qualified Crypto.Hash.SHA256 as SHA256
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.ProtoLens (defMessage)
import Data.ProtoLens.Encoding (decodeMessage, encodeMessage)
import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8)
import Daemon.Engine
import Daemon.MinIO
import Daemon.MinIO.Cache
import qualified Daemon.Proto.Mock as Mock
import Lens.Family2 ((&), (.~), (^.))

newtype MockEngine = MockEngine
  { mockEngineCache :: Cache
  }

mockNativeEngine :: (HasMinIO m, MonadIO m) => MockEngine -> NativeEngine m
mockNativeEngine engine =
  NativeEngine (traverse (runMockRequest engine))

runMockRequest ::
  (HasMinIO m, MonadIO m) =>
  MockEngine ->
  EngineRequest ->
  m (Either EngineError EngineResponse)
runMockRequest engine request =
  case decodeMessage (engineRequestPayload request) of
    Left err ->
      pure
        ( Left
            EngineRequestFailed
              { engineErrorRequestId = engineRequestId request,
                engineErrorDetail = "mock request decode failed: " <> Text.pack err
              }
        )
    Right mockRequest
      | mockRequest ^. Mock.forceFailure ->
          pure
            ( Left
                EngineRequestFailed
                  { engineErrorRequestId = mockRequest ^. Mock.requestId,
                    engineErrorDetail = "mock forced failure"
                  }
            )
      | otherwise -> do
          weight <- readWithCache (mockEngineCache engine) (mockWeightRef mockRequest)
          pure case weight of
            Left err ->
              Left
                EngineRequestFailed
                  { engineErrorRequestId = mockRequest ^. Mock.requestId,
                    engineErrorDetail = "mock weight read failed: " <> Text.pack (show err)
                  }
            Right weightBytes ->
              let result = mockResult mockRequest weightBytes
               in Right
                    EngineResponse
                      { engineResponseRequestId = mockRequest ^. Mock.requestId,
                        engineResponsePayload = encodeMessage result
                      }

mockWeightRef :: Mock.MockRequest -> ObjectRef
mockWeightRef request =
  ObjectRef
    (BucketName (request ^. Mock.weightBucket))
    (ObjectKey (request ^. Mock.weightKey))

mockResult :: Mock.MockRequest -> ByteString -> Mock.MockResult
mockResult request weightBytes =
  defMessage
    & Mock.requestId .~ (request ^. Mock.requestId)
    & Mock.resultPayload .~ mockResultPayload request weightBytes

mockResultPayload :: Mock.MockRequest -> ByteString -> ByteString
mockResultPayload request weightBytes =
  SHA256.hash
    ( ByteString.concat
        [ encodeUtf8 (request ^. Mock.requestId),
          request ^. Mock.inputPayload,
          weightBytes
        ]
    )
