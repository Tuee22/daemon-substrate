H.config
  { project = "daemon-substrate"
  , substrates =
    [ H.entry H.Substrate.LinuxCpu
        ( H.Model.Container
            H.Container::{
            , dockerfile = "docker/linux-substrate.Dockerfile"
            , service = True
            , mounts =
              [ H.Mount::{ host = "./.data", container = "/workspace/.data" }
              , H.Mount::{ host = "/var/run/docker.sock", container = "/var/run/docker.sock" }
              ]
            }
        )
    , H.entry H.Substrate.AppleSilicon
        ( H.Model.HostDaemon
            H.HostDaemon::{
            , build =
                H.Build::{
                , cabal = "cabal install --installdir .build --install-method=copy --overwrite-policy=always exe:daemon-substrate-test"
                , host = H.HostReqs::{ ghc = True }
                }
            , daemon = ".build/daemon-substrate-test service --role worker --config dhall/worker.dhall"
            }
        )
    ]
  }

