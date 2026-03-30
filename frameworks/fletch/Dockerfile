# Stage 1 — AOT compile the Dart server
FROM dart:stable AS build

WORKDIR /app
COPY pubspec.yaml ./
RUN dart pub get

COPY . .
RUN dart build cli --target bin/server.dart --output /app/build

# Stage 2 — Minimal runtime image
FROM debian:bookworm-slim

# The Dart sqlite3 FFI loader looks for libsqlite3.so (unversioned), so we
# install the -dev package to ensure that soname symlink exists.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/build/bundle /server
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/entrypoint.sh"]
