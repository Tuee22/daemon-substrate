{ role = < Worker | Orchestrator >.Worker
, app =
  { harnessWorkerCohort = "apple-silicon"
  , harnessWorkerWorkTopic = "test.batch.apple-silicon"
  , harnessWorkerResultTopic = "test.result"
  , harnessWorkerControlTopic = "test.control.worker"
  , harnessWorkerCacheDirectory = ".cache/daemon-substrate-worker"
  }
, pulsarServiceUrl = "pulsar://daemon-substrate-test-pulsar:6650"
, pulsarAdminUrl = "http://daemon-substrate-test-pulsar:8080"
, minIOEndpoint = "http://daemon-substrate-test-minio:9000"
, harborEndpoint = None Text
, kubectlPath = "/usr/local/bin/kubectl"
, maxInlinePayloadBytes = 1048576
}
