#include "lithium_http_server.hh"
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>

// Simple JSON builder (avoids pulling in a JSON library)
namespace sjson {
    static void escape(std::string &out, const char *s) {
        out += '"';
        for (; *s; ++s) {
            switch (*s) {
                case '"': out += "\\\""; break;
                case '\\': out += "\\\\"; break;
                case '\n': out += "\\n"; break;
                default: out += *s;
            }
        }
        out += '"';
    }
}

static std::string json_response;

// Minimal JSON parser for dataset loading
struct DatasetItem {
    int id;
    std::string name, category;
    double price;
    int quantity;
    bool active;
    std::vector<std::string> tags;
    double rating_score;
    int rating_count;
};

static bool parse_json_string(const char *&p, std::string &out) {
    if (*p != '"') return false;
    ++p;
    out.clear();
    while (*p && *p != '"') {
        if (*p == '\\') { ++p; if (*p) out += *p++; }
        else out += *p++;
    }
    if (*p == '"') ++p;
    return true;
}

static void skip_ws(const char *&p) { while (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t') ++p; }

static double parse_number(const char *&p) {
    char *ep;
    double v = strtod(p, &ep);
    p = ep;
    return v;
}

static void skip_value(const char *&p) {
    skip_ws(p);
    if (*p == '"') { std::string tmp; parse_json_string(p, tmp); }
    else if (*p == '{') { int d=1; ++p; while(*p&&d){if(*p=='{')d++;else if(*p=='}')d--;++p;} }
    else if (*p == '[') { int d=1; ++p; while(*p&&d){if(*p=='[')d++;else if(*p==']')d--;++p;} }
    else if (!strncmp(p,"true",4)) p+=4;
    else if (!strncmp(p,"false",5)) p+=5;
    else if (!strncmp(p,"null",4)) p+=4;
    else { strtod(p, (char**)&p); }
}

static std::vector<DatasetItem> parse_dataset(const std::string &data) {
    std::vector<DatasetItem> items;
    const char *p = data.c_str();
    skip_ws(p);
    if (*p != '[') return items;
    ++p;
    while (true) {
        skip_ws(p);
        if (*p == ']' || !*p) break;
        if (*p == ',') { ++p; continue; }
        if (*p != '{') break;
        ++p;
        DatasetItem item{};
        while (true) {
            skip_ws(p);
            if (*p == '}' || !*p) { if (*p == '}') ++p; break; }
            if (*p == ',') { ++p; continue; }
            std::string key;
            if (!parse_json_string(p, key)) break;
            skip_ws(p);
            if (*p == ':') ++p;
            skip_ws(p);
            if (key == "id") item.id = (int)parse_number(p);
            else if (key == "name") parse_json_string(p, item.name);
            else if (key == "category") parse_json_string(p, item.category);
            else if (key == "price") item.price = parse_number(p);
            else if (key == "quantity") item.quantity = (int)parse_number(p);
            else if (key == "active") {
                if (!strncmp(p,"true",4)) { item.active = true; p += 4; }
                else if (!strncmp(p,"false",5)) { item.active = false; p += 5; }
            }
            else if (key == "tags") {
                skip_ws(p);
                if (*p == '[') {
                    ++p;
                    while (true) {
                        skip_ws(p);
                        if (*p == ']' || !*p) { if (*p == ']') ++p; break; }
                        if (*p == ',') { ++p; continue; }
                        std::string tag;
                        parse_json_string(p, tag);
                        item.tags.push_back(std::move(tag));
                    }
                }
            }
            else if (key == "rating") {
                skip_ws(p);
                if (*p == '{') {
                    ++p;
                    while (true) {
                        skip_ws(p);
                        if (*p == '}' || !*p) { if (*p == '}') ++p; break; }
                        if (*p == ',') { ++p; continue; }
                        std::string rk;
                        if (!parse_json_string(p, rk)) break;
                        skip_ws(p); if (*p == ':') ++p; skip_ws(p);
                        if (rk == "score") item.rating_score = parse_number(p);
                        else if (rk == "count") item.rating_count = (int)parse_number(p);
                        else skip_value(p);
                    }
                }
            }
            else skip_value(p);
        }
        items.push_back(std::move(item));
    }
    return items;
}

static void load_dataset() {
    const char *path = getenv("DATASET_PATH");
    if (!path) path = "/data/dataset.json";
    std::ifstream f(path);
    if (!f.is_open()) return;
    std::stringstream ss;
    ss << f.rdbuf();
    auto items = parse_dataset(ss.str());
    if (items.empty()) return;

    // Build JSON response
    std::string out = "{\"items\":[";
    for (size_t i = 0; i < items.size(); i++) {
        if (i) out += ',';
        auto &d = items[i];
        double total = std::round(d.price * d.quantity * 100.0) / 100.0;
        out += "{\"id\":"; out += std::to_string(d.id);
        out += ",\"name\":"; sjson::escape(out, d.name.c_str());
        out += ",\"category\":"; sjson::escape(out, d.category.c_str());
        out += ",\"price\":";
        { char buf[32]; snprintf(buf, sizeof(buf), "%.2f", d.price); out += buf; }
        out += ",\"quantity\":"; out += std::to_string(d.quantity);
        out += ",\"active\":"; out += d.active ? "true" : "false";
        out += ",\"tags\":[";
        for (size_t j = 0; j < d.tags.size(); j++) {
            if (j) out += ',';
            sjson::escape(out, d.tags[j].c_str());
        }
        out += "],\"rating\":{\"score\":";
        { char buf[32]; snprintf(buf, sizeof(buf), "%.1f", d.rating_score); out += buf; }
        out += ",\"count\":"; out += std::to_string(d.rating_count);
        out += "},\"total\":";
        { char buf[32]; snprintf(buf, sizeof(buf), "%.2f", total); out += buf; }
        out += '}';
    }
    out += "],\"count\":"; out += std::to_string(items.size()); out += '}';
    json_response = std::move(out);
}

static int64_t sum_query(std::string_view qs) {
    if (qs.empty()) return 0;
    int64_t sum = 0;
    size_t i = 0;
    while (i < qs.size()) {
        auto eq = qs.find('=', i);
        if (eq == std::string_view::npos) break;
        auto amp = qs.find('&', eq);
        if (amp == std::string_view::npos) amp = qs.size();
        try { sum += std::stoll(std::string(qs.substr(eq + 1, amp - eq - 1))); } catch (...) {}
        i = amp + 1;
    }
    return sum;
}

int main() {
    load_dataset();

    using namespace li;
    http_api api;

    api.get("/pipeline") = [](http_request &req, http_response &resp) {
        resp.set_header("server", "lithium");
        resp.set_header("content-type", "text/plain");
        resp.write("ok");
    };

    api.get("/json") = [](http_request &req, http_response &resp) {
        if (!json_response.empty()) {
            resp.set_header("server", "lithium");
            resp.set_header("content-type", "application/json");
            resp.set_header("content-length", std::to_string(json_response.size()).c_str());
            resp.write(json_response);
        } else {
            resp.set_status(500);
            resp.write("No dataset");
        }
    };

    api.get("/baseline2") = [](http_request &req, http_response &resp) {
        int64_t sum = sum_query(req.http_ctx.get_parameters_string());
        resp.set_header("server", "lithium");
        resp.set_header("content-type", "text/plain");
        resp.write(std::to_string(sum));
    };

    api.get("/baseline11") = [](http_request &req, http_response &resp) {
        int64_t sum = sum_query(req.http_ctx.get_parameters_string());
        resp.set_header("server", "lithium");
        resp.set_header("content-type", "text/plain");
        resp.write(std::to_string(sum));
    };

    api.post("/baseline11") = [](http_request &req, http_response &resp) {
        int64_t sum = sum_query(req.http_ctx.get_parameters_string());
        auto body = req.http_ctx.read_whole_body();
        if (body.size() > 0) {
            try { sum += std::stoll(std::string(body)); } catch (...) {}
        }
        resp.set_header("server", "lithium");
        resp.set_header("content-type", "text/plain");
        resp.write(std::to_string(sum));
    };

    int nthreads = std::thread::hardware_concurrency();
    if (nthreads < 1) nthreads = 1;
    http_serve(api, 8080, s::nthreads = nthreads);
    return 0;
}
