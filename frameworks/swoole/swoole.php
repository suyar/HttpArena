<?php

use Swoole\Http\Server;
use Swoole\Http\Request;
use Swoole\Http\Response;

require __DIR__ . '/SQLite.php';
require __DIR__ . '/PostgreSQL.php';

$dataset = json_decode(file_get_contents('/data/dataset.json'), true);

$data = json_decode(file_get_contents('/data/dataset-large.json'), true);
foreach ($data as &$item) {
    $item['total'] = $item['price'] * $item['quantity'];
}
$largeJson = json_encode(['items' => $data, 'count' => count($data)], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);

const MIME_TYPES = [
    'css'   => "text/css",
    'js'    => "application/javascript",
    'html'  => "text/html",
    'woff2' => "font/woff2",
    'svg'   => "image/svg+xml",
    'webp'  => "image/webp",
    'json'  => "application/json"
];

$files = [];
$dir   = new DirectoryIterator('/data/static');
foreach ($dir as $fileInfo) {
    if (!$fileInfo->isDot()) {
        $files['/static/' . $fileInfo->getFilename()] = [
            file_get_contents($fileInfo->getPathname()),
            MIME_TYPES[pathinfo($fileInfo->getFilename(), PATHINFO_EXTENSION)] ?? 'application/octet-stream'
        ];
    }
}

$http = new Server('0.0.0.0', 8080);
$http->set([
    'worker_num'             => swoole_cpu_num(),
    'enable_reuse_port'      => true,
    'enable_coroutine'       => false,
    'package_max_length'     => 30 * 1024 * 1024,
    'http_compression_level' => 1
]);

$http->on('workerStart', function (Server $server, int $workerId) {
    SQLite::init();
    PostgreSQL::init();
});

$http->on('request', function (Request $request, Response $response) use ($dataset, $largeJson, $files) {
    $path = $request->server['request_uri'];
    switch ($path) {
        case '/pipeline':
            $response->header['Content-Type'] = 'text/plain';
            $response->end('ok');
            return;

        case '/baseline2':
        case '/baseline11':
            $sum = array_sum($request->get);
            if ($request->server['request_method'] === 'POST') {
                $sum += (int)$request->getContent();
            }

            $response->header['Content-Type'] = 'text/plain';
            $response->end($sum);
            return;

        case '/json':
            $total = [];
            foreach ($dataset as $item) {
                $item['total'] = $item['price'] * $item['quantity'];
                $total[]       = $item;
            }

            $response->header['Content-Type'] = 'application/json';
            $response->end(json_encode(['items' => $total, 'count' => count($total)], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
            return;

        case '/upload':
            $response->header['Content-Type'] = 'text/plain';
            $response->end(strlen($request->getContent()));
            return;

        case '/compression':
            $response->header['Content-Type'] = 'application/json';
            $response->end($largeJson);
            return;

        case '/db':
            $response->header['Content-Type'] = 'application/json';
            $min                              = $request->get['min'] ?? 10;
            $max                              = $request->get['max'] ?? 50;
            $response->end(SQLite::query($min, $max));
            return;

        case '/async-db':
            $response->header['Content-Type'] = 'application/json';
            $min                              = $request->get['min'] ?? 10;
            $max                              = $request->get['max'] ?? 50;
            $response->end(PostgreSQL::query($min, $max));
            return;
    }

    if (str_starts_with($path, '/static/')) {
        if (isset($files[$path])) {
            $response->header['Content-Type'] = $files[$path][1];
            $response->end($files[$path][0]);
            return;
        }
    }

    $response->status(404);
    $response->header['Content-Type'] = 'text/plain';
    $response->end('404 Not Found');
});

$port = $http->listen('0.0.0.0', 8443, SWOOLE_TCP | SWOOLE_SSL);
$port->set([
    'open_http2_protocol'    => true,
    'ssl_cert_file'          => '/certs/server.crt',
    'ssl_key_file'           => '/certs/server.key',
    'package_max_length'     => 30 * 1024 * 1024,
    'http_compression_level' => 1,
]);

$http->start();
