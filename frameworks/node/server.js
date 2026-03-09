const http = require('http');
const http2 = require('http2');
const cluster = require('cluster');
const os = require('os');
const fs = require('fs');

const zlib = require('zlib');

const SERVER_HEADERS = { 'server': 'node' };

// Pre-serialized JSON response buffer
let jsonResponseBuf;

// Pre-loaded static files
const staticFiles = {};
const MIME_TYPES = {
    '.css': 'text/css', '.js': 'application/javascript', '.html': 'text/html',
    '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.json': 'application/json'
};

function loadStaticFiles() {
    const dir = '/data/static';
    try {
        for (const name of fs.readdirSync(dir)) {
            const buf = fs.readFileSync(dir + '/' + name);
            const ext = name.slice(name.lastIndexOf('.'));
            staticFiles[name] = { buf, ct: MIME_TYPES[ext] || 'application/octet-stream' };
        }
    } catch (e) {}
}

function loadDataset() {
    const path = process.env.DATASET_PATH || '/data/dataset.json';
    try {
        const data = JSON.parse(fs.readFileSync(path, 'utf8'));
        const items = data.map(d => ({
            id: d.id, name: d.name, category: d.category,
            price: d.price, quantity: d.quantity, active: d.active,
            tags: d.tags, rating: d.rating,
            total: Math.round(d.price * d.quantity * 100) / 100
        }));
        jsonResponseBuf = Buffer.from(JSON.stringify({ items, count: items.length }));
    } catch (e) {}
}

function sumQuery(url) {
    const q = url.indexOf('?');
    if (q === -1) return 0;
    let sum = 0;
    const qs = url.slice(q + 1);
    let i = 0;
    while (i < qs.length) {
        const eq = qs.indexOf('=', i);
        if (eq === -1) break;
        let amp = qs.indexOf('&', eq);
        if (amp === -1) amp = qs.length;
        const n = parseInt(qs.slice(eq + 1, amp), 10);
        if (n === n) sum += n; // NaN check
        i = amp + 1;
    }
    return sum;
}

const server = http.createServer((req, res) => {
    const url = req.url;
    const q = url.indexOf('?');
    const path = q === -1 ? url : url.slice(0, q);

    if (path === '/pipeline') {
        res.writeHead(200, { 'content-type': 'text/plain', ...SERVER_HEADERS });
        res.end('ok');
    } else if (path === '/json') {
        if (jsonResponseBuf) {
            res.writeHead(200, {
                'content-type': 'application/json',
                'content-length': jsonResponseBuf.length,
                ...SERVER_HEADERS
            });
            res.end(jsonResponseBuf);
        } else {
            res.writeHead(500);
            res.end('No dataset');
        }
    } else if (path === '/baseline2') {
        const body = String(sumQuery(url));
        res.writeHead(200, { 'content-type': 'text/plain', ...SERVER_HEADERS });
        res.end(body);
    } else if (path === '/caching') {
        const inm = req.headers['if-none-match'];
        if (inm === '"AOK"') {
            res.writeHead(304, { 'etag': '"AOK"', ...SERVER_HEADERS });
            res.end();
        } else {
            res.writeHead(200, { 'content-type': 'text/plain', 'etag': '"AOK"', 'content-length': 2, ...SERVER_HEADERS });
            res.end('OK');
        }
    } else if (path === '/upload' && req.method === 'POST') {
        const chunks = [];
        req.on('data', chunk => chunks.push(chunk));
        req.on('end', () => {
            const buf = Buffer.concat(chunks);
            const crc = zlib.crc32(buf);
            res.writeHead(200, { 'content-type': 'text/plain', ...SERVER_HEADERS });
            res.end((crc >>> 0).toString(16).padStart(8, '0'));
        });
    } else {
        // /baseline11 — GET or POST
        const querySum = sumQuery(url);
        if (req.method === 'POST') {
            let body = '';
            req.on('data', chunk => body += chunk);
            req.on('end', () => {
                let total = querySum;
                const n = parseInt(body.trim(), 10);
                if (n === n) total += n;
                res.writeHead(200, { 'content-type': 'text/plain', ...SERVER_HEADERS });
                res.end(String(total));
            });
        } else {
            res.writeHead(200, { 'content-type': 'text/plain', ...SERVER_HEADERS });
            res.end(String(querySum));
        }
    }
});

server.keepAliveTimeout = 0;

// HTTP/2 TLS server on port 8443
function startH2() {
    const certFile = process.env.TLS_CERT || '/certs/server.crt';
    const keyFile = process.env.TLS_KEY || '/certs/server.key';
    try {
        const opts = {
            cert: fs.readFileSync(certFile),
            key: fs.readFileSync(keyFile),
            allowHTTP1: false,
        };
        const h2server = http2.createSecureServer(opts, (req, res) => {
            const url = req.url;
            const q = url.indexOf('?');
            const p = q === -1 ? url : url.slice(0, q);
            if (p.startsWith('/static/')) {
                const name = p.slice(8);
                const sf = staticFiles[name];
                if (sf) {
                    res.writeHead(200, { 'content-type': sf.ct, 'content-length': sf.buf.length, 'server': 'node' });
                    res.end(sf.buf);
                } else {
                    res.writeHead(404);
                    res.end();
                }
            } else {
                const sum = sumQuery(url);
                res.writeHead(200, { 'content-type': 'text/plain', 'server': 'node' });
                res.end(String(sum));
            }
        });
        h2server.listen(8443);
    } catch (e) {
        // TLS certs not available, skip H2
    }
}

if (cluster.isPrimary) {
    const numCPUs = os.availableParallelism ? os.availableParallelism() : os.cpus().length;
    for (let i = 0; i < numCPUs; i++) cluster.fork();
} else {
    loadDataset();
    loadStaticFiles();
    server.listen(8080);
    startH2();
}
