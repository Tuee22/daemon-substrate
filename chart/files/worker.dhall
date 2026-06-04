{ role = < Worker | Orchestrator >.Worker
, app =
  { harnessWorkerCohort = "linux-cpu"
  , harnessWorkerWorkTopic = "test.batch.linux-cpu"
  , harnessWorkerResultTopic = "test.result"
  , harnessWorkerControlTopic = "test.control.worker"
  , harnessWorkerCacheDirectory = "/var/lib/daemon-substrate/cache"
  }
, pulsarServiceUrl = "pulsar://daemon-substrate-test-pulsar:6650"
, pulsarAdminUrl = "http://daemon-substrate-test-pulsar:8080"
, minIOEndpoint = "http://daemon-substrate-test-minio:9000"
, harborEndpoint = None Text
, kubectlPath = "/usr/local/bin/kubectl"
, maxInlinePayloadBytes = 1048576
}
