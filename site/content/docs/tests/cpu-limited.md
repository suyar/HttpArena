---
title: CPU Limited (12 vCPU)
---

Same workload as baseline, but the server's Docker container is restricted to 12 vCPUs via `--cpus=12`. This reveals per-request CPU efficiency.

**Connections:** 512, 4,096

## What it measures

- Frameworks with lower overhead per request maintain higher throughput
- Highlights the cost of runtime features (GC, goroutine scheduling, JIT compilation)
- Shows how well a framework scales when CPU is the bottleneck rather than I/O

## Interpreting results

A framework that scores the same here as in baseline is not CPU-bound in either test. A significant drop indicates the framework's throughput is limited by CPU overhead — useful for understanding real-world performance on shared or resource-constrained infrastructure.
