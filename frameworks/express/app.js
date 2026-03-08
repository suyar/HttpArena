const express = require('express');
const cluster = require('cluster');
const os = require('os');
const fs = require('fs');

if (cluster.isPrimary) {
    const numCPUs = os.availableParallelism ? os.availableParallelism() : os.cpus().length;
    for (let i = 0; i < numCPUs; i++) cluster.fork();
} else {
    const app = express();
    app.disable('x-powered-by');
    app.set('etag', false);

    // Pre-serialized JSON response
    let jsonResponseBuf;
    const datasetPath = process.env.DATASET_PATH || '/data/dataset.json';
    try {
        const data = JSON.parse(fs.readFileSync(datasetPath, 'utf8'));
        const items = data.map(d => ({
            id: d.id, name: d.name, category: d.category,
            price: d.price, quantity: d.quantity, active: d.active,
            tags: d.tags, rating: d.rating,
            total: Math.round(d.price * d.quantity * 100) / 100
        }));
        jsonResponseBuf = Buffer.from(JSON.stringify({ items, count: items.length }));
    } catch (e) {}

    function sumQuery(query) {
        let sum = 0;
        for (const k in query) {
            const n = parseInt(query[k], 10);
            if (n === n) sum += n;
        }
        return sum;
    }

    app.get('/pipeline', (req, res) => {
        res.writeHead(200, { 'content-type': 'text/plain', 'server': 'express' }).end('ok');
    });

    app.get('/json', (req, res) => {
        if (jsonResponseBuf) {
            res.writeHead(200, {
                'content-type': 'application/json',
                'content-length': jsonResponseBuf.length,
                'server': 'express'
            }).end(jsonResponseBuf);
        } else {
            res.writeHead(500).end('No dataset');
        }
    });

    app.get('/baseline2', (req, res) => {
        res.writeHead(200, { 'content-type': 'text/plain', 'server': 'express' })
           .end(String(sumQuery(req.query)));
    });

    app.all('/baseline11', (req, res) => {
        const querySum = sumQuery(req.query);
        if (req.method === 'POST') {
            let body = '';
            req.on('data', chunk => body += chunk);
            req.on('end', () => {
                let total = querySum;
                const n = parseInt(body.trim(), 10);
                if (n === n) total += n;
                res.writeHead(200, { 'content-type': 'text/plain', 'server': 'express' }).end(String(total));
            });
        } else {
            res.writeHead(200, { 'content-type': 'text/plain', 'server': 'express' }).end(String(querySum));
        }
    });

    const server = app.listen(8080);
    server.keepAliveTimeout = 0;
}
