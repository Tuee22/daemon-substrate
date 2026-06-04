module Daemon.Lifecycle
  ( DaemonLifecycleActions (..),
    DaemonRuntime (..),
    LifecycleError (..),
    LifecyclePhase (..),
    LifecycleResult (..),
    RunServiceError (..),
    RunServiceOptions (..),
    ServiceBootConfig (..),
    ServiceRole (..),
    lifecyclePhaseOrder,
    noopLifecycleActions,
    parseRunServiceArgs,
    runDaemonLifecycle,
    runService,
    runServiceWithArgs,
  )
where

import Data.Text (Text)
import qualified Data.Text as Text
import Dhall (FromDhall)
import Daemon.Config.BootConfig
  ( BootConfig,
    BootConfigError,
    OrchestratorRole,
    WorkerRole,
    decodeOrchestratorBootConfigFile,
    decodeWorkerBootConfigFile,
  )
import Daemon.Config.LifecyclePolicy
  ( LifecyclePolicy,
    LifecyclePolicyError,
    decodeLifecyclePolicyFile,
  )
import Daemon.Config.LiveConfig
  ( LiveConfig,
    LiveConfigError,
    decodeLiveConfigFile,
  )
import System.Environment (getArgs)
import System.Exit (die)

data LifecyclePhase
  = Load
  | Prereq
  | Acquire
  | Ready
  | Serve
  | Drain
  | Exit
  deriving stock (Eq, Ord, Show, Enum, Bounded)

lifecyclePhaseOrder :: [LifecyclePhase]
lifecyclePhaseOrder =
  [Load, Prereq, Acquire, Ready, Serve, Drain, Exit]

data DaemonRuntime r app clients subscriptions = DaemonRuntime
  { daemonRuntimePhase :: !LifecyclePhase,
    daemonRuntimeBootConfig :: !(BootConfig r app),
    daemonRuntimeLiveConfig :: !LiveConfig,
    daemonRuntimeLifecyclePolicy :: !LifecyclePolicy,
    daemonRuntimeClients :: !clients,
    daemonRuntimeSubscriptions :: !subscriptions,
    daemonRuntimeReady :: !Bool,
    daemonRuntimeLastError :: !(Maybe LifecycleError)
  }
  deriving stock (Eq, Show)

data LifecycleError = LifecycleError
  { lifecycleErrorPhase :: !LifecyclePhase,
    lifecycleErrorMessage :: !Text
  }
  deriving stock (Eq, Show)

data LifecycleResult runtime
  = LifecycleCompleted !runtime
  | LifecycleFailed !runtime !LifecycleError
  deriving stock (Eq, Show)

data ServiceRole
  = ServiceWorker
  | ServiceOrchestrator
  deriving stock (Eq, Ord, Show)

data RunServiceOptions = RunServiceOptions
  { runServiceRole :: !ServiceRole,
    runServiceBootConfigPath :: !FilePath,
    runServiceLiveConfigPath :: !FilePath,
    runServiceLifecyclePolicyPath :: !FilePath
  }
  deriving stock (Eq, Show)

data ServiceBootConfig app
  = ServiceWorkerBootConfig !(BootConfig WorkerRole app)
  | ServiceOrchestratorBootConfig !(BootConfig OrchestratorRole app)
  deriving stock (Eq, Show)

data RunServiceError
  = RunServiceUsageError !Text
  | RunServiceBootConfigError !BootConfigError
  | RunServiceLiveConfigError !LiveConfigError
  | RunServiceLifecyclePolicyError !LifecyclePolicyError
  | RunServiceLifecycleError !LifecycleError
  deriving stock (Eq, Show)

data DaemonLifecycleActions m r app clients subscriptions = DaemonLifecycleActions
  { lifecycleLoad ::
      DaemonRuntime r app clients subscriptions ->
      m (Either Text (DaemonRuntime r app clients subscriptions)),
    lifecyclePrereq ::
      DaemonRuntime r app clients subscriptions ->
      m (Either Text (DaemonRuntime r app clients subscriptions)),
    lifecycleAcquire ::
      DaemonRuntime r app clients subscriptions ->
      m (Either Text (DaemonRuntime r app clients subscriptions)),
    lifecycleReady ::
      DaemonRuntime r app clients subscriptions ->
      m (Either Text (DaemonRuntime r app clients subscriptions)),
    lifecycleServe ::
      DaemonRuntime r app clients subscriptions ->
      m (Either Text (DaemonRuntime r app clients subscriptions)),
    lifecycleDrain ::
      DaemonRuntime r app clients subscriptions ->
      m (Either Text (DaemonRuntime r app clients subscriptions)),
    lifecycleExit ::
      DaemonRuntime r app clients subscriptions ->
      m (Either Text (DaemonRuntime r app clients subscriptions))
  }

