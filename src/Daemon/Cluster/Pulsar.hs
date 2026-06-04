module Daemon.Cluster.Pulsar where

import Data.Text (Text)
import Daemon.Cluster.Types
import Daemon.Kubectl
import Daemon.Pulsar

data PulsarBootstrapConfig = PulsarBootstrapConfig
  { pulsarNamespace :: !Text,
    pulsarBrokerResource :: !ResourceName,
    pulsarTenant :: !Text,
    pulsarTenantNamespace :: !Text,
    pulsarRequiredTopics :: ![TopicName]
  }
  deriving stock (Eq, Show)

defaultPulsarBootstrapConfig :: PulsarBootstrapConfig
defaultPulsarBootstrapConfig =
  PulsarBootstrapConfig
    { pulsarNamespace = "default",
      pulsarBrokerResource = ResourceName "statefulset/daemon-substrate-test-pulsar",
      pulsarTenant = "daemon-substrate-test",
      pulsarTenantNamespace = "workflows",
      pulsarRequiredTopics =
        [ TopicName "test.request",
          TopicName "test.batch.apple-silicon",
          TopicName "test.batch.linux-cpu",
          TopicName "test.result",
          TopicName "test.control.orchestrator",
          TopicName "test.control.worker",
          TopicName "control.reconcile.leader.daemon-substrate-test",
          TopicName "audit.reconcile.daemon-substrate-test",
          TopicName "test.session.control"
        ]
    }

pulsarBootstrapPlan :: PulsarBootstrapConfig -> [ClusterAction]
pulsarBootstrapPlan config =
  [ clusterAction
      "pulsar-wait"
      "Wait for the Pulsar broker before admin namespace setup."
      (WaitForKubernetesResource (pulsarBrokerResource config)),
    clusterAction
      "pulsar-tenant"
      "Ensure the test-harness Pulsar tenant exists."
      (PulsarAdminOperation ("create tenant " <> pulsarTenant config)),
    clusterAction
      "pulsar-namespace"
      "Ensure the test-harness Pulsar namespace exists."
      (PulsarAdminOperation ("create namespace " <> pulsarTenant config <> "/" <> pulsarTenantNamespace config))
  ]
    <> fmap topicAction (pulsarRequiredTopics config)

topicAction :: TopicName -> ClusterAction
topicAction topic =
  clusterAction
    ("pulsar-topic-" <> unTopicName topic)
    "Ensure a required Pulsar topic exists."
    (PulsarAdminOperation ("create topic " <> unTopicName topic))
