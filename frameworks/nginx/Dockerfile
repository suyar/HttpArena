ARG NGINX_VERSION=1.28.3

FROM debian:bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libpcre2-dev zlib1g-dev libsqlite3-dev wget ca-certificates git perl

# Build quictls (OpenSSL fork with QUIC support)
WORKDIR /tmp
RUN git clone --depth 1 -b openssl-3.1.5+quic https://github.com/quictls/openssl.git quictls && \
    cd quictls && \
    ./Configure --prefix=/opt/quictls --libdir=lib no-tests && \
    make -j$(nproc) && \
    make install_sw

# Download nginx source
ARG NGINX_VERSION
RUN wget -q http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
    tar xzf nginx-${NGINX_VERSION}.tar.gz

# Download cJSON for JSON parsing
RUN wget -q -O /tmp/cJSON.c https://raw.githubusercontent.com/DaveGamble/cJSON/v1.7.18/cJSON.c && \
    wget -q -O /tmp/cJSON.h https://raw.githubusercontent.com/DaveGamble/cJSON/v1.7.18/cJSON.h

# Copy module
COPY ngx_http_httparena_module.c config /tmp/module/
RUN cp /tmp/cJSON.c /tmp/cJSON.h /tmp/module/

# Build nginx with custom module + HTTP/3
WORKDIR /tmp/nginx-${NGINX_VERSION}
RUN ./configure \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --add-module=/tmp/module \
    --with-cc-opt="-O3 -march=native -DNDEBUG -I/opt/quictls/include" \
    --with-ld-opt="-lm -lsqlite3 -L/opt/quictls/lib -Wl,-rpath,/opt/quictls/lib" && \
    make -j$(nproc)

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpcre2-8-0 libsqlite3-0 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/quictls/lib/libssl.so.81.3 /opt/quictls/lib/libcrypto.so.81.3 /opt/quictls/lib/
RUN ln -s libssl.so.81.3 /opt/quictls/lib/libssl.so.81 && \
    ln -s libssl.so.81 /opt/quictls/lib/libssl.so && \
    ln -s libcrypto.so.81.3 /opt/quictls/lib/libcrypto.so.81 && \
    ln -s libcrypto.so.81 /opt/quictls/lib/libcrypto.so && \
    ldconfig /opt/quictls/lib
ARG NGINX_VERSION
COPY --from=build /tmp/nginx-${NGINX_VERSION}/objs/nginx /usr/sbin/nginx
RUN mkdir -p /usr/local/nginx/logs
COPY nginx.conf /usr/local/nginx/conf/nginx.conf
EXPOSE 8080 8443/tcp 8443/udp
CMD ["nginx", "-g", "daemon off;"]
