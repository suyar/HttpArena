# frozen_string_literal: true

require 'zlib'

class BenchmarkController < RageController::API
  # Pre-load datasets at class level (shared across workers via preload)
  DATASET_PATH = ENV.fetch('DATASET_PATH', '/data/dataset.json')
  LARGE_DATASET_PATH = '/data/dataset-large.json'

  @db_available = File.exist?('/data/benchmark.db')

  if File.exist?(DATASET_PATH)
    @dataset_items = JSON.parse(File.read(DATASET_PATH))
  end

  if File.exist?(LARGE_DATASET_PATH)
    raw = JSON.parse(File.read(LARGE_DATASET_PATH))
    items = raw.map { |d| d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0) }
    @large_json_payload = JSON.generate({ 'items' => items, 'count' => items.length })
  end

  DB_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50'

  def self.db_available = @db_available
  def self.large_json_payload = @large_json_payload
  def self.dataset_items = @dataset_items

  before_action do
    headers["server"] = "rage"
  end

  def pipeline
    render plain: 'ok'
  end

  def baseline_one
    total = 0
    params.each_value do |v|
      total += v.to_i
    end
    if request.post?
      rack_input = request.send(:rack_request).env["rack.input"]
      body_str = rack_input.read.strip
      total += body_str.to_i
    end
    render plain: total.to_s
  end

  def baseline_two
    total = 0
    params.each_value do |v|
      total += v.to_i
    end
    render plain: total.to_s
  end

  def json_endpoint
    if self.class.dataset_items
      items = self.class.dataset_items.map { |d| d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0) }
      render json: { 'items' => items, 'count' => items.length }
    else
      head 500
    end
  end

  def compression
    if self.class.large_json_payload
      sio = StringIO.new
      gz = Zlib::GzipWriter.new(sio, 1)
      gz.write(self.class.large_json_payload)
      gz.close
      response.headers['Content-Type'] = 'application/json'
      response.headers['Content-Encoding'] = 'gzip'
      render plain: sio.string
    else
      head 500
    end
  end

  def db
    unless self.class.db_available
      render json: { items: [], count: 0 }
      return
    end

    min_val = (params[:min] || 10).to_f
    max_val = (params[:max] || 50).to_f
    conn = get_db
    rows = conn.execute(DB_QUERY, [min_val, max_val])
    items = rows.map do |r|
      {
        'id' => r['id'], 'name' => r['name'], 'category' => r['category'],
        'price' => r['price'], 'quantity' => r['quantity'], 'active' => r['active'] == 1,
        'tags' => JSON.parse(r['tags']),
        'rating' => { 'score' => r['rating_score'], 'count' => r['rating_count'] }
      }
    end
    render json: { items: items, count: items.length }
  end

  def upload
    rack_input = request.send(:rack_request).env["rack.input"]
    rack_input.rewind
    size = 0
    while (chunk = rack_input.read(65536))
      size += chunk.bytesize
    end
    render plain: size.to_s
  end

  def not_found
    head 404
  end

  private

  def get_db
    Thread.current[:rage_db] ||= begin
      db = SQLite3::Database.new('/data/benchmark.db', readonly: true)
      db.execute('PRAGMA mmap_size=268435456')
      db.results_as_hash = true
      db
    end
  end
end
