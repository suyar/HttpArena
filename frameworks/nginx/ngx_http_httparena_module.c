#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>
#include "cJSON.h"
#include <math.h>

/* ---------- Pre-loaded data ---------- */

static u_char *g_json_resp = NULL;
static size_t g_json_resp_len = 0;
static u_char *g_json_large_resp = NULL;
static size_t g_json_large_resp_len = 0;

#define MAX_STATIC 32
typedef struct {
    char name[64];
    char ct[64];
    u_char *data;
    size_t len;
} sfile_t;
static sfile_t g_sf[MAX_STATIC];
static ngx_int_t g_sf_n = 0;

/* ---------- Integer parser ---------- */

static int64_t
parse_int(u_char *start, u_char *end)
{
    int64_t n = 0;
    int neg = 0;
    u_char *p = start;
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    if (p < end && *p == '-') { neg = 1; p++; }
    while (p < end && *p >= '0' && *p <= '9') {
        n = n * 10 + (*p - '0');
        p++;
    }
    return neg ? -n : n;
}

/* ---------- Query string sum ---------- */

static int64_t
sum_args(ngx_str_t *args)
{
    if (!args->len) return 0;
    int64_t sum = 0;
    u_char *p = args->data, *end = p + args->len;
    while (p < end) {
        u_char *eq = ngx_strlchr(p, end, '=');
        if (!eq) break;
        u_char *v = eq + 1;
        u_char *amp = ngx_strlchr(v, end, '&');
        if (!amp) amp = end;
        sum += parse_int(v, amp);
        p = (amp < end) ? amp + 1 : end;
    }
    return sum;
}

/* ---------- Response helper ---------- */

static ngx_int_t
send_resp(ngx_http_request_t *r, ngx_uint_t status,
          u_char *ct, size_t ct_len,
          u_char *body, size_t body_len, ngx_int_t copy)
{
    ngx_buf_t *b;
    ngx_chain_t out;

    r->headers_out.status = status;
    r->headers_out.content_type.data = ct;
    r->headers_out.content_type.len = ct_len;
    r->headers_out.content_type_len = ct_len;
    r->headers_out.content_length_n = body_len;

    if (r->method == NGX_HTTP_HEAD) {
        return ngx_http_send_header(r);
    }

    if (copy) {
        b = ngx_create_temp_buf(r->pool, body_len);
        if (!b) return NGX_HTTP_INTERNAL_SERVER_ERROR;
        b->last = ngx_copy(b->last, body, body_len);
    } else {
        b = ngx_calloc_buf(r->pool);
        if (!b) return NGX_HTTP_INTERNAL_SERVER_ERROR;
        b->pos = body;
        b->last = body + body_len;
        b->memory = 1;
    }
    b->last_buf = 1;

    out.buf = b;
    out.next = NULL;

    ngx_int_t rc = ngx_http_send_header(r);
    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) return rc;
    return ngx_http_output_filter(r, &out);
}

/* ---------- CRC32 ---------- */

static uint32_t crc32_tab[8][256];

static void
init_crc32_table(void)
{
    uint32_t i;
    int j, s;
    for (i = 0; i < 256; i++) {
        uint32_t c = i;
        for (j = 0; j < 8; j++) c = (c >> 1) ^ (0xEDB88320 & (-(c & 1)));
        crc32_tab[0][i] = c;
    }
    for (i = 0; i < 256; i++)
        for (s = 1; s < 8; s++)
            crc32_tab[s][i] = (crc32_tab[s-1][i] >> 8) ^ crc32_tab[0][crc32_tab[s-1][i] & 0xFF];
}

