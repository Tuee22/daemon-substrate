module Daemon.Pulsar.Native.Connection where

import Control.Exception (AsyncException, SomeException, bracketOnError, fromException, throwIO, try)
import qualified Data.ByteString as ByteString
import Data.ProtoLens (defMessage)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as Text.Read
import Daemon.Pulsar.Native.Frame
import qualified Daemon.Proto.PulsarApi as Api
import Lens.Family2 ((&), (.~), (^.))
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as Socket.ByteString
import System.Timeout (timeout)

data BrokerAddress = BrokerAddress
  { brokerHost :: Text,
    brokerPort :: Int
  }
  deriving stock (Eq, Ord, Show)

data NativeConnection = NativeConnection
  { nativeConnectionAddress :: BrokerAddress,
    nativeConnectionSocket :: Socket.Socket,
    nativeConnectionTimeoutMicros :: Int
  }

data NativeConnectionError
  = NativeInvalidServiceUrl Text
  | NativeSocketUnavailable Text
  | NativeOperationTimedOut Text
  | NativeConnectionClosed
  | NativeFrameError PulsarFrameError
  | NativeUnexpectedCommand Api.BaseCommand'Type
  | NativeBrokerError Text
  deriving stock (Eq, Show)

withNativeConnection ::
  Text ->
  Int ->
  (NativeConnection -> IO (Either NativeConnectionError a)) ->
  IO (Either NativeConnectionError a)
withNativeConnection serviceUrl timeoutMicros action =
  case parseBrokerAddress serviceUrl of
    Left err -> pure (Left (NativeInvalidServiceUrl err))
    Right address -> withNativeBrokerAddress address timeoutMicros action

withNativeBrokerAddress ::
  BrokerAddress ->
  Int ->
  (NativeConnection -> IO (Either NativeConnectionError a)) ->
  IO (Either NativeConnectionError a)
withNativeBrokerAddress address timeoutMicros action = do
  opened <- openSocket address
  case opened of
    Left err -> pure (Left err)
    Right socket ->
      let connection =
            NativeConnection
              { nativeConnectionAddress = address,
                nativeConnectionSocket = socket,
                nativeConnectionTimeoutMicros = timeoutMicros
              }
       in do
            result <- tryAny (action connection)
            Socket.close socket
            pure case result of
              Left err -> Left (NativeSocketUnavailable (Text.pack (show err)))
              Right value -> value

parseBrokerAddress :: Text -> Either Text BrokerAddress
parseBrokerAddress serviceUrl
  | Just rest <- Text.stripPrefix "pulsar://" serviceUrl =
      parseAuthority rest
  | Just _ <- Text.stripPrefix "pulsar+ssl://" serviceUrl =
      Left "pulsar+ssl:// is not implemented by the Phase 2 native client"
  | Text.isInfixOf "://" serviceUrl =
      Left ("unsupported Pulsar service URL scheme: " <> serviceUrl)
  | otherwise =
      parseAuthority serviceUrl
  where
    parseAuthority rawAuthority =
      let authority = Text.takeWhile (/= '/') rawAuthority
       in case Text.breakOnEnd ":" authority of
            ("", host)
              | Text.null host -> Left "missing Pulsar broker host"
              | otherwise -> Right (BrokerAddress host 6650)
            (hostWithColon, portText) ->
              let host = Text.dropEnd 1 hostWithColon
               in if Text.null host || Text.null portText
                    then Left ("invalid Pulsar broker authority: " <> authority)
                    else case Text.Read.decimal portText of
                      Right (port, trailing)
                        | Text.null trailing && port > 0 ->
                            Right (BrokerAddress host port)
                      _ -> Left ("invalid Pulsar broker port: " <> portText)

openSocket :: BrokerAddress -> IO (Either NativeConnectionError Socket.Socket)
openSocket address = do
  resolved <- try resolve :: IO (Either SomeException [Socket.AddrInfo])
  case resolved of
    Left err -> pure (Left (NativeSocketUnavailable (Text.pack (show err))))
    Right [] -> pure (Left (NativeSocketUnavailable ("no address found for " <> brokerHost address)))
    Right (addr : _) -> do
      opened <- try (open addr) :: IO (Either SomeException Socket.Socket)
      pure case opened of
        Left err -> Left (NativeSocketUnavailable (Text.pack (show err)))
        Right socket -> Right socket
  where
    resolve =
      Socket.getAddrInfo
        ( Just
            Socket.defaultHints
              { Socket.addrSocketType = Socket.Stream
              }
        )
        (Just (Text.unpack (brokerHost address)))
        (Just (show (brokerPort address)))
    open addr =
      bracketOnError
        (Socket.socket (Socket.addrFamily addr) (Socket.addrSocketType addr) (Socket.addrProtocol addr))
        Socket.close
        \socket -> do
          Socket.connect socket (Socket.addrAddress addr)
          pure socket

