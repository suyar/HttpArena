use actix_web::http::header::{ContentType, HeaderValue, SERVER};
use actix_web::{web, App, HttpRequest, HttpResponse, HttpServer};
use rustls::ServerConfig;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io;
use std::sync::Arc;

static SERVER_HDR: HeaderValue = HeaderValue::from_static("actix");

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

struct StaticFile {
    data: Vec<u8>,
    content_type: String,
}

struct AppState {
    dataset: Vec<DatasetItem>,
    json_large_cache: Vec<u8>,
    static_files: HashMap<String, StaticFile>,
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
    let mime_types: HashMap<&str, &str> = [
        (".css", "text/css"),
        (".js", "application/javascript"),
        (".html", "text/html"),
        (".woff2", "font/woff2"),
        (".svg", "image/svg+xml"),
        (".webp", "image/webp"),
        (".json", "application/json"),
    ]
    .into();
    let mut files = HashMap::new();
    if let Ok(entries) = std::fs::read_dir("/data/static") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if let Ok(data) = std::fs::read(entry.path()) {
                let ext = name.rfind('.').map(|i| &name[i..]).unwrap_or("");
                let ct = mime_types.get(ext).unwrap_or(&"application/octet-stream");
                files.insert(
                    name,
                    StaticFile {
                        data,
                        content_type: ct.to_string(),
                    },
                );
            }
        }
    }
    files
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

async fn pipeline() -> HttpResponse {
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::plaintext())
        .body("ok")
}

async fn baseline11_get(req: HttpRequest) -> HttpResponse {
    let sum = req
        .uri()
        .query()
        .map(parse_query_sum)
        .unwrap_or(0);
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::plaintext())
        .body(sum.to_string())
}

fn crc32_compute(data: &[u8]) -> u32 {
    static TABLE: std::sync::OnceLock<[[u32; 256]; 8]> = std::sync::OnceLock::new();
    let t = TABLE.get_or_init(|| {
        let mut t = [[0u32; 256]; 8];
        for i in 0..256u32 {
            let mut c = i;
            for _ in 0..8 { c = if c & 1 != 0 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 }; }
            t[0][i as usize] = c;
        }
        for i in 0..256 {
            for s in 1..8 { t[s][i] = (t[s-1][i] >> 8) ^ t[0][(t[s-1][i] & 0xFF) as usize]; }
        }
        t
    });
    let mut crc = 0xFFFFFFFFu32;
    let mut i = 0;
    while i + 8 <= data.len() {
        let a = u32::from_le_bytes([data[i], data[i+1], data[i+2], data[i+3]]) ^ crc;
        let b = u32::from_le_bytes([data[i+4], data[i+5], data[i+6], data[i+7]]);
        crc = t[7][(a & 0xFF) as usize] ^ t[6][((a >> 8) & 0xFF) as usize]
            ^ t[5][((a >> 16) & 0xFF) as usize] ^ t[4][(a >> 24) as usize]
            ^ t[3][(b & 0xFF) as usize] ^ t[2][((b >> 8) & 0xFF) as usize]
            ^ t[1][((b >> 16) & 0xFF) as usize] ^ t[0][(b >> 24) as usize];
        i += 8;
    }
    while i < data.len() { crc = (crc >> 8) ^ t[0][((crc ^ data[i] as u32) & 0xFF) as usize]; i += 1; }
    crc ^ 0xFFFFFFFF
}

async fn upload(body: web::Bytes) -> HttpResponse {
    let crc = crc32_compute(&body);
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::plaintext())
        .body(format!("{:08x}", crc))
}

async fn baseline11_post(req: HttpRequest, body: web::Bytes) -> HttpResponse {
    let mut sum = req
        .uri()
        .query()
        .map(parse_query_sum)
        .unwrap_or(0);
    if let Ok(s) = std::str::from_utf8(&body) {
        if let Ok(n) = s.trim().parse::<i64>() {
            sum += n;
        }
    }
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::plaintext())
        .body(sum.to_string())
}

