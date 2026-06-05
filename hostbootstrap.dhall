H.config
  { project = "daemon-substrate"
  , targets =
    [ H.target H.Accel.Cpu
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
    ]
  }
