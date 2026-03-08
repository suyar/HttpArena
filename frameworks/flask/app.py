import json
import os
import math
from flask import Flask, request, make_response

app = Flask(__name__)
app.config['JSONIFY_PRETTYPRINT_REGULAR'] = False

# Pre-serialize JSON response
json_response = None
dataset_path = os.environ.get('DATASET_PATH', '/data/dataset.json')
try:
    with open(dataset_path) as f:
        data = json.load(f)
    items = []
    for d in data:
        item = dict(d)
        item['total'] = round(d['price'] * d['quantity'] * 100) / 100
        items.append(item)
    json_response = json.dumps({'items': items, 'count': len(items)})
except Exception:
    pass


@app.route('/pipeline')
def pipeline():
    resp = make_response(b'ok')
    resp.content_type = 'text/plain'
    resp.headers['Server'] = 'flask'
    return resp


@app.route('/baseline11', methods=['GET', 'POST'])
def baseline11():
    total = 0
    for v in request.args.values():
        try:
            total += int(v)
        except ValueError:
            pass
    if request.method == 'POST' and request.data:
        try:
            total += int(request.data.strip())
        except ValueError:
            pass
    resp = make_response(str(total))
    resp.content_type = 'text/plain'
    resp.headers['Server'] = 'flask'
    return resp


@app.route('/baseline2')
def baseline2():
    total = 0
    for v in request.args.values():
        try:
            total += int(v)
        except ValueError:
            pass
    resp = make_response(str(total))
    resp.content_type = 'text/plain'
    resp.headers['Server'] = 'flask'
    return resp


@app.route('/json')
def json_endpoint():
    if json_response:
        resp = make_response(json_response)
        resp.content_type = 'application/json'
        resp.headers['Server'] = 'flask'
        return resp
    return 'No dataset', 500
