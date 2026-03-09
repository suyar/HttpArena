---
title: Baseline (HTTP/2)
---

Same workload as the HTTP/1.1 baseline — query parameter parsing and sum computation — but over encrypted HTTP/2 connections using TLS and ALPN negotiation.

**Connections:** 64, 256, 1,024
**Concurrent streams per connection:** 100

## Workload

`GET /baseline2?a=1&b=1` sent over HTTP/2 with TLS. The load generator ([h2load](https://nghttp2.org/documentation/h2load-howto.html)) opens multiple connections, each multiplexing up to 100 concurrent streams.

## What it measures

- HTTP/2 multiplexing efficiency
- TLS handshake and encryption overhead
- How frameworks handle many concurrent streams per connection
- HPACK header compression performance

## How it differs from baseline

| | Baseline (HTTP/1.1) | Baseline (HTTP/2) |
|---|---|---|
| Protocol | HTTP/1.1 plaintext | HTTP/2 over TLS |
| Connections | 512 - 16,384 | 64 - 1,024 |
| Requests per connection | 1 at a time | 100 concurrent streams |
| Load generator | gcannon | h2load |
| Port | 8080 | 8443 |

HTTP/2 uses far fewer connections because each connection multiplexes many streams. The lower connection counts reflect real-world HTTP/2 usage patterns.

## Framework requirements

To participate in this test, a framework must:

1. Listen on **port 8443** with TLS and HTTP/2 enabled
2. Load TLS certificates from `/certs/server.crt` and `/certs/server.key`
3. Handle `GET /baseline2?a=N&b=N` with the same sum logic as `/baseline11`
4. Add `"baseline-h2"` to the `tests` array in `meta.json`

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /baseline2?a=1&b=1` |
| Connections | 64, 256, 1,024 |
| Streams per connection | 100 (`-m 100`) |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | h2load |
