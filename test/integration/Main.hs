module Main (main) where

import Control.Monad (unless, when)
import Data.List (isPrefixOf)
import System.Directory (doesFileExist, findExecutable)
import System.Exit (ExitCode (ExitSuccess), exitFailure)
import System.Process (readProcessWithExitCode)

data Cohort
    = AppleSilicon
    | LinuxCpu
    deriving stock (Eq, Show)

data IntegrationEnv = IntegrationEnv
    { integrationCohort :: !Cohort
    , integrationKubeconfig :: !FilePath
    , integrationEdgePortRecord :: !FilePath
    }
    deriving stock (Show)

main :: IO ()
main = do
    env <- discoverIntegrationEnv
    kubectlPath <- requireTool "kubectl"
    assertNodes kubectlPath env
    assertStatefulSets kubectlPath env
    assertDeployments kubectlPath env
    assertPods kubectlPath env
    assertPersistentVolumes kubectlPath env
    assertEdgePortRecord env
    putStrLn "daemon-substrate-integration: live cluster readiness passed"

discoverIntegrationEnv :: IO IntegrationEnv
discoverIntegrationEnv = do
    let candidates =
            [ IntegrationEnv
                { integrationCohort = LinuxCpu
                , integrationKubeconfig = "/workspace/.data/runtime/daemon-substrate.kubeconfig"
                , integrationEdgePortRecord = "/workspace/.data/runtime/edge-port.json"
                }
            , IntegrationEnv
                { integrationCohort = LinuxCpu
                , integrationKubeconfig = ".data/runtime/daemon-substrate.kubeconfig"
                , integrationEdgePortRecord = ".data/runtime/edge-port.json"
                }
            , IntegrationEnv
                { integrationCohort = AppleSilicon
                , integrationKubeconfig = ".build/daemon-substrate.kubeconfig"
                , integrationEdgePortRecord = ".build/edge-port.json"
                }
            ]
    existing <- filterM (doesFileExist . integrationKubeconfig) candidates
    case existing of
        env : _ -> pure env
        [] ->
            failIntegration
                "no repo-local kubeconfig found; run hostbootstrap cluster up before daemon-substrate-test test integration"

filterM :: (a -> IO Bool) -> [a] -> IO [a]
filterM predicate =
    foldr
        ( \value rest -> do
            include <- predicate value
            values <- rest
            pure (if include then value : values else values)
        )
        (pure [])

requireTool :: String -> IO FilePath
requireTool name = do
    found <- findExecutable name
    case found of
        Just path -> pure path
        Nothing -> failIntegration ("required executable not found on PATH: " <> name)

assertNodes :: FilePath -> IntegrationEnv -> IO ()
assertNodes kubectlPath env = do
    rows <- kubectlLines kubectlPath env ["get", "nodes", "--no-headers"]
    let expected =
            case integrationCohort env of
                AppleSilicon -> 2
                LinuxCpu -> 4
    expect ("expected " <> show expected <> " kind nodes, saw " <> show (length rows)) (length rows == expected)
    expect "every kind node is Ready" (all fieldTwoReady rows)

assertStatefulSets :: FilePath -> IntegrationEnv -> IO ()
assertStatefulSets kubectlPath env =
    mapM_
        ( \resource ->
            kubectlOk kubectlPath env ["rollout", "status", resource, "--timeout=30s"]
        )
        [ "statefulset/daemon-substrate-test-harbor"
        , "statefulset/daemon-substrate-test-pulsar"
        , "statefulset/daemon-substrate-test-minio"
        ]

assertDeployments :: FilePath -> IntegrationEnv -> IO ()
assertDeployments kubectlPath env = do
    kubectlOk kubectlPath env ["rollout", "status", "deployment/daemon-substrate-test-orchestrator", "--timeout=30s"]
    when (integrationCohort env == LinuxCpu) do
        kubectlOk kubectlPath env ["rollout", "status", "deployment/daemon-substrate-test-worker", "--timeout=30s"]

