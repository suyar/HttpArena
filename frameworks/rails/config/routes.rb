Rails.application.routes.draw do
  get  '/pipeline',    to: 'benchmark#pipeline'
  get  '/baseline11',  to: 'benchmark#baseline11'
  post '/baseline11',  to: 'benchmark#baseline11'
  get  '/baseline2',   to: 'benchmark#baseline2'
  get  '/json',        to: 'benchmark#json_endpoint'
  get  '/compression', to: 'benchmark#compression'
  get  '/db',          to: 'benchmark#db'
  post '/upload',      to: 'benchmark#upload'

  # Catch-all for unknown paths → 404
  match '*path', to: 'benchmark#not_found', via: :all
end
