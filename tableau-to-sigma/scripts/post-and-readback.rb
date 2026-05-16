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
