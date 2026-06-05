H.config
  { project = "daemon-substrate"
  , targets =
    [ H.target H.Accel.Cpu
        ( H.Model.HostBinary
            H.HostBinary::{
            , build =
                H.Build::{
                , cabal =
                    "/bin/sh -c 'cabal install --installdir .build --install-method=copy --overwrite-policy=always exe:daemon-substrate-test && cp .build/daemon-substrate-test .build/daemon-substrate'"
                , host = H.HostReqs::{ ghc = True }
                }
            , handoff =
                H.Handoff::{
                , up = ".build/daemon-substrate-test cluster up --model host-binary"
                , down = ".build/daemon-substrate-test cluster down --model host-binary"
                , delete = Some ".build/daemon-substrate-test cluster down --model host-binary"
                }
            }
        )
    ]
  }
