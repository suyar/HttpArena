use salvo::conn::rustls::{Keycert, RustlsConfig};
use salvo::compression::Compression;
use salvo::http::header::{self, HeaderValue};
use salvo::http::StatusCode;
use salvo::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::OnceLock;

static CRC32_TABLE: OnceLock<[[u32; 256]; 8]> = OnceLock::new();

fn init_crc32_table() -> [[u32; 256]; 8] {
    let mut tab = [[0u32; 256]; 8];
    for i in 0..256u32 {
        let mut c = i;
        for _ in 0..8 {
            c = if c & 1 != 0 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 };
        }
        tab[0][i as usize] = c;
    }
    for i in 0..256usize {
        for s in 1..8usize {
            tab[s][i] = (tab[s - 1][i] >> 8) ^ tab[0][(tab[s - 1][i] & 0xFF) as usize];
        }
    }
    tab
}

fn crc32_compute(data: &[u8]) -> u32 {
    let tab = CRC32_TABLE.get_or_init(init_crc32_table);
    let mut crc = 0xFFFFFFFFu32;
    let mut p = data;
    while p.len() >= 8 {
        let a = u32::from_le_bytes([p[0], p[1], p[2], p[3]]) ^ crc;
        let b = u32::from_le_bytes([p[4], p[5], p[6], p[7]]);
        crc = tab[7][(a & 0xFF) as usize] ^ tab[6][((a >> 8) & 0xFF) as usize]
            ^ tab[5][((a >> 16) & 0xFF) as usize] ^ tab[4][(a >> 24) as usize]
            ^ tab[3][(b & 0xFF) as usize] ^ tab[2][((b >> 8) & 0xFF) as usize]
            ^ tab[1][((b >> 16) & 0xFF) as usize] ^ tab[0][(b >> 24) as usize];
        p = &p[8..];
    }
    for &byte in p {
        crc = (crc >> 8) ^ tab[0][((crc ^ byte as u32) & 0xFF) as usize];
    }
    crc ^ 0xFFFFFFFF
}

static STATE: OnceLock<AppState> = OnceLock::new();
static SERVER_HDR: HeaderValue = HeaderValue::from_static("salvo");

struct AppState {
    json_cache: Vec<u8>,
    json_large_cache: Vec<u8>,
    static_files: HashMap<String, StaticFile>,
}

struct StaticFile {
    data: Vec<u8>,
    content_type: &'static str,
}

#[derive(Deserialize, Clone)]
struct Rating {
    score: f64,
    count: i64,
}

#[derive(Deserialize, Clone)]
struct DatasetItem {
    id: i64,
    name: String,
    category: String,
    price: f64,
    quantity: i64,
    active: bool,
    tags: Vec<String>,
    rating: Rating,
}

#[derive(Serialize)]
struct RatingOut {
    score: f64,
    count: i64,
}

#[derive(Serialize)]
struct ProcessedItem {
    id: i64,
    name: String,
    category: String,
    price: f64,
    quantity: i64,
    active: bool,
    tags: Vec<String>,
    rating: RatingOut,
    total: f64,
}

#[derive(Serialize)]
struct JsonResponse {
    items: Vec<ProcessedItem>,
    count: usize,
}

fn parse_query_sum(query: &str) -> i64 {
    let mut sum: i64 = 0;
    for pair in query.split('&') {
        if let Some(val) = pair.split('=').nth(1) {
            if let Ok(n) = val.parse::<i64>() {
                sum += n;
            }
        }
    }
    sum
}

fn get_mime(ext: &str) -> &'static str {
    match ext {
        ".css" => "text/css",
        ".js" => "application/javascript",
        ".html" => "text/html",
        ".woff2" => "font/woff2",
        ".svg" => "image/svg+xml",
        ".webp" => "image/webp",
        ".json" => "application/json",
        _ => "application/octet-stream",
    }
}

fn load_dataset() -> Vec<DatasetItem> {
    let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    match std::fs::read_to_string(&path) {
        Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

fn build_json_cache(dataset: &[DatasetItem]) -> Vec<u8> {
    let items: Vec<ProcessedItem> = dataset
        .iter()
        .map(|d| ProcessedItem {
            id: d.id,
            name: d.name.clone(),
            category: d.category.clone(),
            price: d.price,
            quantity: d.quantity,
            active: d.active,
            tags: d.tags.clone(),
            rating: RatingOut {
                score: d.rating.score,
                count: d.rating.count,
            },
            total: (d.price * d.quantity as f64 * 100.0).round() / 100.0,
        })
        .collect();
    let resp = JsonResponse {
        count: items.len(),
        items,
    };
    serde_json::to_vec(&resp).unwrap_or_default()
}

fn load_static_files() -> HashMap<String, StaticFile> {
    let mut files = HashMap::new();
    if let Ok(entries) = std::fs::read_dir("/data/static") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if let Ok(data) = std::fs::read(entry.path()) {
                let ext = name.rfind('.').map(|i| &name[i..]).unwrap_or("");
                let ct = get_mime(ext);
                files.insert(name, StaticFile { data, content_type: ct });
            }
        }
    }
    files
}

