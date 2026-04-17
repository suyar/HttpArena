using System.Text.Json;
using System.Buffers;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.Extensions.Caching.Memory;


[JsonSerializable(typeof(ResponseDto<ProcessedItem>))]
[JsonSerializable(typeof(ResponseDto<DbResponseItemDto>))]
[JsonSerializable(typeof(DbResponseItemDto))]
[JsonSerializable(typeof(ProcessedItem))]
[JsonSerializable(typeof(RatingInfo))]
[JsonSerializable(typeof(List<string>))]
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
partial class AppJsonContext : JsonSerializerContext { }

static class Handlers
{
    public static int Sum(int a, int b) => a + b;

    public static async ValueTask<int> SumBody(int a, int b, HttpRequest req)
    {
        using var reader = new StreamReader(req.Body);
        return a + b + int.Parse(await reader.ReadToEndAsync());
    }

    public static string Text() => "ok";

    public static async ValueTask<string> Upload(HttpRequest req)
    {
        long size = 0;
        var buffer = ArrayPool<byte>.Shared.Rent(65536);
        try
        {
            int read;
            while ((read = await req.Body.ReadAsync(buffer.AsMemory(0, buffer.Length))) > 0)
            {
                size += read;
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }

        return size.ToString();
    }

    public static Results<JsonHttpResult<ResponseDto<ProcessedItem>>, ProblemHttpResult> Json(int count, HttpRequest req)
    {
        var source = AppData.DatasetItems;
        if (source == null)
            return TypedResults.Problem("Dataset not loaded");

        if (count > source.Count) count = source.Count;
        if (count < 0) count = 0;

        int m = 1;
        if (req.Query.TryGetValue("m", out var mVal) && int.TryParse(mVal, out var pm)) m = pm;

        var items = new ProcessedItem[count];

        for (int i = 0; i < count; i++)
        {
            var item = source[i];
            items[i] = new ProcessedItem
            {
                Id = item.Id,
                Name = item.Name,
                Category = item.Category,
                Price = item.Price,
                Quantity = item.Quantity,
                Active = item.Active,
                Tags = item.Tags,
                Rating = item.Rating,
                Total = item.Price * item.Quantity * m
            };
        }

        return TypedResults.Json(new ResponseDto<ProcessedItem>(items, count), AppJsonContext.Default.ResponseDtoProcessedItem);
    }

    public static async Task<Results<JsonHttpResult<ResponseDto<DbResponseItemDto>>, ProblemHttpResult>> AsyncDatabase(HttpRequest req)
    {
        if (AppData.PgDataSource == null)
            return TypedResults.Problem("DB not available");

        // Query Parsing
        double min = 10, max = 50;
        int limit = 50;
        var query = req.Query;
        if (query.TryGetValue("min", out var minVal) && double.TryParse(minVal, out var pmin)) min = pmin;
        if (query.TryGetValue("max", out var maxVal) && double.TryParse(maxVal, out var pmax)) max = pmax;
        if (query.TryGetValue("limit", out var limVal) && int.TryParse(limVal, out var plim)) limit = Math.Clamp(plim, 1, 50);

        await using var cmd = AppData.PgDataSource.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3");
        
        cmd.Parameters.AddWithValue(min);
        cmd.Parameters.AddWithValue(max);
        cmd.Parameters.AddWithValue(limit);

        await using var reader = await cmd.ExecuteReaderAsync();

        var items = new List<DbResponseItemDto>(limit);

        while (await reader.ReadAsync())
        {
            items.Add(new DbResponseItemDto
            {
                Id = reader.GetInt32(0),
                Name = reader.GetString(1),
                Category = reader.GetString(2),
                Price = (int)reader.GetDouble(3),
                Quantity = reader.GetInt32(4),
                Active = reader.GetBoolean(5),
                Tags = JsonSerializer.Deserialize(reader.GetString(6), AppJsonContext.Default.ListString)!,
                Rating = new RatingInfo { Score = (int)reader.GetDouble(7), Count = reader.GetInt32(8) }
            });
        }

        return TypedResults.Json(new ResponseDto<DbResponseItemDto>(items, items.Count), AppJsonContext.Default.ResponseDtoDbResponseItemDto);
    }

    // ── CRUD handlers ──────────────────────────────────────────────────
    //
    // Realistic REST API with paginated list, cached single-item read,
    // create, and update. In-process IMemoryCache with 1s TTL on single-
    // item reads, invalidated on PUT. List queries always hit Postgres
    // (two queries: data + count).

    private static readonly MemoryCacheEntryOptions _crudCacheOpts =
        new() { AbsoluteExpirationRelativeToNow = TimeSpan.FromSeconds(1) };

    private static readonly JsonSerializerOptions _crudJsonOpts =
        new(JsonSerializerDefaults.Web);

    // GET /crud/items?category=X&page=N&limit=M — paginated list (always DB, never cached)
    public static async Task<IResult> CrudList(HttpRequest req)
    {
        if (AppData.PgDataSource is null)
            return TypedResults.Problem("DB not available");

        var query = req.Query;
        var category = query["category"].ToString();
        if (string.IsNullOrEmpty(category)) category = "electronics";
        int.TryParse(query["page"], out var page);
        if (page < 1) page = 1;
        int.TryParse(query["limit"], out var limit);
        if (limit < 1 || limit > 50) limit = 10;
        var offset = (page - 1) * limit;

        // Query 1: data
        await using var cmd = AppData.PgDataSource.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
            "FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3");
        cmd.Parameters.AddWithValue(category);
        cmd.Parameters.AddWithValue(limit);
        cmd.Parameters.AddWithValue(offset);

        await using var reader = await cmd.ExecuteReaderAsync();
        var items = new List<object>();
        while (await reader.ReadAsync())
        {
            items.Add(new
            {
                id       = reader.GetInt32(0),
                name     = reader.GetString(1),
                category = reader.GetString(2),
                price    = reader.GetInt32(3),
                quantity = reader.GetInt32(4),
                active   = reader.GetBoolean(5),
                tags     = JsonSerializer.Deserialize<List<string>>(reader.GetString(6), AppJsonContext.Default.ListString)!,
                rating   = new RatingInfo { Score = (int)reader.GetDouble(7), Count = reader.GetInt32(8) }
            });
        }
        await reader.CloseAsync();

        // Query 2: total count
        await using var countCmd = AppData.PgDataSource.CreateCommand(
            "SELECT COUNT(*) FROM items WHERE category = $1");
        countCmd.Parameters.AddWithValue(category);
        var total = (long)(await countCmd.ExecuteScalarAsync())!;

        return TypedResults.Ok(new { items, total, page, limit });
    }