static uint32_t
compute_crc32(u_char *data, size_t len)
{
    uint32_t crc = 0xFFFFFFFF;
    while (len >= 8) {
        uint32_t a = *(uint32_t *)data ^ crc;
        uint32_t b = *(uint32_t *)(data + 4);
        crc = crc32_tab[7][a & 0xFF] ^ crc32_tab[6][(a >> 8) & 0xFF]
            ^ crc32_tab[5][(a >> 16) & 0xFF] ^ crc32_tab[4][(a >> 24)]
            ^ crc32_tab[3][b & 0xFF] ^ crc32_tab[2][(b >> 8) & 0xFF]
            ^ crc32_tab[1][(b >> 16) & 0xFF] ^ crc32_tab[0][(b >> 24)];
        data += 8; len -= 8;
    }
    while (len--) crc = (crc >> 8) ^ crc32_tab[0][(crc ^ *data++) & 0xFF];
    return crc ^ 0xFFFFFFFF;
}

/* ---------- POST body handler for /upload ---------- */

static void
upload_post_handler(ngx_http_request_t *r)
{
    uint32_t crc = 0;
    if (r->request_body && r->request_body->bufs) {
        ngx_buf_t *buf = r->request_body->bufs->buf;
        if (buf && !buf->in_file && buf->pos < buf->last) {
            crc = compute_crc32(buf->pos, buf->last - buf->pos);
        }
    }

    u_char resp[16];
    u_char *last = ngx_snprintf(resp, sizeof(resp), "%08xd", crc);

    ngx_int_t rc = send_resp(r, 200,
                              (u_char *)"text/plain", 10,
                              resp, last - resp, 1);
    ngx_http_finalize_request(r, rc);
}

/* ---------- POST body handler for /baseline11 ---------- */

static void
baseline11_post_handler(ngx_http_request_t *r)
{
    int64_t sum = sum_args(&r->args);

    if (r->request_body && r->request_body->bufs) {
        ngx_buf_t *buf = r->request_body->bufs->buf;
        if (buf && !buf->in_file && buf->pos < buf->last) {
            sum += parse_int(buf->pos, buf->last);
        }
    }

    u_char resp[32];
    u_char *last = ngx_snprintf(resp, sizeof(resp), "%L", sum);

    ngx_int_t rc = send_resp(r, 200,
                              (u_char *)"text/plain", 10,
                              resp, last - resp, 1);
    ngx_http_finalize_request(r, rc);
}

/* ---------- Main request handler ---------- */

