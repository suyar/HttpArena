package com.httparena;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.smallrye.common.annotation.NonBlocking;
import io.vertx.core.buffer.Buffer;
import jakarta.annotation.PostConstruct;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

@Path("/")
public class BenchmarkResource {

    private static final Buffer OK_BUFFER = Buffer.buffer("ok".getBytes(StandardCharsets.UTF_8));

    private final ObjectMapper mapper = new ObjectMapper();
    private List<Map<String, Object>> dataset;
    private byte[] largeJsonResponse;
    private final Map<String, byte[]> staticFiles = new ConcurrentHashMap<>();
    private static final Map<String, String> MIME_TYPES = Map.ofEntries(
        Map.entry(".css", "text/css"),
        Map.entry(".js", "application/javascript"),
        Map.entry(".html", "text/html"),
        Map.entry(".woff2", "font/woff2"),
        Map.entry(".svg", "image/svg+xml"),
        Map.entry(".webp", "image/webp"),
        Map.entry(".json", "application/json")
    );

    @PostConstruct
    public void init() throws IOException {
        String path = System.getenv("DATASET_PATH");
        if (path == null) path = "/data/dataset.json";
        File f = new File(path);
        if (f.exists()) {
            dataset = mapper.readValue(f, new TypeReference<>() {});
        }
        File largef = new File("/data/dataset-large.json");
        if (largef.exists()) {
            List<Map<String, Object>> largeDataset = mapper.readValue(largef, new TypeReference<>() {});
            List<Map<String, Object>> largeItems = new ArrayList<>(largeDataset.size());
            for (Map<String, Object> item : largeDataset) {
                Map<String, Object> processed = new LinkedHashMap<>(item);
                double price = ((Number) item.get("price")).doubleValue();
                int quantity = ((Number) item.get("quantity")).intValue();
                processed.put("total", Math.round(price * quantity * 100.0) / 100.0);
                largeItems.add(processed);
            }
            largeJsonResponse = mapper.writeValueAsBytes(Map.of("items", largeItems, "count", largeItems.size()));
        }
        // Pre-load static files
        File staticDir = new File("/data/static");
        if (staticDir.isDirectory()) {
            File[] files = staticDir.listFiles();
            if (files != null) {
                for (File sf : files) {
                    if (sf.isFile()) {
                        try {
                            staticFiles.put(sf.getName(), Files.readAllBytes(sf.toPath()));
                        } catch (IOException ignored) {}
                    }
                }
            }
        }
    }

    @GET
    @Path("/pipeline")
    @Produces(MediaType.TEXT_PLAIN)
    @NonBlocking
    public Buffer pipeline() {
        return OK_BUFFER;
    }

    @GET
    @Path("/baseline11")
    @Produces(MediaType.TEXT_PLAIN)
    @NonBlocking
    public String baselineGet(@QueryParam("a") String a, @QueryParam("b") String b) {
        return String.valueOf(sumParams(a, b));
    }

    @POST
    @Path("/baseline11")
    @Consumes(MediaType.TEXT_PLAIN)
    @Produces(MediaType.TEXT_PLAIN)
    @NonBlocking
    public String baselinePost(@QueryParam("a") String a, @QueryParam("b") String b, String body) {
        int sum = sumParams(a, b);
        try {
            sum += Integer.parseInt(body.trim());
        } catch (NumberFormatException ignored) {}
        return String.valueOf(sum);
    }

    @POST
    @Path("/upload")
    @Produces(MediaType.TEXT_PLAIN)
    @NonBlocking
    public String upload(byte[] body) {
        java.util.zip.CRC32 crc = new java.util.zip.CRC32();
        crc.update(body);
        return String.format("%08x", crc.getValue());
    }

    @GET
    @Path("/baseline2")
    @Produces(MediaType.TEXT_PLAIN)
    @NonBlocking
    public String baseline2(@QueryParam("a") String a, @QueryParam("b") String b) {
        return String.valueOf(sumParams(a, b));
    }

    @GET
    @Path("/json")
    @Produces(MediaType.APPLICATION_JSON)
    @NonBlocking
    public Map<String, Object> json() {
        List<Map<String, Object>> items = new ArrayList<>(dataset.size());
        for (Map<String, Object> item : dataset) {
            Map<String, Object> processed = new LinkedHashMap<>(item);
            double price = ((Number) item.get("price")).doubleValue();
            int quantity = ((Number) item.get("quantity")).intValue();
            processed.put("total", Math.round(price * quantity * 100.0) / 100.0);
            items.add(processed);
        }
        return Map.of("items", items, "count", items.size());
    }

    @GET
    @Path("/compression")
    @Produces(MediaType.APPLICATION_JSON)
    @NonBlocking
    public byte[] compression() {
        return largeJsonResponse;
    }

    private static final String CACHING_ETAG = "\"AOK\"";

    @GET
    @Path("/caching")
    @NonBlocking
    public jakarta.ws.rs.core.Response caching(@HeaderParam("If-None-Match") String ifNoneMatch) {
        if (CACHING_ETAG.equals(ifNoneMatch)) {
            return jakarta.ws.rs.core.Response.notModified().header("ETag", CACHING_ETAG).build();
        }
        return jakarta.ws.rs.core.Response.ok("OK", MediaType.TEXT_PLAIN).header("ETag", CACHING_ETAG).build();
    }

    @GET
    @Path("/static/{filename}")
    @NonBlocking
    public jakarta.ws.rs.core.Response staticFile(@PathParam("filename") String filename) {
        byte[] data = staticFiles.get(filename);
        if (data == null) {
            return jakarta.ws.rs.core.Response.status(404).build();
        }
        int dot = filename.lastIndexOf('.');
        String ext = dot >= 0 ? filename.substring(dot) : "";
        String ct = MIME_TYPES.getOrDefault(ext, "application/octet-stream");
        return jakarta.ws.rs.core.Response.ok(data).header("Content-Type", ct).build();
    }

    private int sumParams(String a, String b) {
        int sum = 0;
        if (a != null) try { sum += Integer.parseInt(a); } catch (NumberFormatException ignored) {}
        if (b != null) try { sum += Integer.parseInt(b); } catch (NumberFormatException ignored) {}
        return sum;
    }
}
