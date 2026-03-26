# HttpArena

HTTP framework benchmark platform.

16 test profiles. 64-core dedicated hardware. Same conditions for every framework.

[View Leaderboard](https://MDA2AV.github.io/HttpArena/) | [Documentation](https://MDA2AV.github.io/HttpArena/docs/) | [Add a Framework](https://MDA2AV.github.io/HttpArena/docs/add-framework/)

---

## PR Commands

Tag **@BennyFranciscus** on your PR for help with implementation or benchmark questions.

| Command | Action |
|---------|--------|
| `/validate` | Run the 18-point validation suite |
| `/benchmark` | Run all benchmark profiles |
| `/benchmark baseline` | Run a specific profile |

---

## Test Profiles

| Category | Profiles | Description |
|----------|----------|-------------|
| Connection | Baseline (512-32K), Pipelined, Limited | Performance scaling with connection count |
| Workload | JSON, Compression, Upload, Database, Async DB | Serialization, gzip, I/O, SQLite queries, async Postgres |
| Resilience | Noisy, Mixed | Malformed requests, concurrent endpoints |
| Protocol | HTTP/2, HTTP/3, gRPC, WebSocket | Multi-protocol support |

## Run Locally

```bash
git clone https://github.com/MDA2AV/HttpArena.git
cd HttpArena

./scripts/validate.sh <framework>            # correctness check
./scripts/benchmark.sh <framework>           # all profiles
./scripts/benchmark.sh <framework> baseline  # specific profile
./scripts/benchmark.sh <framework> --save    # save results
```

## Add a Framework

1. Create `frameworks/<name>/Dockerfile`
2. Implement the [required endpoints](https://MDA2AV.github.io/HttpArena/docs/add-framework/)
3. Add `frameworks/<name>/meta.json`
4. Open a PR — validation runs automatically

See any existing entry in `frameworks/` for reference.

## Hardware

- CPU: 64-core AMD Threadripper
- Dedicated hardware, no VMs, no noisy neighbors
- Load generator: [gcannon](https://github.com/MDA2AV/gcannon) (io_uring-based)

## Contributing

- [Add a framework](https://MDA2AV.github.io/HttpArena/docs/add-framework/)
- [Open an issue](https://github.com/MDA2AV/HttpArena/issues)
- Comment on any open issue or PR