assertPods :: FilePath -> IntegrationEnv -> IO ()
assertPods kubectlPath env = do
    rows <- kubectlLines kubectlPath env ["get", "pods", "--no-headers"]
    assertReadyPodCount "daemon-substrate-test-harbor-" 1 rows
    assertReadyPodCount "daemon-substrate-test-pulsar-" 1 rows
    assertReadyPodCount "daemon-substrate-test-minio-" 1 rows
    assertReadyPodCount "daemon-substrate-test-orchestrator-" 2 rows
    case integrationCohort env of
        AppleSilicon ->
            assertReadyPodCount "daemon-substrate-test-worker-" 0 rows
        LinuxCpu ->
            assertReadyPodCount "daemon-substrate-test-worker-" 2 rows

assertPersistentVolumes :: FilePath -> IntegrationEnv -> IO ()
assertPersistentVolumes kubectlPath env = do
    rows <- kubectlLines kubectlPath env ["get", "pvc", "--no-headers"]
    mapM_
        (assertBoundPvc rows)
        [ "daemon-substrate-test-harbor-data"
        , "daemon-substrate-test-pulsar-data"
        , "daemon-substrate-test-minio-data"
        ]

assertEdgePortRecord :: IntegrationEnv -> IO ()
assertEdgePortRecord env = do
    exists <- doesFileExist (integrationEdgePortRecord env)
    expect ("edge-port record exists at " <> integrationEdgePortRecord env) exists
    body <- readFile (integrationEdgePortRecord env)
    mapM_
        ( \field ->
            expect ("edge-port record includes " <> field) (field `contains` body)
        )
        ["\"pulsarPort\"", "\"pulsarAdminPort\"", "\"minioPort\""]

kubectlLines :: FilePath -> IntegrationEnv -> [String] -> IO [String]
kubectlLines kubectlPath env args = do
    output <- runKubectl kubectlPath env args
    pure (filter (not . null) (lines output))

kubectlOk :: FilePath -> IntegrationEnv -> [String] -> IO ()
kubectlOk kubectlPath env args =
    runKubectl kubectlPath env args >> pure ()

runKubectl :: FilePath -> IntegrationEnv -> [String] -> IO String
runKubectl kubectlPath env args = do
    let fullArgs = ["--kubeconfig", integrationKubeconfig env] <> args
    (code, stdout, stderr) <- readProcessWithExitCode kubectlPath fullArgs ""
    case code of
        ExitSuccess -> pure stdout
        _ ->
            failIntegration
                ( "kubectl "
                    <> unwords fullArgs
                    <> " failed\nstdout:\n"
                    <> stdout
                    <> "\nstderr:\n"
                    <> stderr
                )

assertReadyPodCount :: String -> Int -> [String] -> IO ()
assertReadyPodCount prefix expected rows = do
    let matches = filter (hasNamePrefix prefix) rows
        ready = filter podReady matches
    expect
        (prefix <> " expected " <> show expected <> " Ready pods, saw " <> show (length ready))
        (length ready == expected)

assertBoundPvc :: [String] -> String -> IO ()
assertBoundPvc rows name =
    expect ("PVC is Bound: " <> name) (any isBound rows)
  where
    isBound row =
        case words row of
            pvcName : status : _ -> pvcName == name && status == "Bound"
            _ -> False

fieldTwoReady :: String -> Bool
fieldTwoReady row =
    case words row of
        _nodeName : status : _ -> status == "Ready"
        _ -> False

hasNamePrefix :: String -> String -> Bool
hasNamePrefix prefix row =
    case words row of
        podName : _ -> prefix `isPrefixOf` podName
        _ -> False

podReady :: String -> Bool
podReady row =
    case words row of
        _podName : ready : status : _ ->
            status == "Running" && readyFractionComplete ready
        _ -> False

readyFractionComplete :: String -> Bool
readyFractionComplete value =
    case break (== '/') value of
        (ready, '/' : total) -> ready == total
        _ -> False

contains :: String -> String -> Bool
contains needle haystack =
    any (needle `isPrefixOf`) (tails haystack)

tails :: [a] -> [[a]]
tails [] = [[]]
tails xs@(_ : rest) = xs : tails rest

expect :: String -> Bool -> IO ()
expect label condition =
    unless condition (failIntegration label)

failIntegration :: String -> IO a
failIntegration message = do
    putStrLn ("daemon-substrate-integration: " <> message)
    exitFailure
