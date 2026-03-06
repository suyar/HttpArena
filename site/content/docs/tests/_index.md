---
title: Test Profiles
toc: false
---

HttpArena runs every framework through four distinct benchmark profiles. Each profile isolates a different performance dimension, ensuring frameworks are compared fairly across varied workloads.

Each profile is run at multiple connection counts to show how frameworks scale under increasing concurrency:

| Parameter | Value |
|-----------|-------|
| Connections | 512, 4,096, 16,384 (baseline & pipelined) / 512, 4,096 (others) |
| Threads | 12 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Networking | Docker `--network host` |

{{< cards >}}
  {{< card link="baseline" title="Baseline" subtitle="Primary throughput benchmark with persistent keep-alive connections and mixed GET/POST workload." icon="lightning-bolt" >}}
  {{< card link="short-lived" title="Short-lived Connection" subtitle="Connections closed after 10 requests, measuring TCP handshake and connection setup overhead." icon="refresh" >}}
  {{< card link="cpu-limited" title="CPU Limited (12 vCPU)" subtitle="Same workload as baseline but restricted to 12 vCPUs, revealing per-request CPU efficiency." icon="chip" >}}
  {{< card link="pipelined" title="Pipelined (16x)" subtitle="16 requests sent back-to-back per connection, testing raw I/O and pipeline batching." icon="fast-forward" >}}
{{< /cards >}}
