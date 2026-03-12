package httparenahandler

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
	"github.com/caddyserver/caddy/v2/caddyconfig/httpcaddyfile"
	"github.com/caddyserver/caddy/v2/modules/caddyhttp"
	_ "modernc.org/sqlite"
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

type RawItem struct {
	ID       int      `json:"id"`
	Name     string   `json:"name"`
	Category string   `json:"category"`
	Price    float64  `json:"price"`
	Quantity int      `json:"quantity"`
	Active   bool     `json:"active"`
	Tags     []string `json:"tags"`
	Rating   Rating   `json:"rating"`
}

type Handler struct {
	dataset           []RawItem
	jsonLargeResponse []byte
	staticFiles       map[string]staticFile
	db                *sql.DB
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

	if err := json.Unmarshal(data, &h.dataset); err != nil {
		return nil
	}

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

	// Open SQLite database
	db, err := sql.Open("sqlite", "file:/data/benchmark.db?mode=ro&immutable=1")
	if err == nil {
		db.SetMaxOpenConns(runtime.NumCPU())
		h.db = db
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
		if h.dataset != nil {
			items := make([]ProcessedItem, len(h.dataset))
			for i, d := range h.dataset {
				items[i] = ProcessedItem{
					ID: d.ID, Name: d.Name, Category: d.Category,
					Price: d.Price, Quantity: d.Quantity, Active: d.Active,
					Tags: d.Tags, Rating: d.Rating,
					Total: math.Round(d.Price*float64(d.Quantity)*100) / 100,
				}
			}
			resp, _ := json.Marshal(ProcessResponse{Items: items, Count: len(items)})
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Server", "caddy")
			w.Header().Set("Content-Length", strconv.Itoa(len(resp)))
			w.Write(resp)
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

	case "/compression":
		if h.jsonLargeResponse != nil {
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Server", "caddy")
			w.Write(h.jsonLargeResponse)
		} else {
			http.Error(w, "No dataset", 500)
		}
		return nil

	case "/db":
		if h.db == nil {
			http.Error(w, "DB not available", 500)
			return nil
		}
		minStr := r.URL.Query().Get("min")
		maxStr := r.URL.Query().Get("max")
		minPrice := 10.0
		maxPrice := 50.0
		if v, err := strconv.ParseFloat(minStr, 64); err == nil {
			minPrice = v
		}
		if v, err := strconv.ParseFloat(maxStr, 64); err == nil {
			maxPrice = v
		}
		rows, err := h.db.Query("SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50", minPrice, maxPrice)
		if err != nil {
			http.Error(w, "Query failed", 500)
			return nil
		}
		defer rows.Close()
		var items []map[string]interface{}
		for rows.Next() {
			var dbId int
			var name, category, tags string
			var price float64
			var quantity int
			var active int
			var ratingScore float64
			var ratingCount int
			if err := rows.Scan(&dbId, &name, &category, &price, &quantity, &active, &tags, &ratingScore, &ratingCount); err != nil {
				continue
			}
			var tagsArr []string
			json.Unmarshal([]byte(tags), &tagsArr)
			items = append(items, map[string]interface{}{
				"id": dbId, "name": name, "category": category,
				"price": price, "quantity": quantity, "active": active == 1,
				"tags": tagsArr,
				"rating": map[string]interface{}{"score": ratingScore, "count": ratingCount},
			})
		}
		resp := map[string]interface{}{
			"items": items,
			"count": len(items),
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Server", "caddy")
		json.NewEncoder(w).Encode(resp)
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
