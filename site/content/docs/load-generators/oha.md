---
title: oha
---

[oha](https://github.com/hatoo/oha) is an HTTP load generator with HTTP/3 (QUIC) support, used for the baseline-h3 and static-h3 test profiles.

## Usage in HttpArena

oha handles all HTTP/3 benchmarks, sending requests over QUIC to port 8443:

```bash
oha https://localhost:8443/baseline2?a=1&b=1 \
    --http-version 3 --insecure \
    -c 64 -p 128 -z 5s \
    -o results.json --output-format json
```

For multi-URI static file tests:

```bash
oha requests/static-h2-uris.txt \
    --urls-from-file \
    --http-version 3 --insecure \
    -c 64 -p 128 -z 5s \
    -o results.json --output-format json
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `--http-version 3` | Force HTTP/3 (QUIC) |
| `--insecure` | Accept self-signed TLS certificates |
| `-c` | Number of connections |
| `-p` | Parallelism (concurrent requests per connection) |
| `-z` | Test duration |
| `-o` / `--output-format json` | JSON output to file |

## Known issues

oha's `--no-tui` flag causes severe performance degradation with HTTP/3. As a workaround, HttpArena runs oha with the TUI active and captures results via `-o file --output-format json`. This means oha must have direct TTY access and cannot run in a subshell or background process.

Due to this limitation, HTTP/3 results may show higher variance than HTTP/1.1 and HTTP/2 benchmarks. A disclaimer is shown on the HTTP/3 leaderboard.
