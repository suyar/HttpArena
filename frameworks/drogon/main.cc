#include <drogon/drogon.h>
#include <fstream>
#include <sstream>
#include <cmath>
#include <unistd.h>

using namespace drogon;

static std::string json_response;

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
    json_response = Json::writeString(wb, resp);
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
    loadDataset();

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
                if (!json_response.empty()) {
                    auto resp = HttpResponse::newHttpResponse();
                    resp->setBody(json_response);
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

            return {};
        });

    app().setLogLevel(trantor::Logger::kWarn);
    app().setThreadNum(0); // auto-detect CPU cores
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

    app().run();
    return 0;
}
