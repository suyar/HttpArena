package httparenahandler

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"strconv"

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

type Handler struct {
	jsonResponse []byte
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
