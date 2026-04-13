FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git build-essential libssl-dev zlib1g-dev unzip \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN git clone --depth 1 https://github.com/wg/wrk.git . && \
    make -j"$(nproc)"

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
        libssl3 zlib1g ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/wrk /usr/local/bin/wrk
ENTRYPOINT ["wrk"]
