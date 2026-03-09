package httparenahandler

import (
	"encoding/json"
	"fmt"
	"hash/crc32"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
	"github.com/caddyserver/caddy/v2/caddyconfig/httpcaddyfile"
	"github.com/caddyserver/caddy/v2/modules/caddyhttp"
)

func init() {
	caddy.RegisterModule(Handler{})
	httpcaddyfile.RegisterHandlerDirective("httparena", parseCaddyfile)
}

type Rating struct {
	Score float64 `json:"score"`
	Count int     `json:"count"`
}

type ProcessedItem struct {
	ID       int      `json:"id"`
	Name     string   `json:"name"`
	Category string   `json:"category"`
	Price    float64  `json:"price"`
	Quantity int      `json:"quantity"`
	Active   bool     `json:"active"`
	Tags     []string `json:"tags"`
	Rating   Rating   `json:"rating"`
	Total    float64  `json:"total"`
}

type ProcessResponse struct {
	Items []ProcessedItem `json:"items"`
	Count int             `json:"count"`
}

type staticFile struct {
	data        []byte
	contentType string
}

type Handler struct {
	jsonResponse      []byte
	jsonLargeResponse []byte
	staticFiles       map[string]staticFile
}

func (Handler) CaddyModule() caddy.ModuleInfo {
	return caddy.ModuleInfo{
		ID:  "http.handlers.httparena",
		New: func() caddy.Module { return new(Handler) },
	}
}

func (h *Handler) Provision(ctx caddy.Context) error {
	path := os.Getenv("DATASET_PATH")
	if path == "" {
		path = "/data/dataset.json"
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil // dataset not available, /json will 500
	}
	var dataset []struct {
		ID       int      `json:"id"`
		Name     string   `json:"name"`
		Category string   `json:"category"`
		Price    float64  `json:"price"`
		Quantity int      `json:"quantity"`
		Active   bool     `json:"active"`
		Tags     []string `json:"tags"`
		Rating   Rating   `json:"rating"`
	}
	if err := json.Unmarshal(data, &dataset); err != nil {
		return nil
	}
	items := make([]ProcessedItem, len(dataset))
	for i, d := range dataset {
		items[i] = ProcessedItem{
			ID: d.ID, Name: d.Name, Category: d.Category,
			Price: d.Price, Quantity: d.Quantity, Active: d.Active,
			Tags: d.Tags, Rating: d.Rating,
			Total: math.Round(d.Price*float64(d.Quantity)*100) / 100,
		}
	}
	h.jsonResponse, _ = json.Marshal(ProcessResponse{Items: items, Count: len(items)})

	// Load large dataset for /compression
	largeData, err := os.ReadFile("/data/dataset-large.json")
	if err == nil {
		var largeDataset []struct {
			ID       int      `json:"id"`
			Name     string   `json:"name"`
			Category string   `json:"category"`
			Price    float64  `json:"price"`
			Quantity int      `json:"quantity"`
			Active   bool     `json:"active"`
			Tags     []string `json:"tags"`
			Rating   Rating   `json:"rating"`
		}
		if err := json.Unmarshal(largeData, &largeDataset); err == nil {
			largeItems := make([]ProcessedItem, len(largeDataset))
			for i, d := range largeDataset {
				largeItems[i] = ProcessedItem{
					ID: d.ID, Name: d.Name, Category: d.Category,
					Price: d.Price, Quantity: d.Quantity, Active: d.Active,
					Tags: d.Tags, Rating: d.Rating,
					Total: math.Round(d.Price*float64(d.Quantity)*100) / 100,
				}
			}
			h.jsonLargeResponse, _ = json.Marshal(ProcessResponse{Items: largeItems, Count: len(largeItems)})
		}
	}

	// Load static files
	mimeTypes := map[string]string{
		".css": "text/css", ".js": "application/javascript", ".html": "text/html",
		".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp", ".json": "application/json",
	}
	h.staticFiles = make(map[string]staticFile)
	entries, err := os.ReadDir("/data/static")
	if err == nil {
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			d, err := os.ReadFile(filepath.Join("/data/static", e.Name()))
			if err != nil {
				continue
			}
			ext := filepath.Ext(e.Name())
			ct, ok := mimeTypes[ext]
			if !ok {
				ct = "application/octet-stream"
			}
			h.staticFiles[e.Name()] = staticFile{data: d, contentType: ct}
		}
	}

	return nil
}

func sumQuery(r *http.Request) int64 {
	var sum int64
	for _, vals := range r.URL.Query() {
		for _, v := range vals {
			if n, err := strconv.ParseInt(v, 10, 64); err == nil {
				sum += n
			}
		}
	}
	return sum
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request, next caddyhttp.Handler) error {
	path := r.URL.Path

	switch path {
	case "/pipeline":
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Server", "caddy")
		w.Write([]byte("ok"))
		return nil

	case "/json":
		if h.jsonResponse != nil {
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Server", "caddy")
			w.Header().Set("Content-Length", strconv.Itoa(len(h.jsonResponse)))
			w.Write(h.jsonResponse)
		} else {
			http.Error(w, "No dataset", 500)
		}
		return nil

	case "/baseline2":
		sum := sumQuery(r)
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Server", "caddy")
		fmt.Fprint(w, sum)
		return nil

	case "/baseline11":
		sum := sumQuery(r)
		if r.Method == "POST" && r.Body != nil {
			body, _ := io.ReadAll(r.Body)
			if n, err := strconv.ParseInt(string(body), 10, 64); err == nil {
				sum += n
			}
		}
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Server", "caddy")
		fmt.Fprint(w, sum)
		return nil

	case "/upload":
		if r.Method == "POST" && r.Body != nil {
			body, _ := io.ReadAll(r.Body)
			checksum := crc32.ChecksumIEEE(body)
			w.Header().Set("Content-Type", "text/plain")
			w.Header().Set("Server", "caddy")
			fmt.Fprintf(w, "%08x", checksum)
		} else {
			http.Error(w, "POST required", 405)
		}
		return nil

	case "/caching":
		inm := r.Header.Get("If-None-Match")
		w.Header().Set("ETag", `"AOK"`)
		w.Header().Set("Server", "caddy")
		if inm == `"AOK"` {
			w.WriteHeader(304)
		} else {
			w.Header().Set("Content-Type", "text/plain")
			w.Header().Set("Content-Length", "2")
			w.Write([]byte("OK"))
		}
		return nil

	case "/compression":
		if h.jsonLargeResponse != nil {
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Server", "caddy")
			w.Write(h.jsonLargeResponse)
		} else {
			http.Error(w, "No dataset", 500)
		}
		return nil
	}

	if strings.HasPrefix(path, "/static/") {
		name := path[8:]
		if sf, ok := h.staticFiles[name]; ok {
			w.Header().Set("Content-Type", sf.contentType)
			w.Header().Set("Server", "caddy")
			w.Header().Set("Content-Length", strconv.Itoa(len(sf.data)))
			w.Write(sf.data)
			return nil
		}
		http.NotFound(w, r)
		return nil
	}

	return next.ServeHTTP(w, r)
}

func (h *Handler) UnmarshalCaddyfile(d *caddyfile.Dispenser) error {
	return nil
}

func parseCaddyfile(h httpcaddyfile.Helper) (caddyhttp.MiddlewareHandler, error) {
	var handler Handler
	err := handler.UnmarshalCaddyfile(h.Dispenser)
	return &handler, err
}

var (
	_ caddyhttp.MiddlewareHandler = (*Handler)(nil)
	_ caddyfile.Unmarshaler       = (*Handler)(nil)
)
