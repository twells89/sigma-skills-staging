#!/usr/bin/env ruby
# Build a parity plan automatically by matching Tableau view CSVs to Sigma
# workbook chart elements.
#
# Inputs:
#   --tableau /tmp/<name>           directory with get-workbook.json + views/<viewId>.csv
#   --workbook-spec wb-spec.json    Sigma workbook spec (after Phase 5c readback OR a manual write)
#                                   — used to pull element IDs, kinds, and column IDs
#   --out parity-plan.json          output plan (wrapped: { extract: bool, charts: [...] })
#
# Optional:
#   --rename CHART_FROM=CHART_TO    when the Sigma chart was renamed from the original Tableau title
#                                   (e.g., "Order Channel vs Ship Method=Orders by Category")
#                                   — repeatable
#
# Matching heuristic: Sigma element name == Tableau view name (exact), then loose match
# (strip punctuation, lowercase). Sigma kinds and Tableau chart_kinds are recorded for context.
#
# After running this, the agent fetches Sigma actuals via MCP or REST and edits the plan to
# add an "actual" key per chart, then runs verify-parity.rb.
#
# Or, if the SIGMA_API_TOKEN env path works, this script can pre-fetch Sigma actuals via the
# workbook query API and populate "actual" inline (best-effort; skip silently on failure).

require 'json'
require 'csv'
require 'optparse'
require 'net/http'
require 'uri'

opts = { renames: {} }
OptionParser.new do |p|
  p.on('--tableau DIR')          { |v| opts[:tab] = v }
  p.on('--workbook-spec PATH')   { |v| opts[:wb]  = v }
  p.on('--out PATH')             { |v| opts[:out] = v }
  p.on('--workbook-id ID')       { |v| opts[:wb_id] = v }
  p.on('--rename PAIR')          { |v| from, to = v.split('=', 2); opts[:renames][from] = to }
  p.on('--no-fetch')             {     opts[:no_fetch] = true }
end.parse!
abort('usage: --tableau DIR --workbook-spec FILE --out FILE [--workbook-id ID] [--rename A=B]') unless opts[:tab] && opts[:wb] && opts[:out]

# Load Tableau side: workbook metadata (for extract flag + view name → view id map) + CSVs
gw = JSON.parse(File.read(File.join(opts[:tab], 'get-workbook.json')))
views = gw.dig('views', 'view') || []
views = [views] unless views.is_a?(Array)

# hasExtracts on the workbook OR on the underlying datasource
extract = false
if gw['hasExtracts'] == true || gw['hasExtracts'] == 'true'
  extract = true
end
# Tableau Cloud often surfaces extracts on the workbook search result, not the get-workbook
# response — caller can re-flag via the --extract-mode CLI flag on verify-parity.rb.

view_by_name = views.each_with_object({}) { |v, h| h[v['name']] = v }

# Load Sigma side
spec = JSON.parse(File.read(opts[:wb]))
sigma_charts = []
spec['pages'].each do |pg|
  pg['elements'].each do |e|
    next unless e['source'] && e['source']['elementId'] == 'master'
    sigma_charts << e
  end
end

# Match Sigma chart → Tableau view
def normalize(s)
  s.to_s.downcase.gsub(/[^a-z0-9]/, '')
end

# Build reverse-rename map: tableau-name → sigma-name was the input;
# we want sigma-name → tableau-name for lookup.
rev_renames = opts[:renames].each_with_object({}) { |(k, v), h| h[v] = k }

plan_entries = []
sigma_charts.each do |el|
  sigma_name = el['name']
  tableau_name = rev_renames[sigma_name] || sigma_name

  view = view_by_name[tableau_name]
  view ||= view_by_name.find { |n, _| normalize(n) == normalize(tableau_name) }&.last
  if view.nil?
    warn "no Tableau view matched Sigma chart #{sigma_name.inspect} (try --rename '<Tableau title>=#{sigma_name}')"
    next
  end

  csv_path = File.join(opts[:tab], 'views', "#{view['id']}.csv")
  unless File.exist?(csv_path)
    warn "missing CSV at #{csv_path} for #{sigma_name.inspect}"
    next
  end

  rows = CSV.read(csv_path)
  next if rows.empty?
  header = rows.shift
  expected_rows = rows.map do |r|
    r.map.with_index do |v, i|
      next nil if v.nil? || v.to_s.strip.empty?
      i == 0 ? v : (begin Float(v.to_s.gsub(',', '')) rescue v end)
    end
  end

  cols = (el['columns'] || []).map { |c| c['id'] }
  entry = {
    'chart'       => sigma_name,
    'tableau_view' => tableau_name,
    'sigma_element_id' => el['id'],
    'sigma_kind'  => el['kind'],
    'sigma_columns' => cols.first(2),       # most charts: dim + measure
    'expected'    => expected_rows
  }
  if opts[:wb_id] && cols.size >= 2
    entry['sql_template'] = %(SELECT "#{cols[0]}", "#{cols[1]}" FROM "workbook"."#{el['id']}" ORDER BY 1)
    entry['workbookId'] = opts[:wb_id]
  end
  plan_entries << entry
end

# Optional: pre-fetch actuals via Sigma REST workbook query endpoint.
# Parallel-fire with 5 threads + Cloudflare-429 exponential backoff (same
# envelope as find-or-pick-dm.rb / verify-workbook.rb). beads-sigma-94e.
# Measured pattern: 5 sequential queries × ~20s each = ~100s; parallel
# should bring this to ~25-30s (bounded by slowest single query).
unless opts[:no_fetch]
  if ENV['SIGMA_API_TOKEN'] && ENV['SIGMA_BASE_URL'] && opts[:wb_id]
    require 'thread'
    queue = Queue.new
    plan_entries.each { |e| queue << e if e['sql_template'] }

    threads = 5.times.map do
      Thread.new do
        until queue.empty?
          entry = queue.pop(true) rescue nil
          break unless entry
          uri = URI("#{ENV['SIGMA_BASE_URL']}/v2/workbooks/#{opts[:wb_id]}/query")
          4.times do |attempt|
            req = Net::HTTP::Post.new(uri,
                    'Authorization' => "Bearer #{ENV['SIGMA_API_TOKEN']}",
                    'Accept'        => 'application/json',
                    'Content-Type'  => 'application/json')
            req.body = { sql: entry['sql_template'] }.to_json
            begin
              res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
              code = res.code.to_i
              if res.is_a?(Net::HTTPSuccess)
                parsed = JSON.parse(res.body) rescue {}
                entry['actual'] = { 'rows' => parsed['rows'] } if parsed['rows']
                break
              elsif code == 429 || code >= 500
                sleep 0.5 * (2 ** attempt)   # 0.5, 1, 2, 4s
              else
                break
              end
            rescue StandardError
              break  # silent — actuals can be added manually
            end
          end
        end
      end
    end
    threads.each(&:join)
  end
end

# Wrap output
output = { 'extract' => extract, 'charts' => plan_entries }
File.write(opts[:out], JSON.pretty_generate(output))

puts "wrote #{opts[:out]}"
puts "  charts matched: #{plan_entries.size}"
puts "  extract flag:   #{extract}"
prefetched = plan_entries.count { |e| e['actual'] }
puts "  actuals pre-fetched: #{prefetched}/#{plan_entries.size}#{prefetched.zero? ? '  (paste actuals manually via mcp__sigma-mcp-v2__query, or run with --workbook-id and a healthy Sigma REST query endpoint)' : ''}"