    // GET /crud/items/{id} — single item, cached with 1s TTL
    public static async Task<IResult> CrudRead(int id, IMemoryCache cache, HttpContext ctx)
    {
        if (AppData.PgDataSource is null)
            return TypedResults.Problem("DB not available");

        var cacheKey = $"crud:{id}";
        if (cache.TryGetValue(cacheKey, out object? cached))
        {
            ctx.Response.Headers["X-Cache"] = "HIT";
            return TypedResults.Ok(cached);
        }

        await using var cmd = AppData.PgDataSource.CreateCommand(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
            "FROM items WHERE id = $1 LIMIT 1");
        cmd.Parameters.AddWithValue(id);

        await using var reader = await cmd.ExecuteReaderAsync();
        if (!await reader.ReadAsync())
            return TypedResults.NotFound();

        var item = new
        {
            id       = reader.GetInt32(0),
            name     = reader.GetString(1),
            category = reader.GetString(2),
            price    = reader.GetInt32(3),
            quantity = reader.GetInt32(4),
            active   = reader.GetBoolean(5),
            tags     = JsonSerializer.Deserialize<List<string>>(reader.GetString(6), AppJsonContext.Default.ListString)!,
            rating   = new RatingInfo { Score = (int)reader.GetDouble(7), Count = reader.GetInt32(8) }
        };

        cache.Set(cacheKey, item, _crudCacheOpts);
        ctx.Response.Headers["X-Cache"] = "MISS";
        return TypedResults.Ok(item);
    }

    // POST /crud/items — create item, return 201
    public static async Task<IResult> CrudCreate(HttpRequest req)
    {
        if (AppData.PgDataSource is null)
            return TypedResults.Problem("DB not available");

        using var sr = new StreamReader(req.Body);
        var body = await sr.ReadToEndAsync();
        var input = JsonSerializer.Deserialize<CrudItemInput>(body, _crudJsonOpts);
        if (input is null)
            return TypedResults.BadRequest();

        await using var cmd = AppData.PgDataSource.CreateCommand(
            "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) " +
            "VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0) " +
            "ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 " +
            "RETURNING id");
        cmd.Parameters.AddWithValue(input.Id);
        cmd.Parameters.AddWithValue(input.Name ?? "New Product");
        cmd.Parameters.AddWithValue(input.Category ?? "test");
        cmd.Parameters.AddWithValue(input.Price);
        cmd.Parameters.AddWithValue(input.Quantity);

        var newId = (int)(await cmd.ExecuteScalarAsync())!;
        return TypedResults.Created($"/crud/items/{newId}", new { id = newId, name = input.Name, category = input.Category, price = input.Price, quantity = input.Quantity });
    }

    // PUT /crud/items/{id} — update item, invalidate cache
    public static async Task<IResult> CrudUpdate(int id, HttpRequest req, IMemoryCache cache)
    {
        if (AppData.PgDataSource is null)
            return TypedResults.Problem("DB not available");

        using var sr = new StreamReader(req.Body);
        var body = await sr.ReadToEndAsync();
        var input = JsonSerializer.Deserialize<CrudItemInput>(body, _crudJsonOpts);
        if (input is null)
            return TypedResults.BadRequest();

        await using var cmd = AppData.PgDataSource.CreateCommand(
            "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4");
        cmd.Parameters.AddWithValue(input.Name ?? "Updated");
        cmd.Parameters.AddWithValue(input.Price);
        cmd.Parameters.AddWithValue(input.Quantity);
        cmd.Parameters.AddWithValue(id);

        var affected = await cmd.ExecuteNonQueryAsync();
        if (affected == 0) return TypedResults.NotFound();

        cache.Remove($"crud:{id}");
        return TypedResults.Ok(new { id, name = input.Name, price = input.Price, quantity = input.Quantity });
    }
}

record CrudItemInput(int Id, string? Name, string? Category, int Price, int Quantity);