#[handler]
async fn add_server_header(res: &mut Response) {
    res.headers_mut()
        .insert(header::SERVER, SERVER_HDR.clone());
}

#[handler]
async fn pipeline(res: &mut Response) {
    res.headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    res.render("ok");
}

#[handler]
async fn baseline11_get(req: &mut Request, res: &mut Response) {
    let sum = req.uri().query().map(parse_query_sum).unwrap_or(0);
    res.headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    res.render(sum.to_string());
}

#[handler]
async fn baseline11_post(req: &mut Request, res: &mut Response) {
    let mut sum = req.uri().query().map(parse_query_sum).unwrap_or(0);
    if let Ok(body) = req.payload().await {
        if let Ok(s) = std::str::from_utf8(body) {
            if let Ok(n) = s.trim().parse::<i64>() {
                sum += n;
            }
        }
    }
    res.headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    res.render(sum.to_string());
}

#[handler]
async fn baseline2(req: &mut Request, res: &mut Response) {
    let sum = req.uri().query().map(parse_query_sum).unwrap_or(0);
    res.headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    res.render(sum.to_string());
}

#[handler]
async fn json_endpoint(res: &mut Response) {
    let state = STATE.get().unwrap();
    res.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    res.write_body(state.json_cache.clone()).ok();
}

#[handler]
async fn compression(res: &mut Response) {
    let state = STATE.get().unwrap();
    res.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    res.write_body(state.json_large_cache.clone()).ok();
}

#[handler]
async fn upload(req: &mut Request, res: &mut Response) {
    if let Ok(body) = req.payload_with_max_size(25 * 1024 * 1024).await {
        let crc = crc32_compute(body);
        res.headers_mut()
            .insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
        res.render(format!("{:08x}", crc));
    } else {
        res.status_code(StatusCode::BAD_REQUEST);
    }
}

#[handler]
async fn static_file(req: &mut Request, res: &mut Response) {
    let state = STATE.get().unwrap();
    let filename: String = req.param("filename").unwrap_or_default();
    if let Some(sf) = state.static_files.get(&filename) {
        res.headers_mut().insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static(sf.content_type),
        );
        res.write_body(sf.data.clone()).ok();
    } else {
        res.status_code(StatusCode::NOT_FOUND);
    }
}

#[tokio::main]
async fn main() {
    let dataset = load_dataset();
    let json_cache = build_json_cache(&dataset);

    let large_dataset: Vec<DatasetItem> = match std::fs::read_to_string("/data/dataset-large.json") {
        Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
        Err(_) => Vec::new(),
    };
    let json_large_cache = build_json_cache(&large_dataset);

    STATE
        .set(AppState {
            json_cache,
            json_large_cache,
            static_files: load_static_files(),
        })
        .ok();

    let router = Router::new()
        .hoop(add_server_header)
        .push(Router::with_path("pipeline").get(pipeline))
        .push(
            Router::with_path("baseline11")
                .get(baseline11_get)
                .post(baseline11_post),
        )
        .push(Router::with_path("baseline2").get(baseline2))
        .push(Router::with_path("json").get(json_endpoint))
        .push(
            Router::with_path("compression")
                .hoop(Compression::new().enable_gzip(salvo::compression::CompressionLevel::Fastest))
                .get(compression),
        )
        .push(Router::with_path("upload").post(upload))
        .push(
            Router::with_path("static").push(
                Router::with_path("{filename}").get(static_file),
            ),
        );

    let cert_path = std::env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".to_string());
    let key_path = std::env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".to_string());

    let has_tls = std::fs::metadata(&cert_path).is_ok() && std::fs::metadata(&key_path).is_ok();

    if has_tls {
        let cert = std::fs::read(&cert_path).expect("Failed to read cert");
        let key = std::fs::read(&key_path).expect("Failed to read key");
        let config = RustlsConfig::new(Keycert::new().cert(cert).key(key));

        let plain = TcpListener::new("0.0.0.0:8080");
        let tls_listener = TcpListener::new("0.0.0.0:8443").rustls(config.clone());
        let quinn_config = config
            .build_quinn_config()
            .expect("Failed to build quinn config");
        let quinn_listener = QuinnListener::new(quinn_config, "0.0.0.0:8443");

        let acceptor = quinn_listener.join(tls_listener).join(plain).bind().await;
        Server::new(acceptor).serve(router).await;
    } else {
        let acceptor = TcpListener::new("0.0.0.0:8080").bind().await;
        Server::new(acceptor).serve(router).await;
    }
}
