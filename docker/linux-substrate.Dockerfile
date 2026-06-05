# check=skip=InvalidDefaultArgInFrom
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

WORKDIR /workspace
COPY . .
RUN cabal install --project-file=cabal.project.container --installdir /usr/local/bin --install-method=copy --overwrite-policy=always exe:daemon-substrate-test
RUN daemon-substrate-test check-code

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/daemon-substrate-test"]
CMD ["cluster", "up", "--model", "container", "--stay-resident"]
