package com.httparena;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.annotation.PostConstruct;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.*;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

@RestController
public class BenchmarkController {

    private final ObjectMapper mapper = new ObjectMapper();
    private List<Map<String, Object>> dataset;
    private byte[] largeJsonResponse;
    private final Map<String, byte[]> staticFiles = new ConcurrentHashMap<>();
    private static final Map<String, String> MIME_TYPES = Map.of(
        ".css", "text/css", ".js", "application/javascript", ".html", "text/html",
        ".woff2", "font/woff2", ".svg", "image/svg+xml", ".webp", "image/webp", ".json", "application/json"
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

    @GetMapping(value = "/pipeline", produces = MediaType.TEXT_PLAIN_VALUE)
    public String pipeline() {
        return "ok";
    }

    @GetMapping(value = "/baseline11", produces = MediaType.TEXT_PLAIN_VALUE)
    public String baselineGet(@RequestParam Map<String, String> params) {
        return String.valueOf(sumParams(params));
    }

    @PostMapping(value = "/baseline11", produces = MediaType.TEXT_PLAIN_VALUE)
    public String baselinePost(@RequestParam Map<String, String> params, @RequestBody String body) {
        int sum = sumParams(params);
        try {
            sum += Integer.parseInt(body.trim());
        } catch (NumberFormatException ignored) {}
        return String.valueOf(sum);
    }

    @GetMapping(value = "/baseline2", produces = MediaType.TEXT_PLAIN_VALUE)
    public String baseline2(@RequestParam Map<String, String> params) {
        return String.valueOf(sumParams(params));
    }

    @GetMapping(value = "/compression", produces = MediaType.APPLICATION_JSON_VALUE)
    public byte[] compression() {
        return largeJsonResponse;
    }

    @GetMapping(value = "/json", produces = MediaType.APPLICATION_JSON_VALUE)
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

    private static final String CACHING_ETAG = "\"AOK\"";

    @GetMapping("/caching")
    public org.springframework.http.ResponseEntity<String> caching(
            @RequestHeader(value = "If-None-Match", required = false) String ifNoneMatch) {
        if (CACHING_ETAG.equals(ifNoneMatch)) {
            return org.springframework.http.ResponseEntity.status(304)
                .header("ETag", CACHING_ETAG).build();
        }
        return org.springframework.http.ResponseEntity.ok()
            .header("ETag", CACHING_ETAG)
            .contentType(MediaType.TEXT_PLAIN)
            .body("OK");
    }

    @GetMapping("/static/{filename}")
    public org.springframework.http.ResponseEntity<byte[]> staticFile(@PathVariable String filename) {
        byte[] data = staticFiles.get(filename);
        if (data == null) {
            return org.springframework.http.ResponseEntity.notFound().build();
        }
        int dot = filename.lastIndexOf('.');
        String ext = dot >= 0 ? filename.substring(dot) : "";
        String ct = MIME_TYPES.getOrDefault(ext, "application/octet-stream");
        return org.springframework.http.ResponseEntity.ok()
            .header("Content-Type", ct)
            .body(data);
    }

    private int sumParams(Map<String, String> params) {
        int sum = 0;
        for (String v : params.values()) {
            try {
                sum += Integer.parseInt(v);
            } catch (NumberFormatException ignored) {}
        }
        return sum;
    }
}
