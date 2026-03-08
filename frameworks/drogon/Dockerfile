FROM ubuntu:24.04 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    g++ cmake make git ca-certificates \
    libjsoncpp-dev uuid-dev zlib1g-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Build drogon from source
WORKDIR /tmp/drogon
RUN git clone --depth 1 --branch v1.9.10 https://github.com/drogonframework/drogon.git . && \
    git submodule update --init && \
    cmake -B build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CXX_FLAGS="-flto" \
      -DBUILD_EXAMPLES=OFF -DBUILD_CTL=OFF \
      -DBUILD_ORM=OFF -DBUILD_BROTLI=OFF \
      -S . && \
    cmake --build build -j$(nproc) && \
    cmake --install build

# Build app
WORKDIR /app
COPY CMakeLists.txt main.cc ./
RUN cmake -B build -DCMAKE_BUILD_TYPE=Release -S . && \
    cmake --build build -j$(nproc)

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    libjsoncpp25 libssl3t64 libuuid1 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/lib/libtrantor.so* /usr/local/lib/
COPY --from=build /usr/local/lib/libdrogon.so* /usr/local/lib/
COPY --from=build /app/build/server /server
RUN ldconfig
EXPOSE 8080 8443
CMD ["/server"]
