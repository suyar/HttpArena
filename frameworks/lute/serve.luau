local server = require("@lute/net/server")
local fs = require("@std/fs")
local json = require("@std/json")

local STATIC_DIR = "/data/static"
local CONTENT_TYPES: { [string]: string } = {
	css = "text/css",
	js = "application/javascript",
	json = "application/json",
	html = "text/html",
	woff2 = "font/woff2",
	svg = "image/svg+xml",
	webp = "image/webp",
}

local COMPRESSIBLE: { [string]: boolean } = {
	css = true, js = true, json = true, html = true, svg = true,
}

local STATIC_HEADERS: { [string]: { [string]: string } } = {}
local STATIC_HEADERS_BR: { [string]: { [string]: string } } = {}
local STATIC_HEADERS_GZ: { [string]: { [string]: string } } = {}
for ext, mime in CONTENT_TYPES do
	STATIC_HEADERS[ext] = { ["Content-Type"] = mime }
	STATIC_HEADERS_BR[ext] = { ["Content-Type"] = mime, ["Content-Encoding"] = "br" }
	STATIC_HEADERS_GZ[ext] = { ["Content-Type"] = mime, ["Content-Encoding"] = "gzip" }
end
local OCTET_HEADERS = { ["Content-Type"] = "application/octet-stream" }

local TEXT_HEADERS = { ["Content-Type"] = "text/plain" }
local JSON_HEADERS = { ["Content-Type"] = "application/json" }
local NOT_FOUND = { status = 404, body = "", headers = TEXT_HEADERS }
local UPGRADE_FAILED = { status = 400, body = "Upgrade failed", headers = TEXT_HEADERS }
local PIPELINE_OK = { body = "ok", headers = TEXT_HEADERS }

local dataset: any = nil
local datasetLen = 0

local function buildJson(count: number, m: number): string
	local items = table.create(count)
	for i = 1, count do
		local src = dataset[i]
		items[i] = {
			id = src.id,
			name = src.name,
			category = src.category,
			price = src.price,
			quantity = src.quantity,
			active = src.active,
			tags = src.tags,
			rating = src.rating,
			total = src.price * src.quantity * m,
		}
	end
	return json.serialize({ count = count, items = items })
end

local function handle(req, srv)
	local path = req.path
	local method = req.method

	if path == "/ws" then
		if srv:upgrade(req) then
			return
		end
		return UPGRADE_FAILED
	end

	if path == "/baseline11" then
		local a = tonumber(req.query.a) or 0
		local b = tonumber(req.query.b) or 0
		if method == "POST" then
			local c = tonumber(req.body) or 0
			return { body = tostring(a + b + c), headers = TEXT_HEADERS }
		end
		return { body = tostring(a + b), headers = TEXT_HEADERS }
	end

	if path == "/pipeline" then
		return PIPELINE_OK
	end

	if path == "/upload" and method == "POST" then
		return { body = tostring(#req.body), headers = TEXT_HEADERS }
	end

	if string.sub(path, 1, 6) == "/json/" then
		local count = tonumber(string.sub(path, 7))
		if count and count >= 0 and count <= datasetLen then
			local m = tonumber(req.query.m) or 1
			return { body = buildJson(count, m), headers = JSON_HEADERS }
		end
		return NOT_FOUND
	end

	if string.sub(path, 1, 8) == "/static/" then
		local name = string.sub(path, 9)

		if name == "" or string.find(name, "/", 1, true) then
			return NOT_FOUND
		end
		local ext = string.match(name, "%.([%w]+)$") or ""
		local fullPath = STATIC_DIR .. "/" .. name

		if COMPRESSIBLE[ext] then
			local accept = req.headers["accept-encoding"] or req.headers["Accept-Encoding"]
			if accept then
				if string.find(accept, "br", 1, true) then
					local ok, body = pcall(fs.readFileToString, fullPath .. ".br")
					if ok then
						return { body = body, headers = STATIC_HEADERS_BR[ext] }
					end
				end
				if string.find(accept, "gzip", 1, true) then
					local ok, body = pcall(fs.readFileToString, fullPath .. ".gz")
					if ok then
						return { body = body, headers = STATIC_HEADERS_GZ[ext] }
					end
				end
			end
		end

		local ok, body = pcall(fs.readFileToString, fullPath)
		if not ok then
			return NOT_FOUND
		end
		return { body = body, headers = STATIC_HEADERS[ext] or OCTET_HEADERS }
	end

	return NOT_FOUND
end

local wsHandlers = {
	message = function(ws, message)
		ws:send(message)
	end,
}

return {
	serve = function()
		dataset = json.deserialize(fs.readFileToString("/data/dataset.json")) :: any
		datasetLen = #dataset

		server.serve({
			hostname = "0.0.0.0",
			port = 8080,
			reuseport = true,
			handler = handle,
			websocket = wsHandlers,
		})

		if fs.exists("/certs/server.crt") and fs.exists("/certs/server.key") then
			server.serve({
				hostname = "0.0.0.0",
				port = 8081,
				reuseport = true,
				tls = {
					certfilename = "/certs/server.crt",
					keyfilename = "/certs/server.key",
				},
				handler = handle,
				websocket = wsHandlers,
			})
		end
	end,
}
