module Daemon.Test.EchoEngines where

import Daemon.Engine

nativeEchoEngine :: (Monad m) => NativeEngine m
nativeEchoEngine =
  NativeEngine (pure . fmap (Right . echoResponse))

subprocessEchoEngine :: FilePath -> Int -> SubprocessEngine
subprocessEchoEngine executable timeoutMicros =
  SubprocessEngine
    { subprocessEngineExecutable = executable,
      subprocessEngineArguments = [],
      subprocessEngineTimeoutMicros = timeoutMicros
    }
