#!/usr/bin/env ruby
# build-workbook-from-pbir.rb — map normalized PBIR signals -> Sigma workbook spec.
#
# Power BI analog of tableau-to-sigma's build-charts-from-signals.rb. Input is
# extract-pbir.py's signals.json (per-visual kind + role bindings + position).
# Output is a complete Sigma workbook spec (Data page of hidden masters + a
# page of chart elements) ready for POST /v2/workbooks/spec via
# post-and-readback.rb, plus a 24-col grid layout string for put-layout.rb.
#
# It applies the measure-translation patterns documented in
# refs/measure-patterns.md:
#   - line charts default to a SINGLE series (no color split) unless a Series/
#     Legend role is bound (beads-sigma-c07);
#   - PBI measure refs ("EMPLOYEES.Total Salary") map to a measure formula via a
#     measure-map (Sum/Count/CountDistinct/…); dimensions map to bare/master refs;
#   - kpi/bar/line/pie/donut/table/pivot-table element shapes per spec-fixups.md.
#
# Usage:
#   ruby scripts/build-workbook-from-pbir.rb \
#     --signals /tmp/pbir/signals.json \
#     --master-map /tmp/pbir/master-map.json \
#     --data-model <dataModelId> \
#     --out /tmp/pbir/workbook-spec.json \
#     --layout-out /tmp/pbir/layout.xml \
#     [--name "Workforce KitchenSink (from Power BI)"] \
#     [--folder-id <uuid>]
#
# master-map.json shape — maps each PBI "Entity" to a Data-page master table and
# each "Entity.Field" queryRef to {ref, agg}. `ref` is the Sigma column path
# (e.g. "[EMP/Annual Salary]"); `agg` is the Sigma aggregator name for measures
# (Sum/Count/CountDistinct/Avg/Min/Max) or null for a dimension. Example:
#   {
#     "masters": {
#       "EMP": {"id":"master-emp","element_id":"<dmElementId>","data_model":"<dmId>",
#               "columns":[{"id":"me-salary","name":"Annual Salary","formula":"[EMPLOYEES/Annual Salary]"}, ...]}
#     },
#     "fields": {
#       "EMPLOYEES.DEPARTMENT":   {"master":"EMP","ref":"[EMP/Department]","agg":null},
#       "EMPLOYEES.Total Salary": {"master":"EMP","ref":"[EMP/Annual Salary]","agg":"Sum"},
#       "EMPLOYEES.Headcount":    {"master":"EMP","ref":"[EMP/Employee Id]","agg":"Count"},
#       "SAFETY_INCIDENTS.Incident Count": {"master":"INC","ref":"[INC/Incident Id]","agg":"CountDistinct"}
#     }
#   }
#
# The master-map is the one PBI-specific artifact the agent authors (it encodes
# the DM element ids + the DAX-measure→Sigma-aggregator decisions). Everything
# else is mechanical. Idempotent: deterministic ids from visual_id, re-runnable.

require 'json'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--signals PATH')     { |v| opts[:sig] = v }
  p.on('--master-map PATH')  { |v| opts[:mmap] = v }
  p.on('--data-model ID')    { |v| opts[:dm] = v }
  p.on('--out PATH')         { |v| opts[:out] = v }
  p.on('--layout-out PATH')  { |v| opts[:layout_out] = v }
  p.on('--name NAME')        { |v| opts[:name] = v }
  p.on('--folder-id ID')     { |v| opts[:folder] = v }
end.parse!
%i[sig mmap out].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }

signals = JSON.parse(File.read(opts[:sig]))
mmap    = JSON.parse(File.read(opts[:mmap]))
fields  = mmap['fields'] || {}
masters = mmap['masters'] || {}

SIGMA_KIND = {
  'kpi' => 'kpi-chart', 'bar' => 'bar-chart', 'line' => 'line-chart',
  'area' => 'area-chart', 'combo' => 'combo-chart', 'scatter' => 'scatter-chart',
  'pie' => 'pie-chart', 'donut' => 'donut-chart',
  'table' => 'table', 'pivot-table' => 'pivot-table', 'text' => 'text'
}.freeze

