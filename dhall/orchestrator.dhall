{ role = < Worker | Orchestrator >.Orchestrator
, app =
  { harnessOrchestratorIngressTopic = "test.request"
  , harnessOrchestratorResultTopic = "test.result"
  , harnessOrchestratorResponseTopic = "test.response"
  , harnessOrchestratorControlTopic = "test.control.orchestrator"
  , harnessOrchestratorAuditTopic = "audit.reconcile.daemon-substrate-test"
  , harnessOrchestratorLifecyclePolicyPath = "dhall/lifecycle-policy.dhall"
  , harnessOrchestratorLiveConfigPath = "dhall/live.dhall"
  , harnessOrchestratorWorkerTopics =
    [ { harnessWorkerTopicCohort = "apple-silicon", harnessWorkerTopicName = "test.batch.apple-silicon" }
    , { harnessWorkerTopicCohort = "linux-cpu", harnessWorkerTopicName = "test.batch.linux-cpu" }
    ]
  }
, pulsarServiceUrl = "pulsar://daemon-substrate-test-pulsar:6650"
, pulsarAdminUrl = "http://daemon-substrate-test-pulsar:8080"
, minIOEndpoint = "http://daemon-substrate-test-minio:9000"
, harborEndpoint = Some "https://daemon-substrate-test-harbor"
, kubectlPath = "/usr/local/bin/kubectl"
, maxInlinePayloadBytes = 1048576
}
