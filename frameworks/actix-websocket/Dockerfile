FROM rust:1.94-bookworm AS build
WORKDIR /app

COPY Cargo.toml Cargo.lock* ./
COPY src/ src/

RUN cargo build --release

FROM debian:bookworm-slim
WORKDIR /app

COPY --from=build /app/target/release/actix-websocket .

EXPOSE 8080
ENTRYPOINT ["./actix-websocket"]
