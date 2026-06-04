module Daemon.Pulsar.Native.Frame where

import Data.Bits (complement, shiftL, shiftR, xor, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.ProtoLens.Encoding (decodeMessage, encodeMessage)
import Data.Word (Word16, Word32, Word8)
import Daemon.Proto.PulsarApi (BaseCommand, MessageMetadata)

data PulsarFrame = PulsarFrame
  { pulsarFrameCommand :: BaseCommand,
    pulsarFramePayload :: Maybe ByteString
  }
  deriving stock (Eq, Show)

data PulsarFrameError
  = PulsarFrameTooShort Int
  | PulsarFrameSizeMismatch
      { pulsarFrameDeclaredSize :: Int,
        pulsarFrameActualSize :: Int
      }
  | PulsarFrameCommandTooShort Int
  | PulsarFrameCommandDecodeFailed String
  deriving stock (Eq, Show)

data PulsarPayload = PulsarPayload
  { pulsarPayloadMetadata :: MessageMetadata,
    pulsarPayloadBytes :: ByteString
  }
  deriving stock (Eq, Show)

data PulsarPayloadError
  = PulsarPayloadTooShort Int
  | PulsarPayloadBadMagic Word16
  | PulsarPayloadChecksumMismatch
      { pulsarPayloadExpectedChecksum :: Word32,
        pulsarPayloadActualChecksum :: Word32
      }
  | PulsarPayloadMetadataTooShort Int
  | PulsarPayloadMetadataDecodeFailed String
  deriving stock (Eq, Show)

encodePulsarFrame :: PulsarFrame -> ByteString
encodePulsarFrame frame =
  ByteString.concat
    [ encodeWord32BE (fromIntegral totalSize),
      encodeWord32BE (fromIntegral commandSize),
      commandBytes,
      payloadBytes
    ]
  where
    commandBytes = encodeMessage (pulsarFrameCommand frame)
    payloadBytes = maybe ByteString.empty id (pulsarFramePayload frame)
    commandSize = ByteString.length commandBytes
    totalSize = 4 + commandSize + ByteString.length payloadBytes

decodePulsarFrame :: ByteString -> Either PulsarFrameError PulsarFrame
decodePulsarFrame bytes
  | ByteString.length bytes < 4 =
      Left (PulsarFrameTooShort (ByteString.length bytes))
  | declaredSize /= ByteString.length body =
      Left
        PulsarFrameSizeMismatch
          { pulsarFrameDeclaredSize = declaredSize,
            pulsarFrameActualSize = ByteString.length body
          }
  | ByteString.length body < 4 =
      Left (PulsarFrameCommandTooShort (ByteString.length body))
  | commandSize > ByteString.length commandAndPayload =
      Left (PulsarFrameCommandTooShort commandSize)
  | otherwise =
      case decodeMessage commandBytes of
        Left err -> Left (PulsarFrameCommandDecodeFailed err)
        Right command ->
          Right
            PulsarFrame
              { pulsarFrameCommand = command,
                pulsarFramePayload =
                  if ByteString.null payloadBytes
                    then Nothing
                    else Just payloadBytes
              }
  where
    (sizeBytes, body) = ByteString.splitAt 4 bytes
    declaredSize = fromIntegral (decodeWord32BE sizeBytes)
    (commandSizeBytes, commandAndPayload) = ByteString.splitAt 4 body
    commandSize = fromIntegral (decodeWord32BE commandSizeBytes)
    (commandBytes, payloadBytes) = ByteString.splitAt commandSize commandAndPayload

encodePulsarPayload :: PulsarPayload -> ByteString
encodePulsarPayload payload =
  ByteString.concat
    [ encodeWord16BE payloadMagic,
      encodeWord32BE (crc32c checksumBody),
      checksumBody
    ]
  where
    metadataBytes = encodeMessage (pulsarPayloadMetadata payload)
    checksumBody =
      ByteString.concat
        [ encodeWord32BE (fromIntegral (ByteString.length metadataBytes)),
          metadataBytes,
          pulsarPayloadBytes payload
        ]

decodePulsarPayload :: ByteString -> Either PulsarPayloadError PulsarPayload
decodePulsarPayload bytes
  | ByteString.length bytes < 10 =
      Left (PulsarPayloadTooShort (ByteString.length bytes))
  | magic /= payloadMagic =
      Left (PulsarPayloadBadMagic magic)
  | expectedChecksum /= actualChecksum =
      Left
        PulsarPayloadChecksumMismatch
          { pulsarPayloadExpectedChecksum = expectedChecksum,
            pulsarPayloadActualChecksum = actualChecksum
          }
  | metadataSize > ByteString.length payloadBody =
      Left (PulsarPayloadMetadataTooShort metadataSize)
  | otherwise =
      case decodeMessage metadataBytes of
        Left err -> Left (PulsarPayloadMetadataDecodeFailed err)
        Right metadata ->
          Right
            PulsarPayload
              { pulsarPayloadMetadata = metadata,
                pulsarPayloadBytes = messageBytes
              }
  where
    (magicBytes, afterMagic) = ByteString.splitAt 2 bytes
    magic = decodeWord16BE magicBytes
    (checksumBytes, checksumBody) = ByteString.splitAt 4 afterMagic
    expectedChecksum = decodeWord32BE checksumBytes
    actualChecksum = crc32c checksumBody
    (metadataSizeBytes, payloadBody) = ByteString.splitAt 4 checksumBody
    metadataSize = fromIntegral (decodeWord32BE metadataSizeBytes)
    (metadataBytes, messageBytes) = ByteString.splitAt metadataSize payloadBody

encodeWord32BE :: Word32 -> ByteString
encodeWord32BE value =
  ByteString.pack
    [ fromIntegral ((value `shiftR` 24) .&. 0xff),
      fromIntegral ((value `shiftR` 16) .&. 0xff),
      fromIntegral ((value `shiftR` 8) .&. 0xff),
      fromIntegral (value .&. 0xff)
    ]

encodeWord16BE :: Word16 -> ByteString
encodeWord16BE value =
  ByteString.pack
    [ fromIntegral ((value `shiftR` 8) .&. 0xff),
      fromIntegral (value .&. 0xff)
    ]

decodeWord32BE :: ByteString -> Word32
decodeWord32BE bytes =
  ByteString.foldl' step 0 (ByteString.take 4 bytes)
  where
    step acc byte = (acc `shiftL` 8) + fromIntegral byte

decodeWord16BE :: ByteString -> Word16
decodeWord16BE bytes =
  ByteString.foldl' step 0 (ByteString.take 2 bytes)
  where
    step acc byte = (acc `shiftL` 8) + fromIntegral byte

crc32c :: ByteString -> Word32
crc32c bytes = complement (ByteString.foldl' update 0xffffffff bytes)
  where
    update :: Word32 -> Word8 -> Word32
    update crc byte = iterateCrc 8 (crc `xor` fromIntegral byte)
    iterateCrc :: Int -> Word32 -> Word32
    iterateCrc 0 crc = crc
    iterateCrc n crc =
      iterateCrc (n - 1) $
        if crc .&. 1 == 1
          then (crc `shiftR` 1) `xor` crc32cPolynomial
          else crc `shiftR` 1

payloadMagic :: Word16
payloadMagic = 0x0e01

crc32cPolynomial :: Word32
crc32cPolynomial = 0x82f63b78
