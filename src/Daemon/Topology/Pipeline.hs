module Daemon.Topology.Pipeline where

import Data.Text (Text)
import Daemon.Topology.Types

newtype Pipeline = Pipeline
  { pipelineStages :: [Topology]
  }
  deriving stock (Eq, Show)

pipeline :: [Topology] -> Pipeline
pipeline =
  Pipeline

toTopology :: Text -> Pipeline -> Topology
toTopology name =
  mergeTopologies name . pipelineStages
