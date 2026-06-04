module Daemon.Signal
  ( DaemonRuntimeSnapshot (..),
    DaemonSignal (..),
    InstalledDaemonSignalHandlers (..),
    applyDaemonSignal,
    installDaemonSignalHandlers,
  )
where

import Daemon.Lifecycle
  ( DaemonRuntime (..),
    LifecyclePhase (Drain),
  )
import System.Posix.Signals
  ( Handler (Catch),
    installHandler,
    sigHUP,
    sigINT,
    sigTERM,
  )

data DaemonSignal
  = DaemonSIGHUP
  | DaemonSIGTERM
  | DaemonSIGINT
  deriving stock (Eq, Ord, Show)

data DaemonRuntimeSnapshot r app clients subscriptions = DaemonRuntimeSnapshot
  { daemonRuntimeSnapshotSignal :: !DaemonSignal,
    daemonRuntimeSnapshotRuntime :: !(DaemonRuntime r app clients subscriptions),
    daemonRuntimeSnapshotReloadRequested :: !Bool,
    daemonRuntimeSnapshotDrainRequested :: !Bool
  }
  deriving stock (Eq, Show)

data InstalledDaemonSignalHandlers = InstalledDaemonSignalHandlers
  deriving stock (Eq, Show)

applyDaemonSignal ::
  DaemonRuntime r app clients subscriptions ->
  DaemonSignal ->
  IO (DaemonRuntimeSnapshot r app clients subscriptions)
applyDaemonSignal runtime signal =
  pure
    DaemonRuntimeSnapshot
      { daemonRuntimeSnapshotSignal = signal,
        daemonRuntimeSnapshotRuntime = updatedRuntime,
        daemonRuntimeSnapshotReloadRequested = signal == DaemonSIGHUP,
        daemonRuntimeSnapshotDrainRequested = signal == DaemonSIGTERM || signal == DaemonSIGINT
      }
  where
    updatedRuntime =
      case signal of
        DaemonSIGHUP ->
          runtime
        DaemonSIGTERM ->
          runtime {daemonRuntimePhase = Drain, daemonRuntimeReady = False}
        DaemonSIGINT ->
          runtime {daemonRuntimePhase = Drain, daemonRuntimeReady = False}

installDaemonSignalHandlers :: (DaemonSignal -> IO ()) -> IO InstalledDaemonSignalHandlers
installDaemonSignalHandlers handleSignal = do
  _ <- installHandler sigHUP (Catch (handleSignal DaemonSIGHUP)) Nothing
  _ <- installHandler sigTERM (Catch (handleSignal DaemonSIGTERM)) Nothing
  _ <- installHandler sigINT (Catch (handleSignal DaemonSIGINT)) Nothing
  pure InstalledDaemonSignalHandlers
