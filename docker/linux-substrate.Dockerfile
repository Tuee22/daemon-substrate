ARG BASE_IMAGE
FROM ${BASE_IMAGE}

WORKDIR /workspace
COPY . .
RUN cabal install --installdir /usr/local/bin --install-method=copy --overwrite-policy=always exe:daemon-substrate-test

CMD ["daemon-substrate-test", "cluster", "up"]
