module Daemon.Cluster.Runner where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Daemon.Cluster.EdgePort
import Daemon.Cluster.Types
import Daemon.Harbor
import Daemon.Kubectl
import Daemon.Sub
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory (createDirectoryIfMissing, findExecutable, makeAbsolute)
import System.Exit (ExitCode (ExitFailure))
import System.FilePath (takeDirectory)
import System.IO (hClose)
import System.Info qualified as System
import System.Posix.Signals (sigTERM, signalProcess)
import System.Process (CreateProcess (new_session, std_err, std_in, std_out), ProcessHandle, StdStream (CreatePipe, NoStream, UseHandle), createProcess, getPid, getProcessExitCode, proc)
import Text.Read qualified as Read

data ClusterActionResult = ClusterActionResult
    { clusterActionResultName :: !Text
    , clusterActionResultChanged :: !Bool
    , clusterActionResultDetail :: !Text
    }
    deriving stock (Show)

data ClusterRunnerError
    = ClusterExecutableNotFound !ClusterTool
    | ClusterSubprocessError !Text !SubprocessError
    | ClusterActionFailed !Text !ExitCode !Text !Text
    | ClusterUnsupportedOperation !Text !ClusterOperation
    | ClusterEdgePortSelectionFailed !EdgePortError
    deriving stock (Show)

data PortForwardProcess = PortForwardProcess
    { portForwardKubectlPid :: !Int
    , portForwardStdinPid :: !Int
    }
    deriving stock (Show)

runClusterPlan :: ClusterPaths -> ClusterPlan -> IO (Either ClusterRunnerError [ClusterActionResult])
runClusterPlan paths plan =
    runClusterPlanWithProgress paths plan (\_ -> pure ())

runClusterPlanWithProgress ::
    ClusterPaths ->
    ClusterPlan ->
    (Text -> IO ()) ->
    IO (Either ClusterRunnerError [ClusterActionResult])
runClusterPlanWithProgress paths plan reportAction =
    runActions [] (clusterPlanActions plan)
  where
    runActions completed [] =
        pure (Right (reverse completed))
    runActions completed (action : remaining) = do
        reportAction (clusterActionName action)
        result <- runClusterAction paths (clusterPlanCohort plan) action
        case result of
            Left err -> pure (Left err)
            Right ok -> runActions (ok : completed) remaining

runClusterAction :: ClusterPaths -> ClusterCohort -> ClusterAction -> IO (Either ClusterRunnerError ClusterActionResult)
runClusterAction paths cohort action =
    case clusterActionOperation action of
        InvokeClusterTool invocation ->
            runInvocation paths cohort (clusterActionName action) invocation
        ApplyKubernetesResource resource ->
            runKubectlInput
                paths
                (clusterActionName action)
                ["apply", "-f", "-"]
                (kubernetesResourceBody resource)
        WaitForKubernetesResource resource ->
            runKubectlInput
                paths
                (clusterActionName action)
                ["rollout", "status", Text.unpack (unResourceName resource), "--timeout=120s"]
                mempty
        DiscoverEdgePort start path -> do
            let config =
                    EdgePortConfig
                        { edgePortStart = start
                        , edgePortRecordPath = path
                        }
            case chooseEdgePort [] config of
                Left err -> pure (Left (ClusterEdgePortSelectionFailed err))
                Right port -> do
                    persisted <- persistEdgePort (clusterActionName action) port path
                    pure case persisted of
                        Left err -> Left err
                        Right _ ->
                            Right
                                ClusterActionResult
                                    { clusterActionResultName = clusterActionName action
                                    , clusterActionResultChanged = True
                                    , clusterActionResultDetail =
                                        "selected and persisted edge port " <> Text.pack (show port)
                                    }
        PersistEdgePort port path ->
            persistEdgePort (clusterActionName action) port path
        StartEdgePortForwards path ->
            startEdgePortForwards paths (clusterActionName action) path
        StopEdgePortForwards path ->
            stopEdgePortForwards (clusterActionName action) path
        ConnectCurrentContainerToDockerNetwork networkName ->
            connectCurrentContainerToDockerNetwork (clusterActionName action) networkName
        PublishHarborImage imageRef ->
            buildAndLoadHarnessImage paths cohort (clusterActionName action) imageRef
        PulsarAdminOperation operation ->
            runPulsarAdminOperation paths (clusterActionName action) operation
        MinIOAdminOperation operation ->
            runMinIOAdminOperation paths (clusterActionName action) operation