static ngx_int_t
ngx_http_httparena_handler(ngx_http_request_t *r)
{
    u_char *uri = r->uri.data;
    size_t uri_len = r->uri.len;

    /* /pipeline */
    if (uri_len == 9 && ngx_strncmp(uri, "/pipeline", 9) == 0) {
        ngx_http_discard_request_body(r);
        return send_resp(r, 200,
                         (u_char *)"text/plain", 10,
                         (u_char *)"ok", 2, 0);
    }

    /* /baseline2 */
    if (uri_len == 10 && ngx_strncmp(uri, "/baseline2", 10) == 0) {
        ngx_http_discard_request_body(r);
        int64_t sum = sum_args(&r->args);
        u_char buf[32];
        u_char *last = ngx_snprintf(buf, sizeof(buf), "%L", sum);
        return send_resp(r, 200,
                         (u_char *)"text/plain", 10,
                         buf, last - buf, 1);
    }

    /* /baseline11 */
    if (uri_len == 11 && ngx_strncmp(uri, "/baseline11", 11) == 0) {
        if (r->method == NGX_HTTP_POST) {
            r->request_body_in_single_buf = 1;
            ngx_int_t rc = ngx_http_read_client_request_body(r,
                                                              baseline11_post_handler);
            if (rc >= NGX_HTTP_SPECIAL_RESPONSE) return rc;
            return NGX_DONE;
        }
        ngx_http_discard_request_body(r);
        int64_t sum = sum_args(&r->args);
        u_char buf[32];
        u_char *last = ngx_snprintf(buf, sizeof(buf), "%L", sum);
        return send_resp(r, 200,
                         (u_char *)"text/plain", 10,
                         buf, last - buf, 1);
    }

    /* /upload */
    if (uri_len == 7 && ngx_strncmp(uri, "/upload", 7) == 0 && r->method == NGX_HTTP_POST) {
        r->request_body_in_single_buf = 1;
        ngx_int_t rc = ngx_http_read_client_request_body(r, upload_post_handler);
        if (rc >= NGX_HTTP_SPECIAL_RESPONSE) return rc;
        return NGX_DONE;
    }

    /* /caching */
    if (uri_len == 8 && ngx_strncmp(uri, "/caching", 8) == 0) {
        ngx_http_discard_request_body(r);

        static const u_char etag_val[] = "\"AOK\"";
        ngx_table_elt_t *etag_hdr = ngx_list_push(&r->headers_out.headers);
        if (!etag_hdr) return NGX_HTTP_INTERNAL_SERVER_ERROR;
        etag_hdr->hash = 1;
        ngx_str_set(&etag_hdr->key, "ETag");
        etag_hdr->value.data = (u_char *)etag_val;
        etag_hdr->value.len = sizeof(etag_val) - 1;

        /* Check If-None-Match */
        if (r->headers_in.if_none_match &&
            r->headers_in.if_none_match->value.len == sizeof(etag_val) - 1 &&
            ngx_strncmp(r->headers_in.if_none_match->value.data,
                        etag_val, sizeof(etag_val) - 1) == 0) {
            r->headers_out.status = NGX_HTTP_NOT_MODIFIED;
            r->headers_out.content_length_n = -1;
            r->header_only = 1;
            return ngx_http_send_header(r);
        }

        return send_resp(r, 200,
                         (u_char *)"text/plain", 10,
                         (u_char *)"OK", 2, 0);
    }

    /* /compression */
    if (uri_len == 12 && ngx_strncmp(uri, "/compression", 12) == 0) {
        ngx_http_discard_request_body(r);
        if (g_json_large_resp) {
            return send_resp(r, 200,
                             (u_char *)"application/json", 16,
                             g_json_large_resp, g_json_large_resp_len, 0);
        }
        return send_resp(r, 500,
                         (u_char *)"text/plain", 10,
                         (u_char *)"No dataset", 10, 0);
    }

    /* /json */
    if (uri_len == 5 && ngx_strncmp(uri, "/json", 5) == 0) {
        ngx_http_discard_request_body(r);
        if (g_json_resp) {
            return send_resp(r, 200,
                             (u_char *)"application/json", 16,
                             g_json_resp, g_json_resp_len, 0);
        }
        return send_resp(r, 500,
                         (u_char *)"text/plain", 10,
                         (u_char *)"No dataset", 10, 0);
    }

    /* /static/<filename> */
    if (uri_len > 8 && ngx_strncmp(uri, "/static/", 8) == 0) {
        ngx_http_discard_request_body(r);
        u_char *fname = uri + 8;
        size_t fname_len = uri_len - 8;
        for (ngx_int_t i = 0; i < g_sf_n; i++) {
            size_t nlen = ngx_strlen(g_sf[i].name);
            if (nlen == fname_len &&
                ngx_strncmp(g_sf[i].name, fname, nlen) == 0) {
                return send_resp(r, 200,
                                 (u_char *)g_sf[i].ct, ngx_strlen(g_sf[i].ct),
                                 g_sf[i].data, g_sf[i].len, 0);
            }
        }
        return send_resp(r, 404,
                         (u_char *)"text/plain", 10,
                         (u_char *)"Not Found", 9, 0);
    }

    return NGX_DECLINED;
}

/* ---------- Data loading ---------- */

static void
load_json_file(const char *path, u_char **out_data, size_t *out_len)
{
    FILE *f = fopen(path, "r");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *raw = malloc(sz + 1);
    if (!raw) { fclose(f); return; }
    fread(raw, 1, sz, f);
    raw[sz] = '\0';
    fclose(f);

    cJSON *arr = cJSON_Parse(raw);
    free(raw);
    if (!arr || !cJSON_IsArray(arr)) {
        if (arr) cJSON_Delete(arr);
        return;
    }

    cJSON *item;
    int count = 0;
    cJSON_ArrayForEach(item, arr) {
        cJSON *jprice = cJSON_GetObjectItem(item, "price");
        cJSON *jqty = cJSON_GetObjectItem(item, "quantity");
        if (jprice && jqty) {
            double total = round(jprice->valuedouble * jqty->valueint * 100.0) / 100.0;
            cJSON_AddNumberToObject(item, "total", total);
        }
        count++;
    }

    cJSON *result = cJSON_CreateObject();
    cJSON_AddItemToObject(result, "items", cJSON_Duplicate(arr, 1));
    cJSON_AddNumberToObject(result, "count", count);

    char *json_str = cJSON_PrintUnformatted(result);
    if (json_str) {
        *out_len = strlen(json_str);
        *out_data = (u_char *)json_str;
    }

    cJSON_Delete(result);
    cJSON_Delete(arr);
}

