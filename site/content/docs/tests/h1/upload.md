---
title: Upload (20 MB)
---

The Upload profile measures how efficiently a framework handles large request body ingestion. Each request sends a 20 MB binary payload and the server returns its CRC32 checksum.

**Connections:** 64, 256, 512

## How it works

1. The load generator sends `POST /upload` with a 20 MB binary body using a pre-built raw request file
2. The server reads the entire request body into memory
3. Computes a CRC32 (ISO 3309) checksum using slicing-by-8 optimization
4. Returns the checksum as an 8-character lowercase hex string

## What it measures

- **Request body ingestion throughput** — reading large payloads from the network
- **Memory management** — buffering 20 MB per concurrent request
- **I/O handling efficiency** — how the framework manages sustained large transfers
- **Connection overhead** — at 20 MB per request, connection setup/teardown is significant

## Expected response

```
POST /upload HTTP/1.1
Content-Length: 20971520
```

```
HTTP/1.1 200 OK
Content-Type: text/plain

4a6ce2a3
```

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `POST /upload` |
| Connections | 64, 256, 512 |
| Pipeline | 1 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Payload | 20 MB binary (`data/upload.bin`) |
| Checksum | CRC32 (slicing-by-8) |

## Notes

- I/O is the primary bottleneck, not CRC32 computation
- Lower connection counts are used because each request transfers 20 MB
- The load generator's bandwidth metric only measures response data (~8 bytes), not the uploaded payload