runInvocation :: ClusterPaths -> ClusterCohort -> Text -> ClusterInvocation -> IO (Either ClusterRunnerError ClusterActionResult)
runInvocation paths cohort actionName invocation = do
    input <- invocationInputBytes paths cohort invocation
    let runOnce =
            runTool
                actionName
                (clusterInvocationTool invocation)
                (decoratedInvocationArguments paths invocation)
                input
    if actionName == "kind-wait-ready"
        then runToolWithRetries 60 2000000 runOnce
        else runOnce

runToolWithRetries ::
    Int ->
    Int ->
    IO (Either ClusterRunnerError ClusterActionResult) ->
    IO (Either ClusterRunnerError ClusterActionResult)
runToolWithRetries attempts delayMicros action =
    go attempts
  where
    go remaining = do
        result <- action
        case result of
            Right _ ->
                pure result
            Left (ClusterExecutableNotFound _) ->
                pure result
            Left _
                | remaining > 1 -> do
                    threadDelay delayMicros
                    go (remaining - 1)
            Left _ ->
                pure result

connectCurrentContainerToDockerNetwork :: Text -> Text -> IO (Either ClusterRunnerError ClusterActionResult)
connectCurrentContainerToDockerNetwork actionName networkName = do
    currentContainer <- currentContainerName
    case currentContainer of
        Nothing ->
            pure (Left (ClusterActionFailed actionName (ExitFailure 1) "" "could not read current container hostname from /etc/hostname"))
        Just containerName ->
            runTool
                actionName
                DockerTool
                ["network", "connect", Text.unpack networkName, containerName]
                mempty

currentContainerName :: IO (Maybe String)
currentContainerName = do
    loaded <- try (ByteString.Char8.readFile "/etc/hostname") :: IO (Either SomeException ByteString.Char8.ByteString)
    pure case loaded of
        Left _ -> Nothing
        Right bytes ->
            case ByteString.Char8.words bytes of
                name : _ -> Just (ByteString.Char8.unpack name)
                [] -> Nothing

invocationInputBytes :: ClusterPaths -> ClusterCohort -> ClusterInvocation -> IO ByteString.Char8.ByteString
invocationInputBytes paths cohort invocation =
    case (clusterInvocationTool invocation, clusterInvocationArguments invocation, clusterInvocationInput invocation) of
        (KindTool, "create" : _, Just input) -> do
            createDirectoryIfMissing True (clusterDataDir paths <> "/kind/" <> Text.unpack (clusterCohortName cohort) <> "/daemon-substrate")
            textBytes <$> absolutizeKindHostPaths input
        (_, _, input) ->
            pure (maybe mempty textBytes input)

absolutizeKindHostPaths :: Text -> IO Text
absolutizeKindHostPaths input =
    Text.unlines <$> traverse absolutizeLine (Text.lines input)
  where
    absolutizeLine line =
        case Text.stripPrefix "- hostPath: " (Text.stripStart line) of
            Just rawPath
                | not (Text.isPrefixOf "/" rawPath) -> do
                    absolute <- makeAbsolute (Text.unpack rawPath)
                    pure (Text.takeWhile (== ' ') line <> "- hostPath: " <> Text.pack absolute)
            _ -> pure line

decoratedInvocationArguments :: ClusterPaths -> ClusterInvocation -> [String]
decoratedInvocationArguments paths invocation =
    case clusterInvocationTool invocation of
        HelmTool
            | take 1 args /= ["dependency"] ->
                args <> ["--kubeconfig", clusterKubeconfigPath paths]
        _ -> args
  where
    args = Text.unpack <$> clusterInvocationArguments invocation

