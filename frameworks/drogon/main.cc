#include <drogon/drogon.h>
#include <dirent.h>
#include <fstream>
#include <sstream>
#include <cmath>
#include <unistd.h>

using namespace drogon;

static uint32_t crc32_tab[8][256];
static void crc32_init() {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int j = 0; j < 8; j++) c = (c >> 1) ^ (0xEDB88320 & (-(c & 1)));
        crc32_tab[0][i] = c;
    }
    for (uint32_t i = 0; i < 256; i++)
        for (int s = 1; s < 8; s++)
            crc32_tab[s][i] = (crc32_tab[s-1][i] >> 8) ^ crc32_tab[0][crc32_tab[s-1][i] & 0xFF];
}
static uint32_t crc32_compute(const void *data, size_t len) {
    uint32_t crc = 0xFFFFFFFF;
    const uint8_t *p = (const uint8_t *)data;
    while (len >= 8) {
        uint32_t a = *(const uint32_t *)p ^ crc;
        uint32_t b = *(const uint32_t *)(p + 4);
        crc = crc32_tab[7][a & 0xFF] ^ crc32_tab[6][(a >> 8) & 0xFF]
            ^ crc32_tab[5][(a >> 16) & 0xFF] ^ crc32_tab[4][(a >> 24)]
            ^ crc32_tab[3][b & 0xFF] ^ crc32_tab[2][(b >> 8) & 0xFF]
            ^ crc32_tab[1][(b >> 16) & 0xFF] ^ crc32_tab[0][(b >> 24)];
        p += 8; len -= 8;
    }
    while (len--) crc = (crc >> 8) ^ crc32_tab[0][(crc ^ *p++) & 0xFF];
    return crc ^ 0xFFFFFFFF;
}

static Json::Value dataset_root;
static std::string json_large_response;

struct StaticFile {
    std::string data;
    std::string content_type;
};
static std::unordered_map<std::string, StaticFile> static_files;

static void loadDataset()
{
    const char *path = getenv("DATASET_PATH");
    if (!path) path = "/data/dataset.json";
    std::ifstream f(path);
    if (!f.is_open()) return;

    std::stringstream ss;
    ss << f.rdbuf();
    f.close();

    Json::CharReaderBuilder rb;
    std::string errs;
    std::istringstream is(ss.str());
    Json::parseFromStream(rb, is, &dataset_root, &errs);
}

static void loadDatasetLarge()
{
    const char *path = "/data/dataset-large.json";
    std::ifstream f(path);
    if (!f.is_open()) return;

    std::stringstream ss;
    ss << f.rdbuf();
    f.close();

    Json::CharReaderBuilder rb;
    Json::Value root;
    std::string errs;
    std::istringstream is(ss.str());
    if (!Json::parseFromStream(rb, is, &root, &errs) || !root.isArray()) return;

    Json::Value resp;
    Json::Value items(Json::arrayValue);
    for (const auto &d : root) {
        Json::Value item;
        item["id"] = d["id"];
        item["name"] = d["name"];
        item["category"] = d["category"];
        item["price"] = d["price"];
        item["quantity"] = d["quantity"];
        item["active"] = d["active"];
        item["tags"] = d["tags"];
        item["rating"] = d["rating"];
        double price = d["price"].asDouble();
        int qty = d["quantity"].asInt();
        item["total"] = std::round(price * qty * 100.0) / 100.0;
        items.append(std::move(item));
    }
    resp["items"] = std::move(items);
    resp["count"] = static_cast<int>(root.size());

    Json::StreamWriterBuilder wb;
    wb["indentation"] = "";
    json_large_response = Json::writeString(wb, resp);
}

static void loadStaticFiles()
{
    static const std::unordered_map<std::string, std::string> mime = {
        {".css","text/css"},{".js","application/javascript"},{".html","text/html"},
        {".woff2","font/woff2"},{".svg","image/svg+xml"},{".webp","image/webp"},{".json","application/json"}
    };
    DIR *d = opendir("/data/static");
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != nullptr) {
        if (e->d_type != DT_REG) continue;
        std::string name(e->d_name);
        std::string fpath = "/data/static/" + name;
        std::ifstream f(fpath, std::ios::binary);
        if (!f) continue;
        std::ostringstream ss;
        ss << f.rdbuf();
        auto dot = name.rfind('.');
        std::string ext = dot != std::string::npos ? name.substr(dot) : "";
        auto it = mime.find(ext);
        std::string ct = it != mime.end() ? it->second : "application/octet-stream";
        static_files[name] = {ss.str(), ct};
    }
    closedir(d);
}

static int64_t sumQuery(const HttpRequestPtr &req)
{
    int64_t sum = 0;
    for (auto &[k, v] : req->parameters()) {
        try { sum += std::stoll(v); } catch (...) {}
    }
    return sum;
}