noopLifecycleActions ::
  (Applicative m) =>
  DaemonLifecycleActions m r app clients subscriptions
noopLifecycleActions =
  DaemonLifecycleActions
    { lifecycleLoad = pureRight,
      lifecyclePrereq = pureRight,
      lifecycleAcquire = pureRight,
      lifecycleReady = pureRight,
      lifecycleServe = pureRight,
      lifecycleDrain = pureRight,
      lifecycleExit = pureRight
    }
  where
    pureRight runtime =
      pure (Right runtime)

runDaemonLifecycle ::
  (Monad m) =>
  DaemonLifecycleActions m r app clients subscriptions ->
  DaemonRuntime r app clients subscriptions ->
  m (LifecycleResult (DaemonRuntime r app clients subscriptions))
runDaemonLifecycle actions initial =
  runPhases lifecyclePhaseOrder initial
  where
    runPhases [] runtime =
      pure (LifecycleCompleted runtime)
    runPhases (phase : remaining) runtime = do
      let entered = enterLifecyclePhase phase runtime
      result <- lifecycleAction phase actions entered
      case result of
        Right next ->
          runPhases remaining (afterLifecyclePhase phase next)
        Left message -> do
          let err =
                LifecycleError
                  { lifecycleErrorPhase = phase,
                    lifecycleErrorMessage = message
                  }
              failed =
                entered
                  { daemonRuntimeLastError = Just err,
                    daemonRuntimeReady = False
                  }
          pure (LifecycleFailed failed err)

lifecycleAction ::
  LifecyclePhase ->
  DaemonLifecycleActions m r app clients subscriptions ->
  DaemonRuntime r app clients subscriptions ->
  m (Either Text (DaemonRuntime r app clients subscriptions))
lifecycleAction phase actions =
  case phase of
    Load -> lifecycleLoad actions
    Prereq -> lifecyclePrereq actions
    Acquire -> lifecycleAcquire actions
    Ready -> lifecycleReady actions
    Serve -> lifecycleServe actions
    Drain -> lifecycleDrain actions
    Exit -> lifecycleExit actions

enterLifecyclePhase ::
  LifecyclePhase ->
  DaemonRuntime r app clients subscriptions ->
  DaemonRuntime r app clients subscriptions
enterLifecyclePhase phase runtime =
  runtime
    { daemonRuntimePhase = phase,
      daemonRuntimeReady = phase == Ready || phase == Serve
    }

afterLifecyclePhase ::
  LifecyclePhase ->
  DaemonRuntime r app clients subscriptions ->
  DaemonRuntime r app clients subscriptions
afterLifecyclePhase phase runtime =
  runtime
    { daemonRuntimePhase = phase,
      daemonRuntimeReady = phase == Ready || phase == Serve
    }

runService :: (FromDhall app) => (ServiceBootConfig app -> LiveConfig -> IO ()) -> IO ()
runService callback = do
  args <- getArgs
  result <- runServiceWithArgs args callback
  case result of
    Right () ->
      pure ()
    Left err ->
      die (Text.unpack (renderRunServiceError err))

runServiceWithArgs ::
  (FromDhall app) =>
  [String] ->
  (ServiceBootConfig app -> LiveConfig -> IO ()) ->
  IO (Either RunServiceError ())
runServiceWithArgs args callback =
  case parseRunServiceArgs args of
    Left err ->
      pure (Left err)
    Right options ->
      runServiceWithOptions options callback

