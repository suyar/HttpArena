Rage.routes.draw do
  get  '/pipeline',    to: 'benchmark#pipeline'
  get  '/baseline11',  to: 'benchmark#baseline_one'
  post '/baseline11',  to: 'benchmark#baseline_one'
  get  '/baseline2',   to: 'benchmark#baseline_two'
  get  '/json',        to: 'benchmark#json_endpoint'
  get  '/compression', to: 'benchmark#compression'
  get  '/db',          to: 'benchmark#db'
  post '/upload',      to: 'benchmark#upload'

  # Catch-all for unknown paths → 404
  get '*', to: 'benchmark#not_found'
end
