---
title: Test Profiles
toc: false
---

HttpArena runs every framework through multiple benchmark profiles. Each profile isolates a different performance dimension, ensuring frameworks are compared fairly across varied workloads.

Each profile is run at multiple connection counts to show how frameworks scale under increasing concurrency:

| Parameter | Value |
|-----------|-------|
| Threads | 12 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Networking | Docker `--network host` |

{{< cards >}}
  {{< card link="h1" title="HTTP/1.1" subtitle="Baseline, short-lived connections, JSON processing, upload, compression, and pipelined benchmarks over plain TCP." icon="lightning-bolt" >}}
  {{< card link="h2" title="HTTP/2" subtitle="Baseline and static file benchmarks over encrypted TLS connections with stream multiplexing." icon="globe-alt" >}}
  {{< card link="h3" title="HTTP/3" subtitle="Baseline and static file benchmarks over QUIC for frameworks with native HTTP/3 support." icon="globe-alt" >}}
{{< /cards >}}
