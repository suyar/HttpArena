FROM buildpack-deps:bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    clang libboost-context-dev libboost-dev libssl-dev wget && \
    rm -rf /var/lib/apt/lists/*

# Download lithium single headers
WORKDIR /app
RUN wget -q https://raw.githubusercontent.com/matt-42/lithium/master/single_headers/lithium_http_server.hh

COPY main.cc .

# Compile with aggressive optimizations
RUN clang++ -O3 -march=native -flto -DNDEBUG -std=c++17 \
    -I. main.cc -o server \
    -lpthread -lboost_context -lssl -lcrypto

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libboost-context1.74.0 libssl3 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server
EXPOSE 8080
CMD ["/server"]
