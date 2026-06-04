module Daemon.Cluster.EdgePort where

import Control.Exception (SomeException, try)
import Data.Char (isDigit)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO
import qualified Data.Text.Read as Text.Read
import Daemon.Cluster.Types

data EdgePortRecord = EdgePortRecord
  { edgePortRecordPulsarPort :: !Int,
    edgePortRecordPulsarAdminPort :: !Int,
    edgePortRecordMinIOPort :: !Int
  }
  deriving stock (Eq, Show)

data EdgePortConfig = EdgePortConfig
  { edgePortStart :: !Int,
    edgePortRecordPath :: !FilePath
  }
  deriving stock (Eq, Show)

data EdgePortError
  = NoAvailableEdgePort !Int !Int
  | EdgePortRecordMissing !FilePath
  | EdgePortRecordInvalid !FilePath !Text
  deriving stock (Eq, Show)

defaultEdgePortConfig :: ClusterPaths -> EdgePortConfig
defaultEdgePortConfig paths =
  EdgePortConfig
    { edgePortStart = 9090,
      edgePortRecordPath = clusterEdgePortPath paths
    }

chooseEdgePort :: [Int] -> EdgePortConfig -> Either EdgePortError Int
chooseEdgePort unavailable config =
  choose (edgePortStart config)
  where
    maxPort = 65535
    choose port
      | port > maxPort = Left (NoAvailableEdgePort (edgePortStart config) maxPort)
      | port `elem` unavailable = choose (port + 1)
      | otherwise = Right port

edgePortDiscoveryPlan :: EdgePortConfig -> [ClusterAction]
edgePortDiscoveryPlan config =
  [ clusterAction
      "edge-port-discovery"
      "Choose and persist the edge port used by host-native Apple workers."
      (DiscoverEdgePort (edgePortStart config) (edgePortRecordPath config))
  ]

edgePortPersistencePlan :: EdgePortConfig -> Int -> [ClusterAction]
edgePortPersistencePlan config port =
  [ clusterAction
      "edge-port-persist"
      "Persist the selected edge port."
      (PersistEdgePort port (edgePortRecordPath config))
  ]

edgePortForwardPlan :: EdgePortConfig -> [ClusterAction]
edgePortForwardPlan config =
  [ clusterAction
      "edge-port-forward"
      "Expose Pulsar and MinIO to the Apple host worker through local port-forwards."
      (StartEdgePortForwards (edgePortRecordPath config))
  ]

edgePortStopPlan :: EdgePortConfig -> [ClusterAction]
edgePortStopPlan config =
  [ clusterAction
      "edge-port-stop"
      "Stop local edge port-forwards."
      (StopEdgePortForwards (edgePortRecordPath config))
  ]

renderEdgePortRecord :: Int -> Text
renderEdgePortRecord port =
  Text.unlines
    [ "{",
      "  \"port\": " <> textShow port <> ",",
      "  \"pulsarPort\": " <> textShow (edgePulsarPort port) <> ",",
      "  \"pulsarAdminPort\": " <> textShow (edgePulsarAdminPort port) <> ",",
      "  \"minioPort\": " <> textShow (edgeMinIOPort port),
      "}"
    ]

edgePulsarPort :: Int -> Int
edgePulsarPort = id

edgePulsarAdminPort :: Int -> Int
edgePulsarAdminPort = (+ 1)

edgeMinIOPort :: Int -> Int
edgeMinIOPort = (+ 2)

edgePortPidPath :: FilePath -> FilePath
edgePortPidPath path =
  path <> ".pids"

readEdgePortRecord :: FilePath -> IO (Either EdgePortError EdgePortRecord)
readEdgePortRecord path = do
  loaded <- readFileIfPresent path
  pure case loaded of
    Nothing -> Left (EdgePortRecordMissing path)
    Just text -> parseEdgePortRecord path text

parseEdgePortRecord :: FilePath -> Text -> Either EdgePortError EdgePortRecord
parseEdgePortRecord path text =
  case lookupJsonInt "port" text of
    Nothing ->
      Left (EdgePortRecordInvalid path text)
    Just base ->
      Right
        EdgePortRecord
          { edgePortRecordPulsarPort = fromMaybe (edgePulsarPort base) (lookupJsonInt "pulsarPort" text),
            edgePortRecordPulsarAdminPort = fromMaybe (edgePulsarAdminPort base) (lookupJsonInt "pulsarAdminPort" text),
            edgePortRecordMinIOPort = fromMaybe (edgeMinIOPort base) (lookupJsonInt "minioPort" text)
          }

readFileIfPresent :: FilePath -> IO (Maybe Text)
readFileIfPresent path = do
  result <- try (Text.IO.readFile path) :: IO (Either SomeException Text)
  pure case result of
    Left _ -> Nothing
    Right text -> Just text

lookupJsonInt :: Text -> Text -> Maybe Int
lookupJsonInt key text =
  firstJust (parseLine <$> Text.lines text)
  where
    parseLine line
      | ("\"" <> key <> "\"") `Text.isInfixOf` line =
          case Text.breakOn ":" line of
            (_, rest) ->
              case Text.Read.decimal (Text.dropWhile (not . isDigit) rest) of
                Right (value, _) -> Just value
                Left _ -> Nothing
      | otherwise = Nothing

firstJust :: [Maybe a] -> Maybe a
firstJust values =
  case values of
    [] -> Nothing
    Just value : _ -> Just value
    Nothing : remaining -> firstJust remaining
