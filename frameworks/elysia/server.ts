import { Elysia } from "elysia";
import { staticPlugin } from "@elysiajs/static";
import { readFileSync } from "fs";
import { brotliCompressSync } from "node:zlib";
import cluster from "cluster";
import { availableParallelism } from "os";

// Worker count: env override wins, else one per CPU. Each worker costs
// ~150 MB RSS. Override with ELYSIA_WORKERS env var to cap lower on small boxes.
const WORKERS = Math.max(
	1,
	Math.min(
		parseInt(process.env.ELYSIA_WORKERS ?? "", 10) || availableParallelism(),
		availableParallelism(),
	),
);

// Preload dataset for /json (both primary and workers read it, ~1 MB).
const datasetItems: any[] = JSON.parse(
	readFileSync("/data/dataset.json", "utf8"),
);

// Resolve the async staticPlugin at real top level (outside the cluster
// conditional) — `bun build --compile` can't handle top-level await inside
// if/else blocks, and we need the plugin fully resolved before .use() so
// its routes register synchronously into the main Elysia chain.
//
// alwaysStatic: false — `true` (the NODE_ENV=production default) pre-registers
// each file as a Bun static route, which requires a fully-buffered body and
// crashes with `Bun.file()` streams. Dynamic routing reads disk per request
// which is also more production-rule compliant.
const staticModule = await staticPlugin({
	assets: "/data/static",
	prefix: "/static",
	etag: false,
	alwaysStatic: false,
});

if (cluster.isPrimary) {
	for (let i = 0; i < WORKERS; i++) cluster.fork();
	cluster.on("exit", (w) => {
		console.error(`worker ${w.process.pid} exited, respawning`);
		cluster.fork();
	});
} else {

// PostgreSQL pool for /async-db (node-postgres via Bun's node_modules resolver).
// Pool size per worker is DATABASE_MAX_CONN / WORKERS so the total across the
// cluster matches the server's configured max_connections (256 by default).
let pgPool: any = null;
{
	const dbUrl = process.env.DATABASE_URL;
	if (dbUrl) {
		try {
			const { Pool } = require("pg");
			const totalMax = parseInt(process.env.DATABASE_MAX_CONN ?? "", 10) || 256;
			const perWorker = Math.max(1, Math.floor(totalMax / WORKERS));
			pgPool = new Pool({ connectionString: dbUrl, max: perWorker });
		} catch (_) {}
	}
}

const EMPTY_DB_JSON = '{"items":[],"count":0}';

new Elysia()
	.get("/pipeline", () => new Response("ok", { headers: { "content-type": "text/plain" } }))
	.get("/baseline11", ({ query }) => {
		let sum = 0;
		for (const v of Object.values(query)) sum += parseInt(v as string, 10) || 0;
		return new Response(String(sum), {
			headers: { "content-type": "text/plain" },
		});
	})
	.post("/baseline11", async ({ query, request }) => {
		let total = 0;
		for (const v of Object.values(query)) total += parseInt(v as string, 10) || 0;
		const body = await request.text();
		const n = parseInt(body.trim(), 10);
		if (!isNaN(n)) total += n;
		return new Response(String(total), {
			headers: { "content-type": "text/plain" },
		});
	})
	.get("/baseline2", ({ query }) => {
		let sum = 0;
		for (const v of Object.values(query)) sum += parseInt(v as string, 10) || 0;
		return new Response(String(sum), {
			headers: { "content-type": "text/plain" },
		});
	})
	.get("/json/:count", ({ params, query, headers, set }) => {
		const count = Math.max(
			0,
			Math.min(+params.count || 0, datasetItems.length),
		);
		const m = query.m ? +query.m || 1 : 1;

		const result = {
			count,
			items: datasetItems.slice(0, count).map((d: any) => ({
				id: d.id,
				name: d.name,
				category: d.category,
				price: d.price,
				quantity: d.quantity,
				active: d.active,
				tags: d.tags,
				rating: d.rating,
				total: d.price * d.quantity * m,
			})),
		};

		const encoding = headers["accept-encoding"];
		if (encoding) {
			const index = encoding.indexOf(",");
			const type = index === -1 ? encoding : encoding.slice(0, index);

			set.headers["content-type"] = "application/json";
			if (type === "gzip") {
				set.headers["content-encoding"] = "gzip";
				return Bun.gzipSync(JSON.stringify(result));
			} else if (type === "br") {
				set.headers["content-encoding"] = "br";
				return brotliCompressSync(JSON.stringify(result));
			} else if (type === "deflate") {
				set.headers["content-encoding"] = "deflate";
				return Bun.deflateSync(JSON.stringify(result));
			}
		}

		return result;
	})
	.get("/async-db", async ({ query }) => {
		if (!pgPool) {
			return new Response(EMPTY_DB_JSON, {
				headers: { "content-type": "application/json" },
			});
		}
		const min = parseInt((query.min as string) ?? "", 10) || 10;
		const max = parseInt((query.max as string) ?? "", 10) || 50;
		const limit = Math.max(1, Math.min(parseInt((query.limit as string) ?? "", 10) || 50, 50));
		try {
			const result = await pgPool.query(
				"SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
				[min, max, limit],
			);
			const items = result.rows.map((r: any) => ({
				id: r.id,
				name: r.name,
				category: r.category,
				price: r.price,
				quantity: r.quantity,
				active: r.active,
				tags: r.tags,
				rating: { score: r.rating_score, count: r.rating_count },
			}));
			const body = JSON.stringify({ count: items.length, items });
			return new Response(body, {
				headers: {
					"content-type": "application/json",
					"content-length": String(Buffer.byteLength(body)),
				},
			});
		} catch (e) {
			return new Response(EMPTY_DB_JSON, {
				headers: { "content-type": "application/json" },
			});
		}
	})
	.post("/upload", async ({ request }) => {
		let size = 0;
		if (request.body) {
			for await (const chunk of request.body as any) {
				size += (chunk as Uint8Array).byteLength;
			}
		}
		return new Response(String(size), {
			headers: { "content-type": "text/plain" },
		});
	})
	.use(staticModule)
	.all("*", () => new Response("Not found", { status: 404 }))
	.listen({ port: 8080, reusePort: true });
}
