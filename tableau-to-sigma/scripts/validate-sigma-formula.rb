#!/usr/bin/env ruby
# Validate that a candidate Sigma formula resolves cleanly against a given
# Sigma data-model context. The primitive used by the gap-scout subagent to
# decide whether a proposed translation actually works.
#
# Usage:
#   ruby scripts/validate-sigma-formula.rb \
#     --formula 'MovingAvg(Sum([Master/Sales]), -10, 10)' \
#     --data-model-id <dm-id> \
#     --master-element-id <element-id>  \
#     [--folder-id <folder-id>] \
#     [--chart-kind bar-chart|line-chart|table]
#
# What it does:
#   1. Builds a tiny Sigma workbook spec with:
#      - Data page: a master table pulling from the supplied DM element
#      - Test page: a single chart that uses the candidate formula as a column
#   2. POSTs to /v2/workbooks/spec
#   3. Reads /v2/workbooks/{id}/elements/{el}/columns and checks for
#      type.type == "error"
#   4. Emits a JSON result to stdout (machine-parseable):
#        { "status": "ok" | "error",
#          "workbook_id": "...",
#          "error_columns": [{ "label": "...", "err": {...} }],
#          "spec_used": {...} }
#
# Env: requires SIGMA_BASE_URL, SIGMA_CLIENT_ID, SIGMA_CLIENT_SECRET
# (the same as post-and-readback.rb)

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'base64'
require 'optparse'

opts = {
  chart_kind: 'table',
  folder_id: nil
}
OptionParser.new do |p|
  p.on('--formula F')             { |v| opts[:formula] = v }
  p.on('--data-model-id ID')      { |v| opts[:dm_id] = v }
  p.on('--master-element-id ID')  { |v| opts[:el_id] = v }
  p.on('--folder-id ID')          { |v| opts[:folder_id] = v }
  p.on('--chart-kind K')          { |v| opts[:chart_kind] = v }
  p.on('--label L')               { |v| opts[:label] = v }
end.parse!
%i[formula dm_id el_id].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }

BASE = ENV.fetch('SIGMA_BASE_URL')
CID  = ENV.fetch('SIGMA_CLIENT_ID')
CSEC = ENV.fetch('SIGMA_CLIENT_SECRET')

# --- Auth -----------------------------------------------------------------
def get_token
  uri = URI("#{BASE}/v2/auth/token")
  req = Net::HTTP::Post.new(uri)
  req['Authorization'] = "Basic #{Base64.strict_encode64("#{CID}:#{CSEC}")}"
  req['Content-Type']  = 'application/x-www-form-urlencoded'
  req.body = 'grant_type=client_credentials'
  resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  JSON.parse(resp.body).fetch('access_token')
end
BASE; TOK = get_token

def http(method, path, body: nil, accept_json: true)
  uri = URI("#{BASE}#{path}")
  req = case method
        when :post then r = Net::HTTP::Post.new(uri); r.body = body; r['Content-Type'] = 'application/json'; r
        when :get  then Net::HTTP::Get.new(uri)
        end
  req['Authorization'] = "Bearer #{TOK}"
  req['Accept']        = 'application/json' if accept_json
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
end

# --- Build the test spec ---------------------------------------------------
formula = opts[:formula]
label   = opts[:label] || 'scout-test-col'

# Master needs at least one column to be valid — use a passthrough on whatever
# the DM element exposes. We don't know its specific columns up front; the
# scout caller should already know that [Master/X] refs in the formula resolve
# against the DM's columns. To validate, we POST and read back the chart's
# column types.

master_el = {
  'id'   => 'master',
  'kind' => 'table',
  'name' => 'Master',
  'source' => { 'kind' => 'data-model', 'dataModelId' => opts[:dm_id], 'elementId' => opts[:el_id] },
  # We need at least one master column; pull the first one by referencing a
  # generic field. We can't know the field name without inspecting the DM, so
  # we expect the caller to embed [Master/<col>] in the formula and let Sigma
  # complain at validation time if the column doesn't exist. The master
  # element here just needs to exist with some passthrough column so cross-
  # element refs from the test chart can resolve.
  'columns' => [
    { 'id' => 'm-passthrough', 'formula' => 'RowNumber()', 'name' => 'PassThrough' }
  ],
  'visibleAsSource' => false
}

test_el = {
  'id'   => 'el-scout-test',
  'kind' => opts[:chart_kind],
  'name' => 'Scout test',
  'source' => { 'kind' => 'table', 'elementId' => 'master' },
  'columns' => [
    { 'id' => 'col-scout-test', 'name' => label, 'formula' => formula }
  ]
}

spec = {
  'name'           => "[scout-test] #{label}-#{Time.now.to_i}",
  'schemaVersion'  => 1,
  'pages' => [
    { 'id' => 'page-data', 'name' => 'Data', 'elements' => [master_el] },
    { 'id' => 'page-test', 'name' => 'Test', 'elements' => [test_el] }
  ]
}
spec['folderId'] = opts[:folder_id] if opts[:folder_id]

# --- POST + readback -------------------------------------------------------
resp = http(:post, '/v2/workbooks/spec', body: JSON.generate(spec))
parsed = (YAML.safe_load(resp.body, permitted_classes: [Date, Time]) rescue nil)
parsed ||= (JSON.parse(resp.body) rescue { 'raw' => resp.body })

wb_id = parsed.is_a?(Hash) && parsed['workbookId']
unless wb_id
  puts JSON.pretty_generate({
    'status' => 'error',
    'phase'  => 'post',
    'workbook_id' => nil,
    'error'  => parsed,
    'spec_used' => spec
  })
  exit 1
end

# Walk both elements; we mostly care about the test element
cols_resp = http(:get, "/v2/workbooks/#{wb_id}/elements/el-scout-test/columns")
cols_data = JSON.parse(cols_resp.body)
entries = cols_data['entries'] || []
error_cols = entries.select do |c|
  t = c['type']
  tt = t.is_a?(Hash) ? t['type'] : t
  tt == 'error'
end

status = error_cols.empty? ? 'ok' : 'error'
puts JSON.pretty_generate({
  'status'        => status,
  'phase'         => 'columns',
  'workbook_id'   => wb_id,
  'error_columns' => error_cols.map { |c| { 'label' => c['label'], 'formula' => c['formula'], 'err' => c['type'] } },
  'all_columns'   => entries.map { |c| { 'label' => c['label'], 'type' => (c['type'].is_a?(Hash) ? c['type']['type'] : c['type']) } },
  'spec_used'     => spec
})

exit(status == 'ok' ? 0 : 2)
