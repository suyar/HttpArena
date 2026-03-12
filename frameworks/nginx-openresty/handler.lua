local cjson = require "cjson"
local ffi = require "ffi"

local SQLITE_OPEN_READONLY = 1
local SQLITE_ROW = 100

local _M = {}

local json_resp = nil
local large_resp = ""
local static_files = {}
local sqlite = nil
local db_stmt_ptr = nil

function _M.init()
    local mime = {
        css = "text/css", js = "application/javascript", html = "text/html",
        woff2 = "font/woff2", svg = "image/svg+xml", webp = "image/webp",
        json = "application/json",
    }

    -- Load raw dataset for per-request processing
    local f = io.open(os.getenv("DATASET_PATH") or "/data/dataset.json", "r")
    if f then
        json_resp = cjson.decode(f:read("*a"))
        f:close()
    end

    -- Load large dataset
    f = io.open("/data/dataset-large.json", "r")
    if f then
        local data = cjson.decode(f:read("*a"))
        f:close()
        for _, item in ipairs(data) do
            item.total = math.floor(item.price * item.quantity * 100 + 0.5) / 100
        end
        large_resp = cjson.encode({items = data, count = #data})
    end

    -- Load static files
    local handle = io.popen("ls /data/static 2>/dev/null")
    if handle then
        for name in handle:lines() do
            local file = io.open("/data/static/" .. name, "rb")
            if file then
                local ext = name:match("%.(%w+)$")
                static_files[name] = {
                    data = file:read("*a"),
                    ct = mime[ext] or "application/octet-stream",
                }
                file:close()
            end
        end
        handle:close()
    end
end

function _M.init_worker()
    -- Load SQLite FFI in worker process (after fork)
    ffi.cdef[[
        typedef struct sqlite3 sqlite3;
        typedef struct sqlite3_stmt sqlite3_stmt;
        int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
        int sqlite3_close(sqlite3 *db);
        int sqlite3_exec(sqlite3 *db, const char *sql, void *cb, void *arg, char **errmsg);
        int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
        int sqlite3_step(sqlite3_stmt *pStmt);
        int sqlite3_reset(sqlite3_stmt *pStmt);
        int sqlite3_bind_double(sqlite3_stmt *pStmt, int idx, double val);
        int sqlite3_column_int(sqlite3_stmt *pStmt, int iCol);
        double sqlite3_column_double(sqlite3_stmt *pStmt, int iCol);
        const char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);
    ]]
    sqlite = ffi.load("libsqlite3.so.0")

    local db_handle = ffi.new("sqlite3*[1]")
    local rc = sqlite.sqlite3_open_v2("/data/benchmark.db", db_handle, SQLITE_OPEN_READONLY, nil)
    if rc == 0 and db_handle[0] ~= nil then
        local db_ptr = db_handle[0]
        sqlite.sqlite3_exec(db_ptr, "PRAGMA mmap_size=268435456", nil, nil, nil)
        local stmt_handle = ffi.new("sqlite3_stmt*[1]")
        rc = sqlite.sqlite3_prepare_v2(db_ptr,
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50",
            -1, stmt_handle, nil)
        if rc == 0 then
            db_stmt_ptr = stmt_handle[0]
        end
    end
end

local function sum_args()
    local args = ngx.req.get_uri_args()
    local sum = 0
    for _, v in pairs(args) do
        if type(v) == "table" then
            for _, val in ipairs(v) do
                sum = sum + (tonumber(val) or 0)
            end
        else
            sum = sum + (tonumber(v) or 0)
        end
    end
    return sum
end

function _M.pipeline()
    ngx.header["Content-Type"] = "text/plain"
    ngx.print("ok")
end

function _M.baseline11()
    local sum = sum_args()
    if ngx.req.get_method() == "POST" then
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if body then
            sum = sum + (tonumber(body) or 0)
        end
    end
    ngx.header["Content-Type"] = "text/plain"
    ngx.print(string.format("%d", sum))
end

function _M.baseline2()
    ngx.header["Content-Type"] = "text/plain"
    ngx.print(string.format("%d", sum_args()))
end

function _M.json()
    if not json_resp then
        ngx.status = 500
        ngx.print("dataset not loaded")
        return
    end
    local items = {}
    for i, d in ipairs(json_resp) do
        local item = {}
        for k, v in pairs(d) do item[k] = v end
        item.total = math.floor(d.price * d.quantity * 100 + 0.5) / 100
        items[i] = item
    end
    ngx.header["Content-Type"] = "application/json"
    ngx.print(cjson.encode({items = items, count = #items}))
end

function _M.compression()
    if large_resp == "" then
        ngx.status = 500
        ngx.print("dataset not loaded")
        return
    end
    ngx.header["Content-Type"] = "application/json"
    ngx.print(large_resp)
end

function _M.upload()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        local fname = ngx.req.get_body_file()
        if fname then
            local f = io.open(fname, "rb")
            if f then
                body = f:read("*a")
                f:close()
            end
        end
    end
    if not body then
        ngx.status = 400
        ngx.print("no body")
        return
    end
    ngx.header["Content-Type"] = "text/plain"
    ngx.print(string.format("%08x", ngx.crc32_long(body)))
end

function _M.static_file()
    local name = ngx.var.uri:match("/static/(.+)")
    if not name then
        ngx.status = 404
        ngx.print("not found")
        return
    end
    local sf = static_files[name]
    if not sf then
        ngx.status = 404
        ngx.print("not found")
        return
    end
    ngx.header["Content-Type"] = sf.ct
    ngx.print(sf.data)
end

function _M.db()
    if db_stmt_ptr == nil then
        ngx.status = 500
        ngx.print("DB not available")
        return
    end
    local args = ngx.req.get_uri_args()
    local min_price = tonumber(args.min) or 10.0
    local max_price = tonumber(args.max) or 50.0
    sqlite.sqlite3_bind_double(db_stmt_ptr, 1, min_price)
    sqlite.sqlite3_bind_double(db_stmt_ptr, 2, max_price)
    local items = {}
    while sqlite.sqlite3_step(db_stmt_ptr) == SQLITE_ROW do
        local id = sqlite.sqlite3_column_int(db_stmt_ptr, 0)
        local name = ffi.string(sqlite.sqlite3_column_text(db_stmt_ptr, 1))
        local category = ffi.string(sqlite.sqlite3_column_text(db_stmt_ptr, 2))
        local price = sqlite.sqlite3_column_double(db_stmt_ptr, 3)
        local quantity = sqlite.sqlite3_column_int(db_stmt_ptr, 4)
        local active = sqlite.sqlite3_column_int(db_stmt_ptr, 5) == 1
        local tags_str = ffi.string(sqlite.sqlite3_column_text(db_stmt_ptr, 6))
        local rating_score = sqlite.sqlite3_column_double(db_stmt_ptr, 7)
        local rating_count = sqlite.sqlite3_column_int(db_stmt_ptr, 8)
        items[#items + 1] = {
            id = id,
            name = name,
            category = category,
            price = price,
            quantity = quantity,
            active = active,
            tags = cjson.decode(tags_str),
            rating = { score = rating_score, count = rating_count },
        }
    end
    sqlite.sqlite3_reset(db_stmt_ptr)
    ngx.header["Content-Type"] = "application/json"
    ngx.print(cjson.encode({ items = items, count = #items }))
end

return _M