connectHandshake :: NativeConnection -> Text -> IO (Either NativeConnectionError ())
connectHandshake connection clientVersion = do
  written <- writeCommand connection (connectCommand clientVersion) Nothing
  case written of
    Left err -> pure (Left err)
    Right () -> do
      response <- awaitCommand connection [Api.BaseCommand'CONNECTED]
      pure (() <$ response)

writeCommand :: NativeConnection -> Api.BaseCommand -> Maybe ByteString.ByteString -> IO (Either NativeConnectionError ())
writeCommand connection command payload =
  timed connection "write Pulsar frame" do
    Socket.ByteString.sendAll
      (nativeConnectionSocket connection)
      (encodePulsarFrame (PulsarFrame command payload))

readFrame :: NativeConnection -> IO (Either NativeConnectionError PulsarFrame)
readFrame connection = do
  header <- readExact connection 4
  case header of
    Left err -> pure (Left err)
    Right headerBytes -> do
      let frameSize = fromIntegral (decodeWord32BE headerBytes)
      body <- readExact connection frameSize
      pure case body of
        Left err -> Left err
        Right bodyBytes ->
          case decodePulsarFrame (headerBytes <> bodyBytes) of
            Left err -> Left (NativeFrameError err)
            Right frame -> Right frame

awaitCommand :: NativeConnection -> [Api.BaseCommand'Type] -> IO (Either NativeConnectionError PulsarFrame)
awaitCommand connection expected = loop
  where
    loop = do
      frame <- readFrame connection
      case frame of
        Left err -> pure (Left err)
        Right decoded ->
          case commandType decoded of
            Api.BaseCommand'PING -> do
              pongWritten <- writeCommand connection pongCommand Nothing
              case pongWritten of
                Left err -> pure (Left err)
                Right () -> loop
            Api.BaseCommand'ERROR ->
              pure (Left (NativeBrokerError (brokerErrorMessage (pulsarFrameCommand decoded))))
            Api.BaseCommand'ACTIVE_CONSUMER_CHANGE
              | Api.BaseCommand'ACTIVE_CONSUMER_CHANGE `elem` expected ->
                  pure (Right decoded)
              | otherwise -> loop
            Api.BaseCommand'CLOSE_CONSUMER ->
              pure (Left NativeConnectionClosed)
            actual
              | actual `elem` expected -> pure (Right decoded)
              | otherwise -> pure (Left (NativeUnexpectedCommand actual))

commandType :: PulsarFrame -> Api.BaseCommand'Type
commandType frame = pulsarFrameCommand frame ^. Api.type'

brokerErrorMessage :: Api.BaseCommand -> Text
brokerErrorMessage command =
  let err = command ^. Api.error
   in err ^. Api.message

readExact :: NativeConnection -> Int -> IO (Either NativeConnectionError ByteString.ByteString)
readExact connection wanted = loop ByteString.empty wanted
  where
    loop chunks remaining
      | remaining <= 0 = pure (Right chunks)
      | otherwise = do
          chunk <- timed connection "read Pulsar frame" (Socket.ByteString.recv (nativeConnectionSocket connection) remaining)
          case chunk of
            Left err -> pure (Left err)
            Right bytes
              | ByteString.null bytes -> pure (Left NativeConnectionClosed)
              | otherwise -> loop (chunks <> bytes) (remaining - ByteString.length bytes)

timed :: NativeConnection -> Text -> IO a -> IO (Either NativeConnectionError a)
timed connection label action = do
  result <- timeout (nativeConnectionTimeoutMicros connection) (tryAny action)
  pure case result of
    Nothing -> Left (NativeOperationTimedOut label)
    Just (Left err) -> Left (NativeSocketUnavailable (Text.pack (show err)))
    Just (Right value) -> Right value

tryAny :: IO a -> IO (Either SomeException a)
tryAny action = do
  result <- try action
  case result of
    Left err ->
      case fromException err :: Maybe AsyncException of
        Just _ -> throwIO err
        Nothing -> pure (Left err)
    Right value -> pure (Right value)

connectCommand :: Text -> Api.BaseCommand
connectCommand clientVersion =
  defMessage
    & Api.type' .~ Api.BaseCommand'CONNECT
    & Api.connect
      .~ ( defMessage
             & Api.clientVersion .~ clientVersion
             & Api.protocolVersion .~ 21
         )

pingCommand :: Api.BaseCommand
pingCommand =
  defMessage
    & Api.type' .~ Api.BaseCommand'PING
    & Api.ping .~ defMessage

pongCommand :: Api.BaseCommand
pongCommand =
  defMessage
    & Api.type' .~ Api.BaseCommand'PONG
    & Api.pong .~ defMessage
