module Daemon.Consumer where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.ByteString (ByteString)
import Data.List (sortOn)
import Data.Ord (Down (Down))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.MinIO
import Daemon.MinIO.Store (readBlob)
import Daemon.Pulsar
import qualified Daemon.Proto.Workflow as WorkflowProto
import qualified Daemon.Wire.Workflow as Workflow
import Data.ProtoLens.Encoding (decodeMessage)

data ConsumerPayload
  = ConsumerInline !ByteString
  | ConsumerObjectRef !Workflow.ObjectRef
  | ConsumerMaterialized !Workflow.ObjectRef !ByteString
  deriving stock (Eq, Show)

data ConsumerMessage = ConsumerMessage
  { consumerWorkflowEvent :: !Workflow.WorkflowEvent,
    consumerPayload :: !ConsumerPayload
  }
  deriving stock (Eq, Show)

data ConsumerError
  = ConsumerPulsarError !PulsarError
  | ConsumerDecodeError !Text
  | ConsumerWireError !Workflow.WorkflowWireError
  | ConsumerNoHandler !Text
  | ConsumerHandlerFailed !Text
  | ConsumerMinIOError !MinIOError
  deriving stock (Eq, Show)

data ConsumerStepResult
  = ConsumerNoMessage
  | ConsumerDispatched
  | ConsumerDeduplicated
  deriving stock (Eq, Show)

newtype DedupCache = DedupCache
  { dedupSeen :: TVar (Set Workflow.EventId)
  }

newDedupCache :: IO DedupCache
newDedupCache =
  DedupCache <$> newTVarIO mempty

newtype HandlerRouter m = HandlerRouter
  { handlerRoutes :: [(Text, ConsumerMessage -> m (Either ConsumerError ()))]
  }

emptyHandlerRouter :: HandlerRouter m
emptyHandlerRouter =
  HandlerRouter []

handlerRouter :: [(Text, ConsumerMessage -> m (Either ConsumerError ()))] -> HandlerRouter m
handlerRouter routes =
  HandlerRouter (sortOn (Down . Text.length . fst) routes)

data ConsumerOptions m = ConsumerOptions
  { consumerDedupCache :: !DedupCache,
    consumerHandlerRouter :: !(HandlerRouter m),
    consumerObjectMaterializer :: !(Maybe (Workflow.ObjectRef -> m (Either ConsumerError ByteString)))
  }

consumerStep ::
  (HasPulsar m, MonadIO m) =>
  ConsumerOptions m ->
  Subscription ->
  m (Either ConsumerError ConsumerStepResult)
consumerStep options subscription = do
  consumed <- pulsarConsume subscription
  case consumed of
    Left err -> pure (Left (ConsumerPulsarError err))
    Right Nothing -> pure (Right ConsumerNoMessage)
    Right (Just message) ->
      case decodeWorkflowMessage message of
        Left err -> nack message err
        Right event -> do
          firstSeen <- rememberEvent (consumerDedupCache options) (Workflow.workflowEventId event)
          if not firstSeen
            then ack message ConsumerDeduplicated
            else do
              payload <- materializePayload options (Workflow.workflowPayload event)
              case payload of
                Left err -> nack message err
                Right consumerPayloadValue ->
                  case routeHandler (consumerHandlerRouter options) event consumerPayloadValue of
                    Nothing -> nack message (ConsumerNoHandler (Workflow.unPayloadTypeUrl (Workflow.workflowPayloadType event)))
                    Just handler -> do
                      handled <- handler ConsumerMessage {consumerWorkflowEvent = event, consumerPayload = consumerPayloadValue}
                      case handled of
                        Left err -> nack message err
                        Right () -> ack message ConsumerDispatched
  where
    ack message result = do
      acknowledged <- pulsarAcknowledge subscription (pulsarMessageId message)
      pure case acknowledged of
        Left err -> Left (ConsumerPulsarError err)
        Right () -> Right result
    nack message err = do
      nacked <- pulsarNegativeAcknowledge subscription (pulsarMessageId message)
      pure case nacked of
        Left pulsarErr -> Left (ConsumerPulsarError pulsarErr)
        Right () -> Left err

decodeWorkflowMessage :: PulsarMessage -> Either ConsumerError Workflow.WorkflowEvent
decodeWorkflowMessage message =
  case (decodeMessage (pulsarMessagePayload message) :: Either String WorkflowProto.WorkflowEvent) of
    Left err -> Left (ConsumerDecodeError (Text.pack err))
    Right proto ->
      case Workflow.fromProto proto of
        Left err -> Left (ConsumerWireError err)
        Right event -> Right event

rememberEvent :: (MonadIO m) => DedupCache -> Workflow.EventId -> m Bool
rememberEvent cache eventId =
  liftIO (atomically do
    seen <- readTVar (dedupSeen cache)
    if Set.member eventId seen
      then pure False
      else do
        writeTVar (dedupSeen cache) (Set.insert eventId seen)
        pure True
    )

materializePayload ::
  (Monad m) =>
  ConsumerOptions m ->
  Workflow.WirePayload ->
  m (Either ConsumerError ConsumerPayload)
materializePayload options payload =
  case payload of
    Workflow.WireInline bytes ->
      pure (Right (ConsumerInline bytes))
    Workflow.WireObjectRef ref ->
      case consumerObjectMaterializer options of
        Nothing -> pure (Right (ConsumerObjectRef ref))
        Just materializer -> fmap (ConsumerMaterialized ref <$>) (materializer ref)

materializeObjectRef ::
  (HasMinIO m) =>
  Workflow.ObjectRef ->
  m (Either ConsumerError ByteString)
materializeObjectRef ref = do
  result <-
    readBlob
      ObjectRef
        { objectRefBucket = BucketName (Workflow.objectRefBucket ref),
          objectRefKey = ObjectKey (Workflow.objectRefKey ref)
        }
  pure case result of
    Left err -> Left (ConsumerMinIOError err)
    Right bytes -> Right bytes

routeHandler ::
  HandlerRouter m ->
  Workflow.WorkflowEvent ->
  ConsumerPayload ->
  Maybe (ConsumerMessage -> m (Either ConsumerError ()))
routeHandler (HandlerRouter routes) event _payload =
  let payloadType = Workflow.unPayloadTypeUrl (Workflow.workflowPayloadType event)
   in snd <$> findRoute payloadType routes

findRoute :: Text -> [(Text, handler)] -> Maybe (Text, handler)
findRoute payloadType =
  findFirst (\(prefix, _) -> prefix `Text.isPrefixOf` payloadType)

findFirst :: (a -> Bool) -> [a] -> Maybe a
findFirst predicate items =
  case filter predicate items of
    [] -> Nothing
    item : _ -> Just item
