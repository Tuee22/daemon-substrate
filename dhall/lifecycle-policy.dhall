{ reconcileEverySeconds = 30
, topics =
  [ { topic = "test.request"
    , lifecycle =
        < Ephemeral :
            { retentionMinutes : Natural, dedupWindowSeconds : Natural }
        | ContinuousWithArchive :
            { hotRetentionHours : Natural
            , archiveBucket : Text
            , archivePrefix : Text
            , archiveRetentionDays : Natural
            , dedupWindowSeconds : Natural
            }
        | FiniteSession :
            { sessionControlTopic : Text
            , exportOnComplete : Bool
            , archiveBucket : Optional Text
            , archivePrefix : Optional Text
            , reopenOnResume : Bool
            }
        | OnlineLearning :
            { inferenceHotHours : Natural
            , trainingHotHours : Natural
            , archiveBucket : Text
            , archivePrefix : Text
            , archiveRetentionDays : Natural
            }
        >.Ephemeral
          { retentionMinutes = 60, dedupWindowSeconds = 300 }
    }
  , { topic = "test.result"
    , lifecycle =
        < Ephemeral :
            { retentionMinutes : Natural, dedupWindowSeconds : Natural }
        | ContinuousWithArchive :
            { hotRetentionHours : Natural
            , archiveBucket : Text
            , archivePrefix : Text
            , archiveRetentionDays : Natural
            , dedupWindowSeconds : Natural
            }
        | FiniteSession :
            { sessionControlTopic : Text
            , exportOnComplete : Bool
            , archiveBucket : Optional Text
            , archivePrefix : Optional Text
            , reopenOnResume : Bool
            }
        | OnlineLearning :
            { inferenceHotHours : Natural
            , trainingHotHours : Natural
            , archiveBucket : Text
            , archivePrefix : Text
            , archiveRetentionDays : Natural
            }
        >.ContinuousWithArchive
          { hotRetentionHours = 24
          , archiveBucket = "daemon-substrate-test-archives"
          , archivePrefix = "archives/test.result/"
          , archiveRetentionDays = 7
          , dedupWindowSeconds = 300
          }
    }
  , { topic = "test.session.workload"
    , lifecycle =
        < Ephemeral :
            { retentionMinutes : Natural, dedupWindowSeconds : Natural }
        | ContinuousWithArchive :
            { hotRetentionHours : Natural
            , archiveBucket : Text
            , archivePrefix : Text
            , archiveRetentionDays : Natural
            , dedupWindowSeconds : Natural
            }
        | FiniteSession :
            { sessionControlTopic : Text
            , exportOnComplete : Bool
            , archiveBucket : Optional Text
            , archivePrefix : Optional Text
            , reopenOnResume : Bool
            }
        | OnlineLearning :
            { inferenceHotHours : Natural
            , trainingHotHours : Natural
            , archiveBucket : Text
            , archivePrefix : Text
            , archiveRetentionDays : Natural
            }
        >.FiniteSession
          { sessionControlTopic = "test.session.control"
          , exportOnComplete = True
          , archiveBucket = Some "daemon-substrate-test-archives"
          , archivePrefix = Some "archives/session/"
          , reopenOnResume = True
          }
    }
  , { topic = "test.online.learning"
    , lifecycle =
        < Ephemeral :
            { retentionMinutes : Natural, dedupWindowSeconds : Natural }
        | ContinuousWithArchive :
            { hotRetentionHours : Natural
            , archiveBucket : Text
            , archivePrefix : Text
            , archiveRetentionDays : Natural
            , dedupWindowSeconds : Natural
            }
        | FiniteSession :
            { sessionControlTopic : Text
            , exportOnComplete : Bool
            , archiveBucket : Optional Text
            , archivePrefix : Optional Text
            , reopenOnResume : Bool
            }
        | OnlineLearning :
            { inferenceHotHours : Natural
            , trainingHotHours : Natural
            , archiveBucket : Text
            , archivePrefix : Text
            , archiveRetentionDays : Natural
            }
        >.OnlineLearning
          { inferenceHotHours = 6
          , trainingHotHours = 24
          , archiveBucket = "daemon-substrate-test-archives"
          , archivePrefix = "archives/online-learning/"
          , archiveRetentionDays = 14
          }
    }
  ]
, buckets =
  [ { bucket = "daemon-substrate-test-weights"
    , layout =
      { blobs = { prefix = "blobs/", retentionDays = None Natural }
      , manifests = { prefix = "manifests/", retentionDays = None Natural }
      , pointers = { prefix = "pointers/" }
      , archives = Some { prefix = "archives/", retentionDays = 30 }
      }
    , orphanScan =
        < Never | EveryHours : { interval : Natural, safetyWindowMin : Optional Natural } >.EveryHours
          { interval = 1, safetyWindowMin = Some 1 }
    , reachableFromPointers = [ "blobs/mock-weight" ]
    , deleteOnUndeclare = False
    }
  , { bucket = "daemon-substrate-test-artifacts"
    , layout =
      { blobs = { prefix = "mock/input/", retentionDays = Some 1 }
      , manifests = { prefix = "mock/output/", retentionDays = Some 1 }
      , pointers = { prefix = "pointers/" }
      , archives = None { prefix : Text, retentionDays : Natural }
      }
    , orphanScan =
        < Never | EveryHours : { interval : Natural, safetyWindowMin : Optional Natural } >.Never
    , reachableFromPointers = [] : List Text
    , deleteOnUndeclare = False
    }
  , { bucket = "daemon-substrate-test-archives"
    , layout =
      { blobs = { prefix = "archives/", retentionDays = Some 30 }
      , manifests = { prefix = "manifests/", retentionDays = Some 30 }
      , pointers = { prefix = "pointers/" }
      , archives = Some { prefix = "archives/", retentionDays = 30 }
      }
    , orphanScan =
        < Never | EveryHours : { interval : Natural, safetyWindowMin : Optional Natural } >.Never
    , reachableFromPointers = [] : List Text
    , deleteOnUndeclare = False
    }
  ]
, auditTopic = "audit.reconcile.daemon-substrate-test"
, leaderControlTopic = "control.reconcile.leader.daemon-substrate-test"
}
