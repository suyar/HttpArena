package main

import (
	"encoding/json"
	"math"
	"os"
	"strconv"

	"compress/flate"

	"github.com/valyala/fasthttp"
)

type Rating struct {
	Score float64 `json:"score"`
	Count int     `json:"count"`
}

type DatasetItem struct {
	ID       int      `json:"id"`
	Name     string   `json:"name"`
	Category string   `json:"category"`
	Price    float64  `json:"price"`
	Quantity int      `json:"quantity"`
	Active   bool     `json:"active"`
	Tags     []string `json:"tags"`
	Rating   Rating   `json:"rating"`
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

var dataset []DatasetItem
var jsonLargeResponse []byte

func loadDataset() {
	path := os.Getenv("DATASET_PATH")
	if path == "" {
		path = "/data/dataset.json"
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	json.Unmarshal(data, &dataset)
}

func loadDatasetLarge() {
	data, err := os.ReadFile("/data/dataset-large.json")
	if err != nil {
		return
	}
	var raw []struct {
		ID       int      `json:"id"`
		Name     string   `json:"name"`
		Category string   `json:"category"`
		Price    float64  `json:"price"`
		Quantity int      `json:"quantity"`
		Active   bool     `json:"active"`
		Tags     []string `json:"tags"`
		Rating   Rating   `json:"rating"`
	}
	if json.Unmarshal(data, &raw) != nil {
		return
	}
	items := make([]ProcessedItem, len(raw))
	for i, d := range raw {
		items[i] = ProcessedItem{
			ID: d.ID, Name: d.Name, Category: d.Category,
			Price: d.Price, Quantity: d.Quantity, Active: d.Active,
			Tags: d.Tags, Rating: d.Rating,
			Total: math.Round(d.Price*float64(d.Quantity)*100) / 100,
		}
	}
	jsonLargeResponse, _ = json.Marshal(ProcessResponse{Items: items, Count: len(items)})
}

func baseline11Handler(ctx *fasthttp.RequestCtx) {
	sum := 0

	ctx.QueryArgs().VisitAll(func(key, value []byte) {
		if n, err := strconv.Atoi(string(value)); err == nil {
			sum += n
		}
	})

	body := ctx.PostBody()
	if len(body) > 0 {
		if n, err := strconv.Atoi(string(body)); err == nil {
			sum += n
		}
	}

	ctx.Response.Header.Set("Server", "go-fasthttp")
	ctx.SetContentType("text/plain")
	ctx.SetBodyString(strconv.Itoa(sum))
}

func pipelineHandler(ctx *fasthttp.RequestCtx) {
	ctx.Response.Header.Set("Server", "go-fasthttp")
	ctx.SetContentType("text/plain")
	ctx.SetBodyString("ok")
}

func processHandler(ctx *fasthttp.RequestCtx) {
	items := make([]ProcessedItem, len(dataset))
	for i, d := range dataset {
		items[i] = ProcessedItem{
			ID:       d.ID,
			Name:     d.Name,
			Category: d.Category,
			Price:    d.Price,
			Quantity: d.Quantity,
			Active:   d.Active,
			Tags:     d.Tags,
			Rating:   d.Rating,
			Total:    math.Round(d.Price*float64(d.Quantity)*100) / 100,
		}
	}

	resp := ProcessResponse{Items: items, Count: len(items)}
	ctx.Response.Header.Set("Server", "go-fasthttp")
	ctx.SetContentType("application/json")
	body, _ := json.Marshal(resp)
	ctx.SetBody(body)
}

var compressedHandler fasthttp.RequestHandler

func main() {
	loadDataset()
	loadDatasetLarge()

	compressedHandler = fasthttp.CompressHandlerLevel(func(ctx *fasthttp.RequestCtx) {
		ctx.Response.Header.Set("Server", "go-fasthttp")
		ctx.SetContentType("application/json")
		ctx.SetBody(jsonLargeResponse)
	}, flate.BestSpeed)

	handler := func(ctx *fasthttp.RequestCtx) {
		switch string(ctx.Path()) {
		case "/pipeline":
			pipelineHandler(ctx)
		case "/json":
			processHandler(ctx)
		case "/compression":
			compressedHandler(ctx)
		default:
			baseline11Handler(ctx)
		}
	}
	server := &fasthttp.Server{
		Handler: handler,
	}
	server.ListenAndServe(":8080")
}
