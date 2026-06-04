module Daemon.Orchestrator where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, try)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Daemon.Pulsar
import Daemon.Pulsar.Admin
import Daemon.Reconciler
import Daemon.Topology.Types
import qualified Daemon.Wire.OrchestratorWorker as WorkerWire
import qualified Daemon.Wire.Workflow as Workflow

data OrchestratorOptions = OrchestratorOptions
  { orchestratorTopology :: !Topology,
    orchestratorIngressTopic :: !TopicName,
    orchestratorIngressSubscriptionName :: !SubscriptionName,
    orchestratorResultTopic :: !TopicName,
    orchestratorResultSubscriptionName :: !SubscriptionName,
    orchestratorWorkerTopic :: !TopicName,
    orchestratorResponseTopic :: !TopicName,
    orchestratorWorkerCohort :: !Text
  }
  deriving stock (Eq, Show)

data OrchestratorRuntime = OrchestratorRuntime
  { orchestratorIngressSubscription :: !Subscription,
    orchestratorResultSubscription :: !Subscription
  }
  deriving stock (Eq, Show)

data OrchestratorStepResult
  = OrchestratorNoMessage
  | OrchestratorDispatched !Text !Int
  | OrchestratorForwarded !Text
  deriving stock (Eq, Show)

data OrchestratorError
  = OrchestratorPulsarError !PulsarError
  | OrchestratorAdminError !PulsarAdminError
  | OrchestratorWorkflowWireError !Workflow.WorkflowWireError
  | OrchestratorWorkerWireError !WorkerWire.OrchestratorWorkerWireError
  deriving stock (Eq, Show)

data ConcurrentLoopResult = ConcurrentLoopResult
  { concurrentOrchestratorResult :: !(Either Text (Either OrchestratorError OrchestratorStepResult)),
    concurrentReconcilerResult :: !(Either Text (Either ReconcilerError ReconcileReport))
  }
  deriving stock (Eq, Show)

orchestratorOptions ::
  Topology ->
  TopicName ->
  SubscriptionName ->
  TopicName ->
  SubscriptionName ->
  TopicName ->
  TopicName ->
  Text ->
  OrchestratorOptions
orchestratorOptions topology ingressTopic ingressSubscription resultTopic resultSubscription workerTopic responseTopic cohort =
  OrchestratorOptions
    { orchestratorTopology = topology,
      orchestratorIngressTopic = ingressTopic,
      orchestratorIngressSubscriptionName = ingressSubscription,
      orchestratorResultTopic = resultTopic,
      orchestratorResultSubscriptionName = resultSubscription,
      orchestratorWorkerTopic = workerTopic,
      orchestratorResponseTopic = responseTopic,
      orchestratorWorkerCohort = cohort
    }

runOrchestrator ::
  (HasPulsar m, HasPulsarAdmin m) =>
  OrchestratorOptions ->
  m (Either OrchestratorError OrchestratorStepResult)
runOrchestrator options = do
  acquired <- orchestratorAcquire options
  case acquired of
    Left err -> pure (Left err)
    Right runtime -> orchestratorStep options runtime

runOrchestratorWithReconciler ::
  IO (Either OrchestratorError OrchestratorStepResult) ->
  IO (Either ReconcilerError ReconcileReport) ->
  IO ConcurrentLoopResult
runOrchestratorWithReconciler orchestratorAction reconcilerAction = do
  orchestratorDone <- newEmptyMVar
  reconcilerDone <- newEmptyMVar
  _ <- forkIO (runCaptured orchestratorAction >>= putMVar orchestratorDone)
  _ <- forkIO (runCaptured reconcilerAction >>= putMVar reconcilerDone)
  orchestratorResult <- takeMVar orchestratorDone
  reconcilerResult <- takeMVar reconcilerDone
  pure
    ConcurrentLoopResult
      { concurrentOrchestratorResult = orchestratorResult,
        concurrentReconcilerResult = reconcilerResult
      }

runCaptured :: IO a -> IO (Either Text a)
runCaptured action = do
  result <- try action
  pure case result of
    Left (exception :: SomeException) -> Left (Text.pack (displayException exception))
    Right value -> Right value

