{ retryPolicy =
  { maxAttempts = 3
  , baseDelayMs = 100
  , maxDelayMs = 1000
  }
, dedupCache =
  { maxEntries = 10000
  , ttlSeconds = 300
  }
, drainDeadlineSeconds = 30
, batchingPolicy =
  { maxBatchSize = 16
  , maxWaitWindowMs = 25
  , minBatchSize = 1
  , maxInFlightBuffer = 1024
  , flushStrategy = < MaxFillOrTimeout | AdaptiveLatencyAware | WindowedFixed | DeadlineAware >.MaxFillOrTimeout
  , backpressureMode = < Block | ShedLoad | Redirect >.Block
  , secondaryWorker = None Text
  }
, schedulerPolicy =
  { bucketWeights =
    [ { bucket = "apple-silicon", weight = 1.0 }
    , { bucket = "linux-cpu", weight = 1.0 }
    , { bucket = "default", weight = 1.0 }
    ]
  , deadlinePreemptionMs = 50
  , bucketDwellMs = 0
  }
}
