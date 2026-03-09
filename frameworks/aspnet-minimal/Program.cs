using System.IO.Compression;
using System.Text.Json;
using System.Security.Cryptography.X509Certificates;
using Microsoft.AspNetCore.ResponseCompression;
using Microsoft.AspNetCore.Server.Kestrel.Core;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();

var certPath = Environment.GetEnvironmentVariable("TLS_CERT") ?? "/certs/server.crt";
var keyPath = Environment.GetEnvironmentVariable("TLS_KEY") ?? "/certs/server.key";
var hasCert = File.Exists(certPath) && File.Exists(keyPath);

builder.WebHost.ConfigureKestrel(options =>
{
    // HTTP/1.1 on port 8080
    options.ListenAnyIP(8080, lo =>
    {
        lo.Protocols = HttpProtocols.Http1;
    });

    // HTTPS + HTTP/2 + HTTP/3 on port 8443
    if (hasCert)
    {
        options.ListenAnyIP(8443, lo =>
        {
            lo.Protocols = HttpProtocols.Http1AndHttp2AndHttp3;
            lo.UseHttps(X509Certificate2.CreateFromPemFile(certPath, keyPath));
        });
    }
});

builder.Services.AddResponseCompression(options =>
{
    options.EnableForHttps = true;
    options.MimeTypes = new[] { "application/json" };
    options.Providers.Add<GzipCompressionProvider>();
});
builder.Services.Configure<GzipCompressionProviderOptions>(options =>
{
    options.Level = CompressionLevel.Fastest;
});

var app = builder.Build();

app.UseResponseCompression();

app.Use(async (ctx, next) =>
{
    ctx.Response.Headers["Server"] = "aspnet-minimal";
    await next();
});

// Shared JSON options: camelCase matching for deserialization, camelCase output for serialization
var jsonOptions = new JsonSerializerOptions
{
    PropertyNameCaseInsensitive = true,
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase
};

// Load dataset at startup
var datasetPath = Environment.GetEnvironmentVariable("DATASET_PATH") ?? "/data/dataset.json";
List<DatasetItem>? datasetItems = null;
if (File.Exists(datasetPath))
{
    var json = File.ReadAllText(datasetPath);
    datasetItems = JsonSerializer.Deserialize<List<DatasetItem>>(json, jsonOptions);
}

// Load large dataset for compression endpoint
var largePath = "/data/dataset-large.json";
byte[]? largeJsonResponse = null;
if (File.Exists(largePath))
{
    var largeItems = JsonSerializer.Deserialize<List<DatasetItem>>(File.ReadAllText(largePath), jsonOptions);
    if (largeItems != null)
    {
        var responseItems = new List<ProcessedItem>(largeItems.Count);
        foreach (var item in largeItems)
        {
            responseItems.Add(new ProcessedItem
            {
                Id = item.Id, Name = item.Name, Category = item.Category,
                Price = item.Price, Quantity = item.Quantity, Active = item.Active,
                Tags = item.Tags, Rating = item.Rating,
                Total = Math.Round(item.Price * item.Quantity, 2)
            });
        }
        largeJsonResponse = JsonSerializer.SerializeToUtf8Bytes(new { items = responseItems, count = responseItems.Count }, jsonOptions);
    }
}

// Pre-load static files
var staticFileMap = new Dictionary<string, (byte[] Data, string ContentType)>();
var staticDir = "/data/static";
if (Directory.Exists(staticDir))
{
    var mimeTypes = new Dictionary<string, string>
    {
        {".css", "text/css"}, {".js", "application/javascript"}, {".html", "text/html"},
        {".woff2", "font/woff2"}, {".svg", "image/svg+xml"}, {".webp", "image/webp"}, {".json", "application/json"}
    };
    foreach (var file in Directory.GetFiles(staticDir))
    {
        var name = Path.GetFileName(file);
        var ext = Path.GetExtension(file);
        var ct = mimeTypes.GetValueOrDefault(ext, "application/octet-stream");
        staticFileMap[name] = (File.ReadAllBytes(file), ct);
    }
}

app.MapGet("/static/{filename}", (string filename) =>
{
    if (staticFileMap.TryGetValue(filename, out var sf))
        return Results.Bytes(sf.Data, sf.ContentType);
    return Results.NotFound();
});

app.MapGet("/pipeline", () => Results.Text("ok"));

app.MapGet("/baseline11", (HttpRequest req) =>
{
    int sum = SumQuery(req);
    return Results.Text(sum.ToString());
});

