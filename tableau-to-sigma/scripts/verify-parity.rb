#!/usr/bin/env ruby
# Parity verification: compare expected (from Tableau CSVs) vs actual
# (from Sigma queries) for each chart in a plan. Pure diff/report — the
# caller pre-supplies actuals via the "actual" key OR the script can fetch
# via env-configured Sigma auth.
#
# Plan format (JSON array):
#   [{ "chart": "...",
#      "expected": [[dim, val], ...],
#      "actual":   { "rows": [[dim, val], ...] } }]
#
# Usage:
#   ruby verify-parity.rb --plan <plan.json>

require 'json'
require 'set'
require 'optparse'

opts = {}
OptionParser.new { |p| p.on('--plan P') { |v| opts[:plan] = v } }.parse!
abort('--plan required') unless opts[:plan]

# Lazy env load: only abort on missing token if any plan entry lacks "actual"
def assert_env_for_queries
  return if @env_checked
  %w[SIGMA_BASE_URL SIGMA_API_TOKEN].each do |k|
    ENV[k] or abort("missing env var #{k} — needed when plan entries don't include 'actual'")
  end
  @env_checked = true
end

def query_workbook(wb, sql)
  assert_env_for_queries
  require 'net/http'; require 'uri'
  uri = URI("#{ENV['SIGMA_BASE_URL']}/v2/workbooks/#{wb}/query")
  req = Net::HTTP::Post.new(uri)
  req['Authorization'] = "Bearer #{ENV['SIGMA_API_TOKEN']}"
  req['Accept']        = 'application/json'
  req['Content-Type']  = 'application/json'
  req.body = { sql: sql }.to_json
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  JSON.parse(res.body) rescue { 'error' => res.body }
end

def round_row(row)
  row.map { |v| v.is_a?(Numeric) ? v.round(2) : v }
end

plan = JSON.parse(File.read(opts[:plan]))
results = plan.map do |p|
  actual = p['actual'] || query_workbook(p['workbookId'], p['sql'])
  exp  = (p['expected']         || []).map { |r| round_row(r) }
  act  = (actual['rows']        || []).map { |r| round_row(r) }
  exp_set = Set.new(exp.map { |r| r.first(2) })
  act_set = Set.new(act.map { |r| r.first(2) })
  status = (exp_set == act_set ? 'PASS' : 'DIVERGE')
  { chart: p['chart'], status: status,
    only_in_tableau: (exp_set - act_set).to_a,
    only_in_sigma:   (act_set - exp_set).to_a }
end

results.each do |r|
  printf "%-7s  %s\n", r[:status], r[:chart]
  unless r[:status] == 'PASS'
    puts "  Tableau-only: #{r[:only_in_tableau].inspect[0..200]}"
    puts "  Sigma-only:   #{r[:only_in_sigma].inspect[0..200]}"
  end
end

failed = results.count { |r| r[:status] != 'PASS' }
puts "---"
puts "#{results.size - failed}/#{results.size} pass"
exit(failed.zero? ? 0 : 1)