async fn baseline2(req: HttpRequest) -> HttpResponse {
    let sum = req
        .uri()
        .query()
        .map(parse_query_sum)
        .unwrap_or(0);
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::plaintext())
        .body(sum.to_string())
}

async fn json_endpoint(state: web::Data<Arc<AppState>>) -> HttpResponse {
    if state.dataset.is_empty() {
        return HttpResponse::InternalServerError().body("No dataset");
    }
    let items: Vec<ProcessedItem> = state.dataset.iter().map(|d| ProcessedItem {
        id: d.id,
        name: d.name.clone(),
        category: d.category.clone(),
        price: d.price,
        quantity: d.quantity,
        active: d.active,
        tags: d.tags.clone(),
        rating: RatingOut { score: d.rating.score, count: d.rating.count },
        total: (d.price * d.quantity as f64 * 100.0).round() / 100.0,
    }).collect();
    let resp = JsonResponse { count: items.len(), items };
    let body = serde_json::to_vec(&resp).unwrap_or_default();
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::json())
        .body(body)
}

async fn compression(state: web::Data<Arc<AppState>>) -> HttpResponse {
    HttpResponse::Ok()
        .insert_header(("Content-Type", "application/json"))
        .insert_header(("Server", "actix"))
        .body(state.json_large_cache.clone())
}

async fn static_file(
    state: web::Data<Arc<AppState>>,
    path: web::Path<String>,
) -> HttpResponse {
    let filename = path.into_inner();
    if let Some(sf) = state.static_files.get(&filename) {
        HttpResponse::Ok()
            .insert_header((SERVER, SERVER_HDR.clone()))
            .insert_header(("content-type", sf.content_type.as_str()))
            .body(sf.data.clone())
    } else {
        HttpResponse::NotFound().finish()
    }
}

fn load_tls_config() -> Option<ServerConfig> {
    let cert_path = std::env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".to_string());
    let key_path = std::env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".to_string());
    let cert_file = std::fs::File::open(&cert_path).ok()?;
    let key_file = std::fs::File::open(&key_path).ok()?;
    let certs: Vec<_> = rustls_pemfile::certs(&mut io::BufReader::new(cert_file))
        .filter_map(|r| r.ok())
        .collect();
    let key = rustls_pemfile::private_key(&mut io::BufReader::new(key_file)).ok()??;
    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .ok()?;
    config.alpn_protocols = vec![b"h2".to_vec()];
    Some(config)
}

#[actix_web::main]
async fn main() -> io::Result<()> {
    let dataset = load_dataset();

    let large_dataset: Vec<DatasetItem> = match std::fs::read_to_string("/data/dataset-large.json") {
        Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
        Err(_) => Vec::new(),
    };
    let json_large_cache = build_json_cache(&large_dataset);

    let state = Arc::new(AppState {
        dataset,
        json_large_cache,
        static_files: load_static_files(),
    });

    let tls_config = load_tls_config();
    let workers = num_cpus::get();

    let mut server = HttpServer::new({
        let state = state.clone();
        move || {
            App::new()
                .wrap(actix_web::middleware::Compress::default())
                .app_data(web::Data::new(state.clone()))
                .app_data(web::PayloadConfig::new(25 * 1024 * 1024))
                .route("/pipeline", web::get().to(pipeline))
                .route("/baseline11", web::get().to(baseline11_get))
                .route("/baseline11", web::post().to(baseline11_post))
                .route("/baseline2", web::get().to(baseline2))
                .route("/json", web::get().to(json_endpoint))
                .route("/compression", web::get().to(compression))
                .route("/upload", web::post().to(upload))
                .route("/static/{filename}", web::get().to(static_file))
        }
    })
    .workers(workers)
    .backlog(4096)
    .bind("0.0.0.0:8080")?;

    if let Some(tls_cfg) = tls_config {
        server = server.bind_rustls_0_23("0.0.0.0:8443", tls_cfg)?;
    }

    server.run().await
}