static void
load_dataset(void)
{
    const char *path = getenv("DATASET_PATH");
    if (!path) path = "/data/dataset.json";
    load_json_file(path, &g_json_resp, &g_json_resp_len);
    load_json_file("/data/dataset-large.json", &g_json_large_resp, &g_json_large_resp_len);
}

static void
load_static_files(void)
{
    static const struct { const char *name; const char *ct; } entries[] = {
        {"reset.css",       "text/css"},
        {"layout.css",      "text/css"},
        {"theme.css",       "text/css"},
        {"components.css",  "text/css"},
        {"utilities.css",   "text/css"},
        {"analytics.js",    "application/javascript"},
        {"helpers.js",      "application/javascript"},
        {"app.js",          "application/javascript"},
        {"vendor.js",       "application/javascript"},
        {"router.js",       "application/javascript"},
        {"header.html",     "text/html"},
        {"footer.html",     "text/html"},
        {"regular.woff2",   "font/woff2"},
        {"bold.woff2",      "font/woff2"},
        {"logo.svg",        "image/svg+xml"},
        {"icon-sprite.svg", "image/svg+xml"},
        {"hero.webp",       "image/webp"},
        {"thumb1.webp",     "image/webp"},
        {"thumb2.webp",     "image/webp"},
        {"manifest.json",   "application/json"},
    };
    int n = sizeof(entries) / sizeof(entries[0]);
    for (int i = 0; i < n && g_sf_n < MAX_STATIC; i++) {
        char path[256];
        snprintf(path, sizeof(path), "/data/static/%s", entries[i].name);
        FILE *f = fopen(path, "rb");
        if (!f) continue;
        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        u_char *data = malloc(sz);
        if (!data) { fclose(f); continue; }
        fread(data, 1, sz, f);
        fclose(f);
        strncpy(g_sf[g_sf_n].name, entries[i].name, sizeof(g_sf[g_sf_n].name) - 1);
        strncpy(g_sf[g_sf_n].ct, entries[i].ct, sizeof(g_sf[g_sf_n].ct) - 1);
        g_sf[g_sf_n].data = data;
        g_sf[g_sf_n].len = sz;
        g_sf_n++;
    }
}

/* ---------- Module boilerplate ---------- */

static char *
ngx_http_httparena(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_core_loc_conf_t *clcf;
    clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);
    clcf->handler = ngx_http_httparena_handler;
    return NGX_CONF_OK;
}

static ngx_int_t
ngx_http_httparena_init_module(ngx_cycle_t *cycle)
{
    init_crc32_table();
    load_dataset();
    load_static_files();
    return NGX_OK;
}

static ngx_command_t ngx_http_httparena_commands[] = {
    {
        ngx_string("httparena"),
        NGX_HTTP_LOC_CONF | NGX_CONF_NOARGS,
        ngx_http_httparena,
        0,
        0,
        NULL
    },
    ngx_null_command
};

static ngx_http_module_t ngx_http_httparena_module_ctx = {
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
};

ngx_module_t ngx_http_httparena_module = {
    NGX_MODULE_V1,
    &ngx_http_httparena_module_ctx,
    ngx_http_httparena_commands,
    NGX_HTTP_MODULE,
    NULL,                                /* init master */
    ngx_http_httparena_init_module,      /* init module */
    NULL,                                /* init process */
    NULL,                                /* init thread */
    NULL,                                /* exit thread */
    NULL,                                /* exit process */
    NULL,                                /* exit master */
    NGX_MODULE_V1_PADDING
};