runTool :: Text -> ClusterTool -> [String] -> ByteString.Char8.ByteString -> IO (Either ClusterRunnerError ClusterActionResult)
runTool actionName tool args input = do
    resolved <- findExecutable (Text.unpack (clusterToolName tool))
    case resolved of
        Nothing ->
            pure (Left (ClusterExecutableNotFound tool))
        Just executable -> do
            result <-
                runSubprocess
                    Subprocess
                        { subprocessExecutable = executable
                        , subprocessArguments = args
                        , subprocessInput = input
                        }
            pure (subprocessResultToAction actionName result)

runKubectlInput :: ClusterPaths -> Text -> [String] -> Text -> IO (Either ClusterRunnerError ClusterActionResult)
runKubectlInput paths actionName args input = do
    resolved <- findExecutable "kubectl"
    case resolved of
        Nothing ->
            pure (Left (ClusterExecutableNotFound KubectlTool))
        Just kubectl -> do
            result <-
                runSubprocess
                    Subprocess
                        { subprocessExecutable = kubectl
                        , subprocessArguments = ["--kubeconfig", clusterKubeconfigPath paths] <> args
                        , subprocessInput = textBytes input
                        }
            pure (subprocessResultToAction actionName result)

buildAndLoadHarnessImage ::
    ClusterPaths ->
    ClusterCohort ->
    Text ->
    ImageRef ->
    IO (Either ClusterRunnerError ClusterActionResult)
buildAndLoadHarnessImage _paths cohort actionName imageRef = do
    let image = Text.unpack (unImageRef imageRef)
        baseImage = hostbootstrapBaseImageRef
        clusterName = "daemon-substrate-" <> Text.unpack (clusterCohortName cohort)
    built <-
        runStreamingTool
            (actionName <> "-docker-build")
            DockerTool
            [ "build"
            , "--build-arg"
            , "BASE_IMAGE=" <> baseImage
            , "--tag"
            , image
            , "--file"
            , "docker/linux-substrate.Dockerfile"
            , "."
            ]
            mempty
    case built of
        Left err -> pure (Left err)
        Right _ ->
            runStreamingTool
                actionName
                KindTool
                ["load", "docker-image", image, "--name", clusterName]
                mempty

runStreamingTool :: Text -> ClusterTool -> [String] -> ByteString.Char8.ByteString -> IO (Either ClusterRunnerError ClusterActionResult)
runStreamingTool actionName tool args input = do
    resolved <- findExecutable (Text.unpack (clusterToolName tool))
    case resolved of
        Nothing ->
            pure (Left (ClusterExecutableNotFound tool))
        Just executable -> do
            result <-
                runSubprocessStreaming
                    Subprocess
                        { subprocessExecutable = executable
                        , subprocessArguments = args
                        , subprocessInput = input
                        }
            pure (subprocessResultToAction actionName result)

hostbootstrapBaseImageRef :: String
hostbootstrapBaseImageRef =
    "docker.io/tuee22/hostbootstrap:basecontainer-cpu-" <> dockerArch

dockerArch :: String
dockerArch =
    case System.arch of
        "x86_64" -> "amd64"
        "amd64" -> "amd64"
        "aarch64" -> "arm64"
        "arm64" -> "arm64"
        other -> other

runPulsarAdminOperation :: ClusterPaths -> Text -> Text -> IO (Either ClusterRunnerError ClusterActionResult)
runPulsarAdminOperation paths actionName operation =
    case Text.words operation of
        ["create", "tenant", tenant] ->
            runPulsarAdminScript paths actionName ("bin/pulsar-admin tenants create " <> shellQuote tenant <> " || bin/pulsar-admin tenants get " <> shellQuote tenant)
        ["create", "namespace", namespaceName] ->
            let tenant = Text.takeWhile (/= '/') namespaceName
             in runPulsarAdminScript
                    paths
                    actionName
                    ( "bin/pulsar-admin namespaces create "
                        <> shellQuote namespaceName
                        <> " || bin/pulsar-admin namespaces list "
                        <> shellQuote tenant
                        <> " | grep -Fx "
                        <> shellQuote namespaceName
                        <> " >/dev/null"
                    )
        ["create", "topic", topicName] ->
            let topic = pulsarPersistentTopic topicName
             in runPulsarAdminScript paths actionName ("bin/pulsar-admin topics create " <> shellQuote topic <> " || bin/pulsar-admin topics stats " <> shellQuote topic <> " >/dev/null")
        _ ->
            pure (Left (ClusterUnsupportedOperation actionName (PulsarAdminOperation operation)))

