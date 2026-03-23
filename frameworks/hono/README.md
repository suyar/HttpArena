# Hono

[Hono](https://github.com/honojs/hono) is an ultrafast, lightweight web framework built on Web Standards. It runs on any JavaScript runtime — Node.js, Bun, Deno, Cloudflare Workers, and more.

## Implementation Notes

- Uses `@hono/node-server` for the Node.js runtime adapter
- Cluster mode with one worker per CPU core
- `better-sqlite3` for the /db endpoint with mmap enabled
- Manual gzip compression (zlib level 1) for /compression
- HTTP/2 via native `http2` module on port 8443
- Hono's RegExpRouter provides fast pattern matching

## Why Hono?

Hono is one of the fastest-growing JS frameworks (~29k stars). Its key differentiator is being built entirely on Web Standards (Request/Response), making it portable across runtimes. Running it on Node.js via `@hono/node-server` shows how the Web Standards abstraction layer performs compared to native Node.js APIs (Fastify, bare node) and other runtimes (Bun, Deno).