parseRunServiceArgs :: [String] -> Either RunServiceError RunServiceOptions
parseRunServiceArgs args =
  buildOptions Nothing Nothing Nothing Nothing args
  where
    buildOptions role boot live lifecycle [] =
      RunServiceOptions
        <$> maybe (Left (RunServiceUsageError "missing --role")) Right role
        <*> maybe (Left (RunServiceUsageError "missing --boot-config")) Right boot
        <*> maybe (Left (RunServiceUsageError "missing --live-config")) Right live
        <*> maybe (Left (RunServiceUsageError "missing --lifecycle-policy")) Right lifecycle
    buildOptions _ boot live lifecycle ("--role" : value : remaining) =
      case parseRole value of
        Left err -> Left err
        Right role -> buildOptions (Just role) boot live lifecycle remaining
    buildOptions role _ live lifecycle ("--boot-config" : value : remaining) =
      buildOptions role (Just value) live lifecycle remaining
    buildOptions role boot _ lifecycle ("--live-config" : value : remaining) =
      buildOptions role boot (Just value) lifecycle remaining
    buildOptions role boot live _ ("--lifecycle-policy" : value : remaining) =
      buildOptions role boot live (Just value) remaining
    buildOptions _ _ _ _ (flag : _) =
      Left (RunServiceUsageError ("unknown or incomplete argument: " <> Text.pack flag))

parseRole :: String -> Either RunServiceError ServiceRole
parseRole value =
  case value of
    "worker" -> Right ServiceWorker
    "orchestrator" -> Right ServiceOrchestrator
    _ -> Left (RunServiceUsageError ("unknown role: " <> Text.pack value))

runServiceWithOptions ::
  (FromDhall app) =>
  RunServiceOptions ->
  (ServiceBootConfig app -> LiveConfig -> IO ()) ->
  IO (Either RunServiceError ())
runServiceWithOptions options callback = do
  live <- decodeLiveConfigFile (runServiceLiveConfigPath options)
  lifecyclePolicy <- decodeLifecyclePolicyFile (runServiceLifecyclePolicyPath options)
  case (live, lifecyclePolicy) of
    (Left err, _) ->
      pure (Left (RunServiceLiveConfigError err))
    (_, Left err) ->
      pure (Left (RunServiceLifecyclePolicyError err))
    (Right liveConfig, Right policy) ->
      case runServiceRole options of
        ServiceWorker -> do
          boot <- decodeWorkerBootConfigFile (runServiceBootConfigPath options)
          case boot of
            Left err -> pure (Left (RunServiceBootConfigError err))
            Right bootConfig ->
              runLifecycleAndCallback
                (ServiceWorkerBootConfig bootConfig)
                bootConfig
                liveConfig
                policy
                callback
        ServiceOrchestrator -> do
          boot <- decodeOrchestratorBootConfigFile (runServiceBootConfigPath options)
          case boot of
            Left err -> pure (Left (RunServiceBootConfigError err))
            Right bootConfig ->
              runLifecycleAndCallback
                (ServiceOrchestratorBootConfig bootConfig)
                bootConfig
                liveConfig
                policy
                callback

runLifecycleAndCallback ::
  ServiceBootConfig app ->
  BootConfig r app ->
  LiveConfig ->
  LifecyclePolicy ->
  (ServiceBootConfig app -> LiveConfig -> IO ()) ->
  IO (Either RunServiceError ())
runLifecycleAndCallback serviceBoot boot live policy callback = do
  let initial =
        DaemonRuntime
          { daemonRuntimePhase = Load,
            daemonRuntimeBootConfig = boot,
            daemonRuntimeLiveConfig = live,
            daemonRuntimeLifecyclePolicy = policy,
            daemonRuntimeClients = (),
            daemonRuntimeSubscriptions = (),
            daemonRuntimeReady = False,
            daemonRuntimeLastError = Nothing
          }
      actions =
        noopLifecycleActions
          { lifecycleServe = \runtime -> do
              callback serviceBoot live
              pure (Right runtime)
          }
  result <- runDaemonLifecycle actions initial
  pure case result of
    LifecycleCompleted _ -> Right ()
    LifecycleFailed _ err -> Left (RunServiceLifecycleError err)

renderRunServiceError :: RunServiceError -> Text
renderRunServiceError err =
  case err of
    RunServiceUsageError message -> message
    RunServiceBootConfigError detail -> "BootConfig decode failed: " <> Text.pack (show detail)
    RunServiceLiveConfigError detail -> "LiveConfig decode failed: " <> Text.pack (show detail)
    RunServiceLifecyclePolicyError detail -> "LifecyclePolicy decode failed: " <> Text.pack (show detail)
    RunServiceLifecycleError detail -> "Lifecycle failed: " <> Text.pack (show detail)
