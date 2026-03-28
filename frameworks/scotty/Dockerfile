FROM haskell:9.8-slim AS builder

# Fix archived bullseye repos and install build dependencies
RUN sed -i 's|deb.debian.org|archive.debian.org|g' /etc/apt/sources.list && \
    sed -i '/bullseye-updates/d' /etc/apt/sources.list && \
    sed -i '/bullseye-security/d' /etc/apt/sources.list && \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --no-install-recommends --allow-downgrades \
      libsqlite3-0=3.34.1-3 libsqlite3-dev libpq-dev zlib1g-dev pkg-config && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY scotty-bench.cabal .
RUN cabal update && \
    cabal build --only-dependencies \
      --constraint='postgresql-libpq-configure < 0.11'

COPY Main.hs .
RUN cabal build \
      --constraint='postgresql-libpq-configure < 0.11' && \
    cp $(cabal list-bin scotty-bench) /build/scotty-bench

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends libpq5 libsqlite3-0 zlib1g libgmp10 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /build/scotty-bench /app/scotty-bench

EXPOSE 8080

CMD ["/app/scotty-bench"]
