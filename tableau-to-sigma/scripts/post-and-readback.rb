#!/usr/bin/env ruby
# POST a DM or workbook spec, parse the YAML response, then GET the spec back
# and emit a clean JSON map of pages → elements with server-assigned IDs.
#
# Usage:
#   ruby post-and-readback.rb --type datamodel|workbook --spec <spec.json> --out <id-map.json>

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'date'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--type T', %w[datamodel workbook]) { |v| opts[:type] = v }
  p.on('--spec P')                         { |v| opts[:spec] = v }
  p.on('--out P')                          { |v| opts[:out]  = v }
end.parse!
%i[type spec out].each { |k| abort("missing --#{k}") unless opts[k] }

BASE = ENV.fetch('SIGMA_BASE_URL')
TOK  = ENV.fetch('SIGMA_API_TOKEN')

POST_PATH = opts[:type] == 'datamodel' ? '/v2/dataModels/spec'              : '/v2/workbooks/spec'
GET_PATH  = opts[:type] == 'datamodel' ? '/v2/dataModels/%s/spec'           : '/v2/workbooks/%s/spec'
ID_FIELD  = opts[:type] == 'datamodel' ? 'dataModelId'                      : 'workbookId'

def http(method, path, body = nil, accept_json: false)
  uri = URI("#{BASE}#{path}")
  req = case method
        when :post then r = Net::HTTP::Post.new(uri); r.body = body; r['Content-Type'] = 'application/json'; r
        when :get  then Net::HTTP::Get.new(uri)
        end
  req['Authorization'] = "Bearer #{TOK}"
  req['Accept']        = 'application/json' if accept_json
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
end

resp = http(:post, POST_PATH, File.read(opts[:spec]))
parsed = YAML.safe_load(resp.body, permitted_classes: [Date, Time])
oid = parsed[ID_FIELD] or abort("POST failed: #{parsed.inspect}")
warn "POST ok: #{ID_FIELD}=#{oid}"

# Read back
spec = JSON.parse(http(:get, format(GET_PATH, oid), accept_json: true).body)
out = {
  ID_FIELD => oid,
  'pages'  => spec.fetch('pages', []).map do |p|
    {
      'id'       => p['id'],
      'name'     => p['name'],
      'visibility' => p['visibility'],
      'elements' => (p['elements'] || []).map { |e| { 'id' => e['id'], 'kind' => e['kind'], 'name' => e['name'] } }
    }
  end
}
File.write(opts[:out], JSON.pretty_generate(out))
puts JSON.pretty_generate(out)

# Universal silent-error guard: scan every column's resolved type via the
# `/columns` endpoint and fail loudly on any column with type `error`.
#
# A column ends up "error" when the formula compiles successfully against the
# validator but fails at runtime. Typical causes:
#   - Referenced column doesn't exist (typo)
#   - Function doesn't exist in Sigma (e.g., IsIn — see memory feedback_sigma_formula_isin.md)
#   - Window aggregate used in calc-column context (validate-spec catches the known
#     function names; this catches anything else that produces an error type)
#   - Cross-element ref without a Lookup wrapper (compiles, returns NULL forever — actually
#     resolves as the column's declared type, not "error", so this guard misses it; that's
#     why refs/data-model-spec.md has its own callout)
#
# Endpoint: GET /v2/{dataModels|workbooks}/<id>/columns — returns one entry per
# column with `type.type` resolved. Scan for type == "error".

columns_path = opts[:type] == 'datamodel' ?
  "/v2/dataModels/#{oid}/columns" :
  "/v2/workbooks/#{oid}/columns"

res = http(:get, columns_path, accept_json: true)
if res.is_a?(Net::HTTPSuccess)
  cols_json = JSON.parse(res.body) rescue { 'entries' => [] }
  error_columns = (cols_json['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }
  if error_columns.any?
    warn "\n========================================"
    warn "FAIL — #{error_columns.size} column(s) compiled to type \"error\":"
    error_columns.each do |c|
      warn "  [element=#{c['elementId']}] #{c['label']} (#{c['columnId']}):"
      warn "    formula: #{c['formula']}"
    end
    warn 'Fix these formulas before continuing — Phase 6 parity would fail downstream.'
    warn 'Common causes: typo in a column ref, IsIn() / non-existent function, window'
    warn 'aggregate in a calc column (use a Custom SQL element instead — see Phase 3).'
    warn '========================================'
    exit(2)
  else
    total = (cols_json['entries'] || []).size
    warn "column-type guard: #{total} columns clean (no `error` types)"
  end
else
  warn "WARN: could not fetch /columns for type guard (got HTTP #{res.code}); skipping"
end
