---
title: Implementation Guidelines
---
{{< type-rules production="Must use a standard async Postgres driver with connection pooling. Cache-aside with in-process cache and TTL &le; 1s. No pre-warming or background refresh." tuned="May use custom pool sizes, prepared statements, or alternative cache implementations." engine="No specific rules." >}}

The CRUD profile benchmarks a realistic REST API with four operations against Postgres: paginated list, cached single-item read, create (upsert), and update with cache invalidation.

**This test is for framework-type entries only** - engines (nginx, h2o, etc.) are excluded.

**Connections:** 512, 4,096

## Endpoints

### GET /crud/items — Paginated list

Accepts query parameters:
- `category` (string, default `"electronics"`) — filter by category
- `page` (integer, default `1`) — page number (1-indexed)
- `limit` (integer, default `10`, max `50`) — items per page

Executes two SQL queries:
1. `SELECT ... FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3`
2. `SELECT COUNT(*) FROM items WHERE category = $1`

Returns:
```json
{
  "items": [
    {
      "id": 42,
      "name": "Alpha Widget 42",
      "category": "electronics",
      "price": 30,
      "quantity": 5,
      "active": true,
      "tags": ["fast", "new"],
      "rating": { "score": 42, "count": 127 }
    }
  ],
  "total": 9986,
  "page": 1,
  "limit": 10
}
```

### GET /crud/items/{id} — Single item read (cached)

Reads a single item by ID. Uses in-process cache (e.g. `IMemoryCache`, `HashMap`, etc.) with absolute expiration of 1 second.

- On cache miss: query Postgres, populate cache, return item with `X-Cache: MISS` header
- On cache hit: return cached item with `X-Cache: HIT` header
- If item not found: return HTTP 404

```json
{
  "id": 1,
  "name": "Alpha Widget 1",
  "category": "electronics",
  "price": 30,
  "quantity": 5,
  "active": true,
  "tags": ["fast", "new"],
  "rating": { "score": 42, "count": 127 }
}
```

### POST /crud/items — Create item

Accepts a JSON body:
```json
{ "id": 200001, "name": "New Product", "category": "test", "price": 25, "quantity": 10 }
```

Inserts into Postgres with `ON CONFLICT (id) DO UPDATE` (upsert). Returns HTTP 201 with the created item.

### PUT /crud/items/{id} — Update item

Accepts a JSON body:
```json
{ "name": "Updated Name", "price": 30, "quantity": 5 }
```

Updates the item in Postgres and **invalidates the cache entry** for the updated ID. Returns HTTP 200 with the updated fields. Returns 404 if the item doesn't exist.

## What it measures

- **Connection pooling** — maintaining a Postgres connection pool under mixed read/write load
- **Cache-aside correctness** — cache hit/miss with TTL-based expiration and write-through invalidation
- **Query diversity** — handling paginated queries (two SQL per request), single-item lookups, inserts, and updates concurrently
- **JSON parsing and serialization** — deserializing request bodies (POST/PUT) and serializing response payloads

## Workload mix

The load generator (gcannon) rotates across 20 raw HTTP templates:

| Operation | Templates | Weight | ID distribution |
|-----------|-----------|--------|-----------------|
| List (GET /crud/items) | 8 | 40% | Fixed categories, random pages via `{RAND:1:100}` |
| Read (GET /crud/items/{id}) | 6 | 30% | Random IDs via `{RAND:1:50000}` |
| Create (POST /crud/items) | 3 | 15% | Sequential IDs via `{SEQ:100001}` |
| Update (PUT /crud/items/{id}) | 3 | 15% | Random IDs via `{RAND:1:50000}` |

## Environment variables

| Variable | Value | Description |
|----------|-------|-------------|
| `DATABASE_URL` | `postgres://bench:bench@localhost:5432/benchmark` | Postgres connection string |
| `DATABASE_MAX_CONN` | `256` | Maximum connections for pool sizing |

## Parameters

| Parameter | Value |
|-----------|-------|
| Connections | 512, 4,096 |
| Pipeline | 1 |
| CPU limit | 64 threads (cores 0-31, 64-95) |
| Duration | 10s per run |
| Runs | 3 (best taken) |
| Database | Postgres 17, 100,000 rows |