runPulsarAdminScript :: ClusterPaths -> Text -> Text -> IO (Either ClusterRunnerError ClusterActionResult)
runPulsarAdminScript paths actionName script =
    runKubectlInput
        paths
        actionName
        [ "exec"
        , "statefulset/daemon-substrate-test-pulsar"
        , "--"
        , "/bin/sh"
        , "-c"
        , Text.unpack script
        ]
        mempty

pulsarPersistentTopic :: Text -> Text
pulsarPersistentTopic topic
    | "persistent://" `Text.isPrefixOf` topic = topic
    | otherwise = "persistent://daemon-substrate-test/workflows/" <> topic

runMinIOAdminOperation :: ClusterPaths -> Text -> Text -> IO (Either ClusterRunnerError ClusterActionResult)
runMinIOAdminOperation paths actionName operation =
    case Text.words operation of
        ["create", "bucket", bucket] ->
            runMinIOAdminScript paths actionName ("mc mb --ignore-existing local/" <> shellQuote bucket)
        ["put", "object", objectPath] ->
            runMinIOAdminScript
                paths
                actionName
                ( Text.unwords
                    [ "printf %s"
                    , shellQuote "deterministic mock weight blob"
                    , "> /tmp/daemon-substrate-seed && mc cp /tmp/daemon-substrate-seed local/" <> shellQuote objectPath
                    ]
                )
        _ ->
            pure (Left (ClusterUnsupportedOperation actionName (MinIOAdminOperation operation)))

runMinIOAdminScript :: ClusterPaths -> Text -> Text -> IO (Either ClusterRunnerError ClusterActionResult)
runMinIOAdminScript paths actionName script =
    runKubectlInput
        paths
        actionName
        [ "exec"
        , "statefulset/daemon-substrate-test-minio"
        , "-c"
        , "mc"
        , "--"
        , "/bin/sh"
        , "-c"
        , Text.unpack ("mc alias set local http://localhost:9000 minioadmin minioadmin >/dev/null && " <> script)
        ]
        mempty

persistEdgePort :: Text -> Int -> FilePath -> IO (Either ClusterRunnerError ClusterActionResult)
persistEdgePort actionName port path = do
    createDirectoryIfMissing True (takeDirectory path)
    ByteString.Char8.writeFile path (textBytes (renderEdgePortRecord port))
    pure
        ( Right
            ClusterActionResult
                { clusterActionResultName = actionName
                , clusterActionResultChanged = True
                , clusterActionResultDetail = "persisted edge port " <> Text.pack (show port)
                }
        )

startEdgePortForwards :: ClusterPaths -> Text -> FilePath -> IO (Either ClusterRunnerError ClusterActionResult)
startEdgePortForwards paths actionName path = do
    _ <- stopEdgePortForwards actionName path
    record <- readEdgePortRecord path
    case record of
        Left err -> pure (Left (ClusterEdgePortSelectionFailed err))
        Right ports -> do
            pulsar <-
                startKubectlPortForward
                    paths
                    actionName
                    "statefulset/daemon-substrate-test-pulsar"
                    [ edgePortRecordPulsarPort ports
                    , edgePortRecordPulsarAdminPort ports
                    ]
                    [6650, 8080]
            case pulsar of
                Left err -> pure (Left err)
                Right pulsarProcess -> do
                    minio <-
                        startKubectlPortForward
                            paths
                            actionName
                            "statefulset/daemon-substrate-test-minio"
                            [edgePortRecordMinIOPort ports]
                            [9000]
                    case minio of
                        Left err -> do
                            terminatePortForward pulsarProcess
                            pure (Left err)
                        Right minioProcess -> do
                            createDirectoryIfMissing True (takeDirectory path)
                            ByteString.Char8.writeFile
                                (edgePortPidPath path)
                                ( textBytes
                                    ( Text.unlines
                                        [ "pulsar-stdin " <> Text.pack (show (portForwardStdinPid pulsarProcess))
                                        , "pulsar " <> Text.pack (show (portForwardKubectlPid pulsarProcess))
                                        , "minio-stdin " <> Text.pack (show (portForwardStdinPid minioProcess))
                                        , "minio " <> Text.pack (show (portForwardKubectlPid minioProcess))
                                        ]
                                    )
                                )
                            pure
                                ( Right
                                    ClusterActionResult
                                        { clusterActionResultName = actionName
                                        , clusterActionResultChanged = True
                                        , clusterActionResultDetail =
                                            "forwarding Pulsar "
                                                <> Text.pack (show (edgePortRecordPulsarPort ports))
                                                <> ", admin "
                                                <> Text.pack (show (edgePortRecordPulsarAdminPort ports))
                                                <> ", MinIO "
                                                <> Text.pack (show (edgePortRecordMinIOPort ports))
                                        }
                                )

