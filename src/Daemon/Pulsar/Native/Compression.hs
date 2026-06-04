module Daemon.Pulsar.Native.Compression where

data Compression
  = CompressionNone
  | CompressionLz4
  | CompressionZstd
  | CompressionSnappy
  | CompressionZlib
  deriving stock (Eq, Ord, Show, Enum, Bounded)
