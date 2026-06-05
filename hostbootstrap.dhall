let projectContainer =
      { dockerfile = "docker/Dockerfile" }

let linuxContainer =
      H.Model.Container
        H.Container::{
        , dockerfile = "docker/Dockerfile"
        , mounts =
          [ H.Mount::{ host = "./.data", container = "/workspace/.data" }
          , H.Mount::{ host = "/var/run/docker.sock", container = "/var/run/docker.sock" }
          ]
        }

let hostBinary =
      H.Model.HostBinary
        H.HostBinary::{ container = Some projectContainer }

let hostDaemon =
      H.Model.HostDaemon
        H.HostDaemon::{
        , daemon = "service --role worker --config dhall/worker.dhall"
        , container = Some projectContainer
        }

in  H.config
      { project = "daemon-substrate-test"
      , substrates =
        [ H.entry H.Substrate.AppleSilicon (H.cluster hostDaemon)
        , H.entry H.Substrate.LinuxCpu (H.cluster linuxContainer)
        , H.entry H.Substrate.LinuxGpu (H.cluster hostBinary)
        ]
      }