orchestratorAcquire ::
  (HasPulsar m, HasPulsarAdmin m) =>
  OrchestratorOptions ->
  m (Either OrchestratorError OrchestratorRuntime)
orchestratorAcquire options = do
  provisioned <- provisionTopology options
  case provisioned of
    Left err -> pure (Left err)
    Right () -> do
      ingress <-
        pulsarSubscribe
          (orchestratorIngressTopic options)
          (orchestratorIngressSubscriptionName options)
          Shared
      case ingress of
        Left err -> pure (Left (OrchestratorPulsarError err))
        Right ingressSubscription -> do
          results <-
            pulsarSubscribe
              (orchestratorResultTopic options)
              (orchestratorResultSubscriptionName options)
              Shared
          pure case results of
            Left err -> Left (OrchestratorPulsarError err)
            Right resultSubscription ->
              Right
                OrchestratorRuntime
                  { orchestratorIngressSubscription = ingressSubscription,
                    orchestratorResultSubscription = resultSubscription
                  }

provisionTopology ::
  (HasPulsarAdmin m) =>
  OrchestratorOptions ->
  m (Either OrchestratorError ())
provisionTopology options =
  createAll (orchestratorRequiredTopics options)
  where
    createAll topics =
      case topics of
        [] -> pure (Right ())
        topic : rest -> do
          created <- createTopic topic
          case created of
            Left err -> pure (Left (OrchestratorAdminError err))
            Right _ -> createAll rest

orchestratorRequiredTopics :: OrchestratorOptions -> [TopicName]
orchestratorRequiredTopics options =
  Set.toList
    ( Set.fromList
        ( fmap topologyTopicName (topologyTopics (orchestratorTopology options))
            <> [ orchestratorIngressTopic options,
                 orchestratorResultTopic options,
                 orchestratorWorkerTopic options,
                 orchestratorResponseTopic options
               ]
        )
    )

subscribeTopology ::
  (HasPulsar m) =>
  Topology ->
  m (Either OrchestratorError [Subscription])
subscribeTopology topology =
  subscribeAll (topologySubscriptions topology)
  where
    subscribeAll subscriptions =
      case subscriptions of
        [] -> pure (Right [])
        subscription : rest -> do
          subscribed <-
            pulsarSubscribe
              (topologySubscriptionTopic subscription)
              (topologySubscriptionName subscription)
              (topologySubscriptionMode subscription)
          case subscribed of
            Left err -> pure (Left (OrchestratorPulsarError err))
            Right handle -> fmap (handle :) <$> subscribeAll rest

orchestratorStep ::
  (HasPulsar m) =>
  OrchestratorOptions ->
  OrchestratorRuntime ->
  m (Either OrchestratorError OrchestratorStepResult)
orchestratorStep options runtime = do
  ingress <- pulsarConsume (orchestratorIngressSubscription runtime)
  case ingress of
    Left err -> pure (Left (OrchestratorPulsarError err))
    Right (Just message) -> handleIngress options runtime message
    Right Nothing -> do
      result <- pulsarConsume (orchestratorResultSubscription runtime)
      case result of
        Left err -> pure (Left (OrchestratorPulsarError err))
        Right Nothing -> pure (Right OrchestratorNoMessage)
        Right (Just message) -> handleWorkerResult options runtime message

orchestratorDispatchBatch ::
  (HasPulsar m) =>
  OrchestratorOptions ->
  Text ->
  NonEmpty Workflow.WorkflowEvent ->
  m (Either OrchestratorError MessageId)
orchestratorDispatchBatch options batchId events =
  publishWorkerBatch
    options
    WorkerWire.OrchestratorToWorker
      { WorkerWire.orchestratorBatchId = batchId,
        WorkerWire.orchestratorCohort = orchestratorWorkerCohort options,
        WorkerWire.orchestratorEvents = NonEmpty.toList events
      }

orchestratorDrainOrder :: Topology -> [TopologySubscription]
orchestratorDrainOrder =
  reverse . topologySubscriptions

