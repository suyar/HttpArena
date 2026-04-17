---
title: Validation
---

The following checks are executed by `validate.sh` for every framework subscribed to the `crud` test. A Postgres sidecar container is started automatically before these checks run.

## List pagination

Sends `GET /crud/items?category=electronics&page=1&limit=5` and verifies:

- Exactly 5 items returned
- `total` is greater than 0
- `page` equals 1
- Every item has a nested `rating` object

## Single item read

Sends `GET /crud/items/1` and verifies the response contains `id` equal to `1`.

## Cache-aside (MISS then HIT)

Sends two consecutive `GET /crud/items/42` requests and checks the `X-Cache` response header:

- First request must return `X-Cache: MISS`
- Second request must return `X-Cache: HIT`

## Not found

Sends `GET /crud/items/999999` and verifies the response status is HTTP 404.

## Create (POST)

Sends `POST /crud/items` with body `{"id":200001,"name":"Bench Test","category":"test","price":25,"quantity":10}` and verifies:

- Response status is HTTP 201

## Read back created item

Sends `GET /crud/items/200001` and verifies the response contains `id` equal to `200001`.

## Update with cache invalidation

1. Warms the cache with `GET /crud/items/200001`
2. Sends `PUT /crud/items/200001` with updated fields and verifies HTTP 200
3. Sends `GET /crud/items/200001` and verifies `X-Cache: MISS` (cache was invalidated by the PUT)