startKubectlPortForward :: ClusterPaths -> Text -> String -> [Int] -> [Int] -> IO (Either ClusterRunnerError PortForwardProcess)
startKubectlPortForward paths actionName resource hostPorts targetPorts = do
    resolved <- findExecutable "kubectl"
    sleeper <- findExecutable "sleep"
    case (resolved, sleeper) of
        (Nothing, _) ->
            pure (Left (ClusterExecutableNotFound KubectlTool))
        (_, Nothing) ->
            pure (Left (ClusterActionFailed actionName (ExitFailure 1) "" "sleep executable unavailable for kubectl stdin guard"))
        (Just kubectl, Just sleepExecutable) -> do
            (_, Just inputHandle, _, inputProcess) <-
                createProcess
                    (proc sleepExecutable ["2147483647"])
                        { std_in = NoStream
                        , std_out = CreatePipe
                        , std_err = NoStream
                        , new_session = True
                        }
            let args =
                    [ "--kubeconfig"
                    , clusterKubeconfigPath paths
                    , "port-forward"
                    , "--address"
                    , "127.0.0.1"
                    , resource
                    ]
                        <> zipWith (\host target -> show host <> ":" <> show target) hostPorts targetPorts
            (_, _, _, handle) <-
                createProcess
                    (proc kubectl args)
                        { std_in = UseHandle inputHandle
                        , std_out = NoStream
                        , std_err = NoStream
                        , new_session = True
                        }
            hClose inputHandle
            threadDelay 1000000
            exited <- getProcessExitCode handle
            case exited of
                Just code -> do
                    terminateProcessHandle inputProcess
                    pure (Left (ClusterActionFailed actionName code "" "kubectl port-forward exited before becoming ready"))
                Nothing -> do
                    pid <- getPid handle
                    inputPid <- getPid inputProcess
                    case (pid, inputPid) of
                        (Nothing, _) -> do
                            terminateProcessHandle inputProcess
                            pure (Left (ClusterActionFailed actionName (ExitFailure 1) "" "kubectl port-forward pid unavailable"))
                        (_, Nothing) -> do
                            terminateProcessHandle handle
                            pure (Left (ClusterActionFailed actionName (ExitFailure 1) "" "kubectl stdin guard pid unavailable"))
                        (Just processId, Just guardProcessId) ->
                            pure
                                ( Right
                                    PortForwardProcess
                                        { portForwardKubectlPid = fromIntegral processId
                                        , portForwardStdinPid = fromIntegral guardProcessId
                                        }
                                )

stopEdgePortForwards :: Text -> FilePath -> IO (Either ClusterRunnerError ClusterActionResult)
stopEdgePortForwards actionName path = do
    pids <- readStoredPids (edgePortPidPath path)
    mapM_ terminateStoredPid pids
    pure
        ( Right
            ClusterActionResult
                { clusterActionResultName = actionName
                , clusterActionResultChanged = not (null pids)
                , clusterActionResultDetail =
                    if null pids
                        then "no edge port-forwards recorded"
                        else "stopped edge port-forwards"
                }
        )

