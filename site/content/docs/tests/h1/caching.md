---
title: Caching (ETag 304)
---

The Caching profile measures how efficiently a framework handles HTTP conditional requests using ETag-based cache validation. Every request includes an `If-None-Match` header matching the server's ETag, so the expected response is `304 Not Modified` with no body.

**Connections:** 512, 4,096, 16,384

## How it works

1. The server defines a fixed ETag value (`"AOK"`) for the `/caching` endpoint
2. On each `GET /caching` request, the server checks the `If-None-Match` header
3. If `If-None-Match` matches the ETag, the server returns `304 Not Modified` with no body
4. If it doesn't match (or is absent), the server returns `200 OK` with body `"OK"` and the `ETag` header

In this benchmark, all requests include the matching `If-None-Match` header, so every response is a `304`.

## What it measures

- **Conditional request handling** — `If-None-Match` header parsing and ETag comparison
- **304 Not Modified throughput** — minimal-overhead bodyless response path
- **Framework routing and header overhead** — how efficiently the framework dispatches a simple endpoint

## Expected response

```
GET /caching HTTP/1.1
If-None-Match: "AOK"
```

```
HTTP/1.1 304 Not Modified
ETag: "AOK"
```

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /caching` |
| Connections | 512, 4,096, 16,384 |
| Pipeline | 1 |
| Duration | 5s |
| Runs | 3 (best taken) |
| ETag | `"AOK"` (fixed) |