# PBI role -> (dim_role?, value_role?) per visual kind handled below.
def field_spec(queryref, fields)
  fields[queryref] || { 'master' => nil, 'ref' => "[#{queryref}]", 'agg' => nil }
end

def measure_formula(fs)
  agg = fs['agg']
  return fs['ref'] if agg.nil? || agg.empty?
  "#{agg}(#{fs['ref']})"
end

# Deterministic, collision-free short id from a PBIR visual id. PBIR visual ids
# often share a long common prefix (e.g. a1b2c3d4e5f60001 / ...0002), so a naive
# prefix-truncate collides. Take a stable suffix of the sanitized id plus a short
# hash of the full id to guarantee uniqueness across visuals.
require 'digest'
def short(id)
  clean = id.to_s.gsub(/[^a-zA-Z0-9]/, '')
  h = Digest::SHA1.hexdigest(id.to_s)[0, 6]
  "#{clean[-6, 6] || clean}#{h}"
end

# Resolve which master a visual sources from (first bound field's master).
def visual_master(rec, fields)
  rec['bindings'].each_value do |refs|
    refs.each do |qr|
      m = (fields[qr] || {})['master']
      return m if m
    end
  end
  nil
end

# Build chart element from a normalized visual record.
def build_element(rec, fields, masters)
  kind = SIGMA_KIND[rec['sigma_kind']] || 'bar-chart'
  vid  = rec['visual_id']
  eid  = "el-#{short(vid)}"

  if kind == 'text'
    body = rec['text'] ? "## #{rec['text']}" : '## '
    return { 'id' => eid, 'kind' => 'text', 'body' => body }
  end

  master = visual_master(rec, fields)
  master_id = master && masters[master] ? masters[master]['id'] : nil
  el = { 'id' => eid, 'kind' => kind, 'name' => rec['visual_id'] }
  el['source'] = { 'elementId' => master_id, 'kind' => 'table' } if master_id
  cols = []
  b = rec['bindings']

  case kind
  when 'kpi-chart'
    qr = (b['Values'] || b['Y'] || []).first
    fs = field_spec(qr, fields)
    cid = "#{eid}-v"
    cols << { 'id' => cid, 'formula' => measure_formula(fs), 'name' => (qr || 'Value').split('.').last }
    el['value'] = { 'id' => cid }
  when 'bar-chart', 'line-chart', 'area-chart'
    dim = (b['Category'] || b['Axis'] || b['X'] || []).first
    meas = (b['Y'] || b['Values'] || [])
    series = (b['Series'] || b['Legend'] || []).first
    dfs = field_spec(dim, fields)
    dcid = "#{eid}-x"
    cols << { 'id' => dcid, 'formula' => dfs['ref'], 'name' => (dim || 'Dim').split('.').last }
    ycids = []
    meas.each_with_index do |qr, i|
      fs = field_spec(qr, fields)
      cid = "#{eid}-y#{i}"
      cols << { 'id' => cid, 'formula' => measure_formula(fs), 'name' => qr.split('.').last }
      ycids << cid
    end
    el['xAxis'] = { 'columnId' => dcid }
    el['yAxis'] = { 'columnIds' => ycids }
    # c07: default to single series. Only split by color when PBI bound a
    # Series/Legend role. Never auto-color a line by a dimension that PBI did
    # not legend (see refs/measure-patterns.md §1 + §4).
    if series
      sfs = field_spec(series, fields)
      scid = "#{eid}-c"
      cols << { 'id' => scid, 'formula' => sfs['ref'], 'name' => series.split('.').last }
      el['color'] = { 'by' => 'category', 'column' => scid }
    end
  when 'pie-chart', 'donut-chart'
    dim = (b['Category'] || b['Legend'] || []).first
    val = (b['Values'] || b['Y'] || []).first
    dfs = field_spec(dim, fields); vfs = field_spec(val, fields)
    dcid = "#{eid}-c"; vcid = "#{eid}-v"
    cols << { 'id' => dcid, 'formula' => dfs['ref'], 'name' => (dim || 'Dim').split('.').last }
    cols << { 'id' => vcid, 'formula' => measure_formula(vfs), 'name' => (val || 'Value').split('.').last }
    el['color'] = { 'id' => dcid }
    el['value'] = { 'id' => vcid }
  when 'table'
    (b['Values'] || []).each_with_index do |qr, i|
      fs = field_spec(qr, fields)
      cid = "#{eid}-c#{i}"
      cols << { 'id' => cid, 'formula' => fs['agg'].to_s.empty? ? fs['ref'] : measure_formula(fs),
                'name' => qr.split('.').last }
    end
  when 'pivot-table'
    rows = (b['Rows'] || b['Category'] || [])
    vals = (b['Values'] || [])
    rowids = []
    rows.each_with_index do |qr, i|
      fs = field_spec(qr, fields); cid = "#{eid}-r#{i}"
      cols << { 'id' => cid, 'formula' => fs['ref'], 'name' => qr.split('.').last }
      rowids << cid
    end
    valids = []
    vals.each_with_index do |qr, i|
      fs = field_spec(qr, fields); cid = "#{eid}-v#{i}"
      cols << { 'id' => cid, 'formula' => measure_formula(fs), 'name' => qr.split('.').last }
      valids << cid
    end
    # rowsBy + values REQUIRED or the pivot collapses to one grand-total cell
    # (memory: feedback_sigma_pivot_rowsby_columnsby).
    el['rowsBy'] = rowids.map { |id| { 'id' => id } }
    el['values'] = valids
  end

  el['columns'] = cols
  el