readStoredPids :: FilePath -> IO [Int]
readStoredPids path = do
    loaded <- try (ByteString.Char8.readFile path) :: IO (Either SomeException ByteString.Char8.ByteString)
    pure case loaded of
        Left _ -> []
        Right bytes ->
            [ pid
            | line <- lines (ByteString.Char8.unpack bytes)
            , token <- take 1 (drop 1 (words line))
            , Just pid <- [Read.readMaybe token]
            ]

terminateStoredPid :: Int -> IO ()
terminateStoredPid pid = do
    _ <- try (signalProcess sigTERM (fromIntegral pid)) :: IO (Either SomeException ())
    pure ()

terminatePortForward :: PortForwardProcess -> IO ()
terminatePortForward process = do
    terminateStoredPid (portForwardKubectlPid process)
    terminateStoredPid (portForwardStdinPid process)

terminateProcessHandle :: ProcessHandle -> IO ()
terminateProcessHandle handle = do
    pid <- getPid handle
    case pid of
        Nothing -> pure ()
        Just processId -> terminateStoredPid (fromIntegral processId)

subprocessResultToAction ::
    Text ->
    Either SubprocessError SubprocessResult ->
    Either ClusterRunnerError ClusterActionResult
subprocessResultToAction actionName result =
    case result of
        Left err ->
            Left (ClusterSubprocessError actionName err)
        Right completed
            | subprocessSucceeded completed ->
                Right
                    ClusterActionResult
                        { clusterActionResultName = actionName
                        , clusterActionResultChanged = True
                        , clusterActionResultDetail = Text.pack (subprocessStdout completed)
                        }
            | kindClusterAlreadyExists actionName completed ->
                Right
                    ClusterActionResult
                        { clusterActionResultName = actionName
                        , clusterActionResultChanged = False
                        , clusterActionResultDetail = "kind cluster already exists"
                        }
            | dockerNetworkAlreadyConnected actionName completed ->
                Right
                    ClusterActionResult
                        { clusterActionResultName = actionName
                        , clusterActionResultChanged = False
                        , clusterActionResultDetail = "current container already attached to kind network"
                        }
            | otherwise ->
                Left
                    ( ClusterActionFailed
                        actionName
                        (subprocessExitCode completed)
                        (Text.pack (subprocessStdout completed))
                        (Text.pack (subprocessStderr completed))
                    )

renderClusterRunnerError :: ClusterRunnerError -> Text
renderClusterRunnerError err =
    case err of
        ClusterExecutableNotFound tool ->
            "cluster tool not found on PATH: " <> clusterToolName tool
        ClusterSubprocessError action detail ->
            "cluster action " <> action <> " could not start: " <> Text.pack (show detail)
        ClusterActionFailed action code stdout stderr ->
            Text.unlines
                [ "cluster action failed: " <> action
                , "exit: " <> Text.pack (show code)
                , "stdout:"
                , stdout
                , "stderr:"
                , stderr
                ]
        ClusterUnsupportedOperation action operation ->
            "cluster action "
                <> action
                <> " is still an abstract plan operation without a live interpreter: "
                <> Text.pack (show operation)
        ClusterEdgePortSelectionFailed detail ->
            "edge port selection failed: " <> Text.pack (show detail)

renderClusterActionResult :: ClusterActionResult -> Text
renderClusterActionResult result =
    clusterActionResultName result <> ": " <> clusterActionResultDetail result

textBytes :: Text -> ByteString.Char8.ByteString
textBytes = ByteString.Char8.pack . Text.unpack

kindClusterAlreadyExists :: Text -> SubprocessResult -> Bool
kindClusterAlreadyExists actionName completed =
    actionName == "kind-create"
        && "node(s) already exist for a cluster with the name" `Text.isInfixOf` Text.pack (subprocessStderr completed)

dockerNetworkAlreadyConnected :: Text -> SubprocessResult -> Bool
dockerNetworkAlreadyConnected actionName completed =
    actionName == "kind-network-connect"
        && ( "already exists in network" `Text.isInfixOf` stderrText
                || "already connected" `Text.isInfixOf` stderrText
           )
  where
    stderrText = Text.pack (subprocessStderr completed)

shellQuote :: Text -> Text
shellQuote value =
    "'" <> Text.replace "'" "'\"'\"'" value <> "'"