app.MapPost("/baseline11", async (HttpRequest req) =>
{
    int sum = SumQuery(req);

    using var reader = new StreamReader(req.Body);

    var body = await reader.ReadToEndAsync();

    if (int.TryParse(body, out int b))
        sum += b;

    return Results.Text(sum.ToString());
});

app.MapGet("/baseline2", (HttpRequest req) =>
{
    int sum = SumQuery(req);
    return Results.Text(sum.ToString());
});

app.MapPost("/upload", async (HttpRequest req) =>
{
    using var ms = new MemoryStream();
    await req.Body.CopyToAsync(ms);
    uint crc = Crc32Helper.Compute(ms.GetBuffer().AsSpan(0, (int)ms.Length));
    return Results.Text(crc.ToString("x8"));
});

app.MapGet("/json", () =>
{
    if (datasetItems == null)
        return Results.Problem("Dataset not loaded");

    var responseItems = new List<ProcessedItem>(datasetItems.Count);
    foreach (var item in datasetItems)
    {
        responseItems.Add(new ProcessedItem
        {
            Id = item.Id,
            Name = item.Name,
            Category = item.Category,
            Price = item.Price,
            Quantity = item.Quantity,
            Active = item.Active,
            Tags = item.Tags,
            Rating = item.Rating,
            Total = Math.Round(item.Price * item.Quantity, 2)
        });
    }

    return Results.Json(new { items = responseItems, count = responseItems.Count });
});

app.MapGet("/compression", async (HttpContext ctx) =>
{
    if (largeJsonResponse == null)
    {
        ctx.Response.StatusCode = 500;
        return;
    }
    ctx.Response.ContentType = "application/json";
    await ctx.Response.Body.WriteAsync(largeJsonResponse);
});

const string CachingETag = "\"AOK\"";
app.MapGet("/caching", (HttpContext ctx) =>
{
    var inm = ctx.Request.Headers.IfNoneMatch.ToString();
    ctx.Response.Headers.ETag = CachingETag;
    if (inm == CachingETag)
    {
        ctx.Response.StatusCode = 304;
        return;
    }
    ctx.Response.ContentType = "text/plain";
    ctx.Response.ContentLength = 2;
    ctx.Response.Body.Write("OK"u8);
});

app.Run();

static int SumQuery(HttpRequest req)
{
    int sum = 0;
    foreach (var (_, values) in req.Query)
        foreach (var v in values)
            if (int.TryParse(v, out int n)) sum += n;
    return sum;
}

class DatasetItem
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public double Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string> Tags { get; set; } = new();
    public RatingInfo Rating { get; set; } = new();
}

class ProcessedItem
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public double Price { get; set; }
    public int Quantity { get; set; }
    public bool Active { get; set; }
    public List<string> Tags { get; set; } = new();
    public RatingInfo Rating { get; set; } = new();
    public double Total { get; set; }
}

class RatingInfo
{
    public double Score { get; set; }
    public int Count { get; set; }
}

static class Crc32Helper
{
    private static readonly uint[][] T = new uint[8][];
    static Crc32Helper()
    {
        for (int s = 0; s < 8; s++) T[s] = new uint[256];
        for (uint i = 0; i < 256; i++)
        {
            uint c = i;
            for (int j = 0; j < 8; j++)
                c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
            T[0][i] = c;
        }
        for (uint i = 0; i < 256; i++)
            for (int s = 1; s < 8; s++)
                T[s][i] = (T[s-1][i] >> 8) ^ T[0][T[s-1][i] & 0xFF];
    }
    public static uint Compute(ReadOnlySpan<byte> data)
    {
        uint crc = 0xFFFFFFFF;
        int i = 0;
        while (i + 8 <= data.Length)
        {
            uint a = (uint)(data[i] | (data[i+1] << 8) | (data[i+2] << 16) | (data[i+3] << 24)) ^ crc;
            uint b = (uint)(data[i+4] | (data[i+5] << 8) | (data[i+6] << 16) | (data[i+7] << 24));
            crc = T[7][a & 0xFF] ^ T[6][(a >> 8) & 0xFF]
                ^ T[5][(a >> 16) & 0xFF] ^ T[4][a >> 24]
                ^ T[3][b & 0xFF] ^ T[2][(b >> 8) & 0xFF]
                ^ T[1][(b >> 16) & 0xFF] ^ T[0][b >> 24];
            i += 8;
        }
        while (i < data.Length)
            crc = (crc >> 8) ^ T[0][(crc ^ data[i++]) & 0xFF];
        return crc ^ 0xFFFFFFFF;
    }
}