end

# ---- assemble pages -------------------------------------------------------
data_elements = masters.map do |_name, m|
  {
    'id' => m['id'], 'kind' => 'table', 'name' => m['id'].sub(/^master-/, '').upcase[0, 6],
    'source' => { 'dataModelId' => (m['data_model'] || opts[:dm]),
                  'elementId' => m['element_id'], 'kind' => 'data-model' },
    'columns' => (m['columns'] || []),
    'visibleAsSource' => false
  }
end

content_pages = signals['pages'].map do |pg|
  els = pg['visuals'].map { |v| build_element(v, fields, masters) }
  { 'id' => "page-#{pg['page_id']}", 'name' => pg['page_title'], 'elements' => els }
end

spec = {
  'name' => opts[:name] || signals.dig('pages', 0, 'page_title') || 'Power BI Import',
  'schemaVersion' => 1,
  'pages' => [{ 'id' => 'page-data', 'name' => 'Data', 'elements' => data_elements }] + content_pages
}
spec['folderId'] = opts[:folder] if opts[:folder]

File.write(opts[:out], JSON.pretty_generate(spec))
warn "[build-workbook] wrote #{opts[:out]} (#{data_elements.size} master(s), " \
     "#{content_pages.sum { |p| p['elements'].size }} chart element(s))"

# ---- 24-col grid layout (research/powerbi-visual-layout.md §4) -------------
if opts[:layout_out]
  col_for = ->(x, w, pw) {
    unit = pw / 24.0
    cs = (x / unit).floor + 1
    ce = ((x + w - 1) / unit).floor + 2
    [[cs, 1].max, [ce, 25].min]
  }
  ROW_UNIT = 30.0
  pages_xml = signals['pages'].map do |pg|
    pw = pg['page_w'] || 1280
    les = pg['visuals'].map do |v|
      cs, ce = col_for.call(v['x'], v['w'], pw)
      rs = (v['y'] / ROW_UNIT).floor + 1
      re = ((v['y'] + v['h']) / ROW_UNIT).ceil + 1
      eid = "el-#{short(v['visual_id'])}"
      %(  <LayoutElement elementId="#{eid}" gridColumn="#{cs} / #{ce}" gridRow="#{rs} / #{re}"/>)
    end.join("\n")
    %(<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-#{pg['page_id']}">\n#{les}\n</Page>)
  end.join("\n")
  File.write(opts[:layout_out], %(<?xml version="1.0" encoding="utf-8"?>\n#{pages_xml}\n))
  warn "[build-workbook] wrote layout -> #{opts[:layout_out]}"
end
