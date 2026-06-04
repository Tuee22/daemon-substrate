{-# LANGUAGE ScopedTypeVariables #-}

module Daemon.Config.BootConfig
  ( BootConfig (..),
    BootConfigError (..),
    OrchestratorRole,
    Role (..),
    WorkerRole,
    defaultMaxInlinePayloadBytes,
    decodeBootConfigFile,
    decodeBootConfigText,
    decodeOrchestratorBootConfigFile,
    decodeOrchestratorBootConfigText,
    decodeWorkerBootConfigFile,
    decodeWorkerBootConfigText,
  )
where

import Control.Exception (SomeException, displayException, try)
import Data.Text (Text)
import qualified Data.Text as Text
import Dhall (Decoder, FromDhall)
import qualified Dhall
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

data WorkerRole

data OrchestratorRole

data Role
  = Worker
  | Orchestrator
  deriving stock (Eq, Ord, Show, Generic)

instance FromDhall Role

data BootConfig r app = BootConfig
  { bootConfigRole :: !Role,
    bootConfigApp :: !app,
    bootConfigPulsarServiceUrl :: !Text,
    bootConfigPulsarAdminUrl :: !Text,
    bootConfigMinIOEndpoint :: !Text,
    bootConfigHarborEndpoint :: !(Maybe Text),
    bootConfigKubectlPath :: !FilePath,
    bootConfigMaxInlinePayloadBytes :: !Natural
  }
  deriving stock (Eq, Show)

data BootConfigError
  = BootConfigDhallError !Text
  | BootConfigRoleMismatch
      { bootConfigExpectedRole :: !Role,
        bootConfigActualRole :: !Role
      }
  deriving stock (Eq, Show)

defaultMaxInlinePayloadBytes :: Natural
defaultMaxInlinePayloadBytes = 1048576

decodeWorkerBootConfigText ::
  (FromDhall app) =>
  Text ->
  IO (Either BootConfigError (BootConfig WorkerRole app))
decodeWorkerBootConfigText =
  decodeBootConfigText Worker

decodeOrchestratorBootConfigText ::
  (FromDhall app) =>
  Text ->
  IO (Either BootConfigError (BootConfig OrchestratorRole app))
decodeOrchestratorBootConfigText =
  decodeBootConfigText Orchestrator

decodeWorkerBootConfigFile ::
  (FromDhall app) =>
  FilePath ->
  IO (Either BootConfigError (BootConfig WorkerRole app))
decodeWorkerBootConfigFile =
  decodeBootConfigFile Worker

decodeOrchestratorBootConfigFile ::
  (FromDhall app) =>
  FilePath ->
  IO (Either BootConfigError (BootConfig OrchestratorRole app))
decodeOrchestratorBootConfigFile =
  decodeBootConfigFile Orchestrator

decodeBootConfigText ::
  forall r app.
  (FromDhall app) =>
  Role ->
  Text ->
  IO (Either BootConfigError (BootConfig r app))
decodeBootConfigText expectedRole text = do
  full <- decodeWith rawBootConfigWithMaxDecoder text
  case full of
    Right raw ->
      pure (rawToBootConfig expectedRole raw)
    Left fullError -> do
      defaulted <- decodeWith rawBootConfigDefaultDecoder text
      pure case defaulted of
        Right raw ->
          rawToBootConfig expectedRole raw
        Left defaultError ->
          Left (combinedDhallError fullError defaultError)

decodeBootConfigFile ::
  forall r app.
  (FromDhall app) =>
  Role ->
  FilePath ->
  IO (Either BootConfigError (BootConfig r app))
decodeBootConfigFile expectedRole path = do
  full <- decodeFileWith rawBootConfigWithMaxDecoder path
  case full of
    Right raw ->
      pure (rawToBootConfig expectedRole raw)
    Left fullError -> do
      defaulted <- decodeFileWith rawBootConfigDefaultDecoder path
      pure case defaulted of
        Right raw ->
          rawToBootConfig expectedRole raw
        Left defaultError ->
          Left (combinedDhallError fullError defaultError)

data RawBootConfig app = RawBootConfig
  { rawBootConfigRole :: !Role,
    rawBootConfigApp :: !app,
    rawBootConfigPulsarServiceUrl :: !Text,
    rawBootConfigPulsarAdminUrl :: !Text,
    rawBootConfigMinIOEndpoint :: !Text,
    rawBootConfigHarborEndpoint :: !(Maybe Text),
    rawBootConfigKubectlPath :: !FilePath,
    rawBootConfigMaxInlinePayloadBytes :: !(Maybe Natural)
  }

rawBootConfigWithMaxDecoder :: (FromDhall app) => Decoder (RawBootConfig app)
rawBootConfigWithMaxDecoder =
  Dhall.record
    ( RawBootConfig
        <$> Dhall.field "role" Dhall.auto
        <*> Dhall.field "app" Dhall.auto
        <*> Dhall.field "pulsarServiceUrl" Dhall.auto
        <*> Dhall.field "pulsarAdminUrl" Dhall.auto
        <*> Dhall.field "minIOEndpoint" Dhall.auto
        <*> Dhall.field "harborEndpoint" Dhall.auto
        <*> Dhall.field "kubectlPath" Dhall.auto
        <*> (Just <$> Dhall.field "maxInlinePayloadBytes" Dhall.auto)
    )

rawBootConfigDefaultDecoder :: (FromDhall app) => Decoder (RawBootConfig app)
rawBootConfigDefaultDecoder =
  Dhall.record
    ( RawBootConfig
        <$> Dhall.field "role" Dhall.auto
        <*> Dhall.field "app" Dhall.auto
        <*> Dhall.field "pulsarServiceUrl" Dhall.auto
        <*> Dhall.field "pulsarAdminUrl" Dhall.auto
        <*> Dhall.field "minIOEndpoint" Dhall.auto
        <*> Dhall.field "harborEndpoint" Dhall.auto
        <*> Dhall.field "kubectlPath" Dhall.auto
        <*> pure Nothing
    )

rawToBootConfig ::
  Role ->
  RawBootConfig app ->
  Either BootConfigError (BootConfig r app)
rawToBootConfig expectedRole raw
  | rawBootConfigRole raw /= expectedRole =
      Left (BootConfigRoleMismatch expectedRole (rawBootConfigRole raw))
  | otherwise =
      Right
        BootConfig
          { bootConfigRole = rawBootConfigRole raw,
            bootConfigApp = rawBootConfigApp raw,
            bootConfigPulsarServiceUrl = rawBootConfigPulsarServiceUrl raw,
            bootConfigPulsarAdminUrl = rawBootConfigPulsarAdminUrl raw,
            bootConfigMinIOEndpoint = rawBootConfigMinIOEndpoint raw,
            bootConfigHarborEndpoint = rawBootConfigHarborEndpoint raw,
            bootConfigKubectlPath = rawBootConfigKubectlPath raw,
            bootConfigMaxInlinePayloadBytes =
              maybe
                defaultMaxInlinePayloadBytes
                id
                (rawBootConfigMaxInlinePayloadBytes raw)
          }

decodeWith :: Decoder a -> Text -> IO (Either SomeException a)
decodeWith decoder text =
  try (Dhall.input decoder text)

decodeFileWith :: Decoder a -> FilePath -> IO (Either SomeException a)
decodeFileWith decoder path =
  try (Dhall.inputFile decoder path)

combinedDhallError :: SomeException -> SomeException -> BootConfigError
combinedDhallError fullError defaultError =
  BootConfigDhallError
    ( Text.unlines
        [ "BootConfig Dhall decode failed with and without maxInlinePayloadBytes.",
          "With maxInlinePayloadBytes:",
          Text.pack (displayException fullError),
          "Without maxInlinePayloadBytes:",
          Text.pack (displayException defaultError)
        ]
    )
