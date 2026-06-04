module Daemon.Proto.Workflow
  ( WorkflowPublishGuardError (..),
    validateWorkflowPayloadSize,
    module Proto.DaemonSubstrate.Workflow,
    module Proto.DaemonSubstrate.Workflow_Fields,
  )
where

import qualified Data.ByteString as ByteString
import Lens.Family2 ((^.))
import Numeric.Natural (Natural)
import Proto.DaemonSubstrate.Workflow
import Proto.DaemonSubstrate.Workflow_Fields

data WorkflowPublishGuardError
  = InlinePayloadTooLarge
      { inlinePayloadSize :: !Natural,
        inlinePayloadMax :: !Natural
      }
  deriving stock (Eq, Show)

validateWorkflowPayloadSize ::
  Natural ->
  WorkflowEvent ->
  Either WorkflowPublishGuardError ()
validateWorkflowPayloadSize maxSize event =
  case event ^. maybe'inlineBytes of
    Just payload
      | payloadSize > maxSize ->
          Left
            InlinePayloadTooLarge
              { inlinePayloadSize = payloadSize,
                inlinePayloadMax = maxSize
              }
      | otherwise ->
          Right ()
      where
        payloadSize = fromIntegral (ByteString.length payload)
    Nothing ->
      Right ()