int main()
{
    crc32_init();
    loadDataset();
    loadDatasetLarge();
    loadStaticFiles();

    // Register sync advice for fastest dispatch (bypasses controller pipeline)
    app().registerSyncAdvice(
        [](const HttpRequestPtr &req) -> HttpResponsePtr {
            if (req->method() != Get && req->method() != Post)
                return {};

            const auto &path = req->path();

            if (path == "/pipeline") {
                auto resp = HttpResponse::newHttpResponse();
                resp->setBody("ok");
                resp->setContentTypeCode(CT_TEXT_PLAIN);
                resp->addHeader("Server", "drogon");
                return resp;
            }

            if (path == "/json") {
                if (dataset_root.isArray() && dataset_root.size() > 0) {
                    Json::Value resp;
                    Json::Value items(Json::arrayValue);
                    for (const auto &d : dataset_root) {
                        Json::Value item;
                        item["id"] = d["id"];
                        item["name"] = d["name"];
                        item["category"] = d["category"];
                        item["price"] = d["price"];
                        item["quantity"] = d["quantity"];
                        item["active"] = d["active"];
                        item["tags"] = d["tags"];
                        item["rating"] = d["rating"];
                        double price = d["price"].asDouble();
                        int qty = d["quantity"].asInt();
                        item["total"] = std::round(price * qty * 100.0) / 100.0;
                        items.append(std::move(item));
                    }
                    resp["items"] = std::move(items);
                    resp["count"] = static_cast<int>(dataset_root.size());
                    Json::StreamWriterBuilder wb;
                    wb["indentation"] = "";
                    auto httpResp = HttpResponse::newHttpResponse();
                    httpResp->setBody(Json::writeString(wb, resp));
                    httpResp->setContentTypeCode(CT_APPLICATION_JSON);
                    httpResp->addHeader("Server", "drogon");
                    return httpResp;
                }
                auto resp = HttpResponse::newHttpResponse();
                resp->setStatusCode(k500InternalServerError);
                resp->setBody("No dataset");
                return resp;
            }

            if (path == "/compression") {
                if (!json_large_response.empty()) {
                    auto resp = HttpResponse::newHttpResponse();
                    resp->setBody(json_large_response);
                    resp->setContentTypeCode(CT_APPLICATION_JSON);
                    resp->addHeader("Server", "drogon");
                    return resp;
                }
                auto resp = HttpResponse::newHttpResponse();
                resp->setStatusCode(k500InternalServerError);
                resp->setBody("No dataset");
                return resp;
            }

            if (path == "/baseline2") {
                int64_t sum = sumQuery(req);
                auto resp = HttpResponse::newHttpResponse();
                resp->setBody(std::to_string(sum));
                resp->setContentTypeCode(CT_TEXT_PLAIN);
                resp->addHeader("Server", "drogon");
                return resp;
            }

            if (path == "/upload" && req->method() == Post) {
                const auto &body = req->body();
                uint32_t crc = crc32_compute(body.data(), body.size());
                char buf[16];
                snprintf(buf, sizeof(buf), "%08x", crc);
                auto resp = HttpResponse::newHttpResponse();
                resp->setBody(std::string(buf));
                resp->setContentTypeCode(CT_TEXT_PLAIN);
                resp->addHeader("Server", "drogon");
                return resp;
            }

            if (path == "/baseline11") {
                int64_t sum = sumQuery(req);
                if (req->method() == Post) {
                    const auto &body = req->body();
                    if (!body.empty()) {
                        try { sum += std::stoll(std::string(body)); } catch (...) {}
                    }
                }
                auto resp = HttpResponse::newHttpResponse();
                resp->setBody(std::to_string(sum));
                resp->setContentTypeCode(CT_TEXT_PLAIN);
                resp->addHeader("Server", "drogon");
                return resp;
            }

            if (path.size() > 8 && path.substr(0, 8) == "/static/") {
                auto it = static_files.find(path.substr(8));
                if (it != static_files.end()) {
                    auto resp = HttpResponse::newHttpResponse();
                    resp->setBody(it->second.data);
                    resp->addHeader("Content-Type", it->second.content_type);
                    resp->addHeader("Server", "drogon");
                    return resp;
                }
                auto resp = HttpResponse::newHttpResponse();
                resp->setStatusCode(k404NotFound);
                return resp;
            }

            return {};
        });

    app().setLogLevel(trantor::Logger::kWarn);
    app().setThreadNum(0); // auto-detect CPU cores
    app().setClientMaxBodySize(25 * 1024 * 1024);
    app().setIdleConnectionTimeout(0);
    app().setKeepaliveRequestsNumber(0);
    app().setGzipStatic(false);
    app().setServerHeaderField("drogon");
    app().addListener("0.0.0.0", 8080);

    // HTTPS/H2 on port 8443
    const char *cert = getenv("TLS_CERT");
    const char *key = getenv("TLS_KEY");
    if (!cert) cert = "/certs/server.crt";
    if (!key) key = "/certs/server.key";
    if (access(cert, R_OK) == 0 && access(key, R_OK) == 0)
        app().addListener("0.0.0.0", 8443, true, cert, key);

    app().enableGzip(true);
    app().run();
    return 0;
}
