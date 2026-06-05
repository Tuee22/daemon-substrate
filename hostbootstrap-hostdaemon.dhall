H.config
  { project = "daemon-substrate"
  , targets =
    [ H.target H.Accel.Cpu
        ( H.Model.HostDaemon
            H.HostDaemon::{
            , build =
                H.Build::{
                , cabal =
                    "/bin/sh -c 'cabal install --installdir .build --install-method=copy --overwrite-policy=always exe:daemon-substrate-test && cp .build/daemon-substrate-test .build/daemon-substrate'"
                , host = H.HostReqs::{ ghc = True }
                }
            , daemon =
                ".build/daemon-substrate-test service --role worker --config dhall/worker.dhall"
            }
        )
    ]
  }
