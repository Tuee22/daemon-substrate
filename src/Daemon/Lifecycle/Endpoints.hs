module Daemon.Lifecycle.Endpoints
  ( EndpointResponse (..),
    renderLifecycleEndpoint,
    serveLifecycleEndpoints,
  )
where

import Control.Exception (bracket)
import Control.Monad (forever)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString.Char8
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text.Encoding
import Daemon.Lifecycle (DaemonRuntime (..))
import Network.Socket
  ( AddrInfo (addrAddress, addrFlags, addrSocketType),
    AddrInfoFlag (AI_PASSIVE),
    HostName,
    PortNumber,
    ServiceName,
    Socket,
    SocketOption (ReuseAddr),
    SocketType (Stream),
    accept,
    bind,
    close,
    defaultHints,
    getAddrInfo,
    listen,
    openSocket,
    setSocketOption,
    withSocketsDo,
  )
import qualified Network.Socket.ByteString as Socket.ByteString

data EndpointResponse = EndpointResponse
  { endpointResponseStatus :: !Int,
    endpointResponseContentType :: !ByteString,
    endpointResponseBody :: !ByteString
  }
  deriving stock (Eq, Show)

renderLifecycleEndpoint ::
  DaemonRuntime r app clients subscriptions ->
  ByteString ->
  EndpointResponse
renderLifecycleEndpoint runtime path =
  case path of
    "/healthz" ->
      EndpointResponse 200 "text/plain; charset=utf-8" "ok\n"
    "/readyz"
      | daemonRuntimeReady runtime ->
          EndpointResponse 200 "text/plain; charset=utf-8" "ready\n"
      | otherwise ->
          EndpointResponse 503 "text/plain; charset=utf-8" "not ready\n"
    "/metrics" ->
      EndpointResponse 200 "text/plain; version=0.0.4" (metricsBody runtime)
    _ ->
      EndpointResponse 404 "text/plain; charset=utf-8" "not found\n"

serveLifecycleEndpoints ::
  IO (DaemonRuntime r app clients subscriptions) ->
  HostName ->
  PortNumber ->
  IO ()
serveLifecycleEndpoints getRuntime host port =
  withSocketsDo do
    bracket (openEndpointSocket host port) close \socket ->
      forever do
        (connection, _) <- accept socket
        request <- Socket.ByteString.recv connection 4096
        runtime <- getRuntime
        Socket.ByteString.sendAll connection (httpResponse (renderLifecycleEndpoint runtime (requestPath request)))
        close connection

openEndpointSocket :: HostName -> PortNumber -> IO Socket
openEndpointSocket host port = do
  address : _ <- getAddrInfo (Just hints) (Just host) (Just (show port :: ServiceName))
  socket <- openSocket address
  setSocketOption socket ReuseAddr 1
  bind socket (addrAddress address)
  listen socket 16
  pure socket
  where
    hints =
      defaultHints
        { addrFlags = [AI_PASSIVE],
          addrSocketType = Stream
        }

requestPath :: ByteString -> ByteString
requestPath request =
  case ByteString.Char8.words (headLine request) of
    (_method : path : _) -> path
    _ -> "/"

headLine :: ByteString -> ByteString
headLine =
  ByteString.takeWhile (/= 10)

httpResponse :: EndpointResponse -> ByteString
httpResponse response =
  ByteString.concat
    [ "HTTP/1.1 ",
      ByteString.Char8.pack (show (endpointResponseStatus response)),
      " ",
      reasonPhrase (endpointResponseStatus response),
      "\r\nContent-Type: ",
      endpointResponseContentType response,
      "\r\nContent-Length: ",
      ByteString.Char8.pack (show (ByteString.length (endpointResponseBody response))),
      "\r\nConnection: close\r\n\r\n",
      endpointResponseBody response
    ]

reasonPhrase :: Int -> ByteString
reasonPhrase status =
  case status of
    200 -> "OK"
    404 -> "Not Found"
    503 -> "Service Unavailable"
    _ -> "Status"

metricsBody :: DaemonRuntime r app clients subscriptions -> ByteString
metricsBody runtime =
  ByteString.concat
    [ "daemon_lifecycle_ready ",
      if daemonRuntimeReady runtime then "1\n" else "0\n",
      "daemon_lifecycle_phase{phase=\"",
      Text.Encoding.encodeUtf8 (Text.pack (show (daemonRuntimePhase runtime))),
      "\"} 1\n"
    ]