handleIngress ::
  (HasPulsar m) =>
  OrchestratorOptions ->
  OrchestratorRuntime ->
  PulsarMessage ->
  m (Either OrchestratorError OrchestratorStepResult)
handleIngress options runtime message =
  case Workflow.decodeWorkflowEvent (pulsarMessagePayload message) of
    Left err -> nackOrchestratorMessage (orchestratorIngressSubscription runtime) message (OrchestratorWorkflowWireError err)
    Right event -> do
      let batchId = Workflow.unEventId (Workflow.workflowEventId event)
      published <- orchestratorDispatchBatch options batchId (event :| [])
      case published of
        Left err -> nackOrchestratorMessage (orchestratorIngressSubscription runtime) message err
        Right _ -> ackOrchestratorMessage (orchestratorIngressSubscription runtime) message (OrchestratorDispatched batchId 1)

handleWorkerResult ::
  (HasPulsar m) =>
  OrchestratorOptions ->
  OrchestratorRuntime ->
  PulsarMessage ->
  m (Either OrchestratorError OrchestratorStepResult)
handleWorkerResult options runtime message =
  case WorkerWire.decodeWorkerResult (pulsarMessagePayload message) of
    Left err -> nackOrchestratorMessage (orchestratorResultSubscription runtime) message (OrchestratorWorkerWireError err)
    Right result -> do
      forwarded <- publishResponse options result
      case forwarded of
        Left err -> nackOrchestratorMessage (orchestratorResultSubscription runtime) message err
        Right _ -> ackOrchestratorMessage (orchestratorResultSubscription runtime) message (OrchestratorForwarded (WorkerWire.workerRequestId result))

publishWorkerBatch ::
  (HasPulsar m) =>
  OrchestratorOptions ->
  WorkerWire.OrchestratorToWorker ->
  m (Either OrchestratorError MessageId)
publishWorkerBatch options batch = do
  published <-
    pulsarPublish
      (orchestratorWorkerTopic options)
      ProducerMessage
        { producerKey = Just (WorkerWire.orchestratorBatchId batch),
          producerPayload = WorkerWire.encodeOrchestratorToWorker batch,
          producerProperties = Map.empty,
          producerDeduplicationKey = Just (WorkerWire.orchestratorBatchId batch)
        }
  pure case published of
    Left err -> Left (OrchestratorPulsarError err)
    Right messageId -> Right messageId

publishResponse ::
  (HasPulsar m) =>
  OrchestratorOptions ->
  WorkerWire.WorkerResult ->
  m (Either OrchestratorError MessageId)
publishResponse options result = do
  published <-
    pulsarPublish
      (orchestratorResponseTopic options)
      ProducerMessage
        { producerKey = Just (WorkerWire.workerRequestId result),
          producerPayload = WorkerWire.encodeWorkerResult result,
          producerProperties = Map.empty,
          producerDeduplicationKey =
            Just (WorkerWire.workerBatchId result <> ":" <> WorkerWire.workerRequestId result)
        }
  pure case published of
    Left err -> Left (OrchestratorPulsarError err)
    Right messageId -> Right messageId

ackOrchestratorMessage ::
  (HasPulsar m) =>
  Subscription ->
  PulsarMessage ->
  OrchestratorStepResult ->
  m (Either OrchestratorError OrchestratorStepResult)
ackOrchestratorMessage subscription message result = do
  acknowledged <- pulsarAcknowledge subscription (pulsarMessageId message)
  pure case acknowledged of
    Left err -> Left (OrchestratorPulsarError err)
    Right () -> Right result

nackOrchestratorMessage ::
  (HasPulsar m) =>
  Subscription ->
  PulsarMessage ->
  OrchestratorError ->
  m (Either OrchestratorError OrchestratorStepResult)
nackOrchestratorMessage subscription message err = do
  nacked <- pulsarNegativeAcknowledge subscription (pulsarMessageId message)
  pure case nacked of
    Left pulsarErr -> Left (OrchestratorPulsarError pulsarErr)
    Right () -> Left err
