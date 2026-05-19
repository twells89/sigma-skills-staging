#!/usr/bin/env ruby
# Parse the dashboard layout out of a .twb XML file.
#
# The dashboard image PNG only shows pixels; the .twb XML carries the actual
# zone tree with chart positions, captions, underlying view refs, AND the chart
# kind (bar / line / pie / map / etc.) via the worksheet's <mark> element.
# Reading this BEFORE building the workbook spec prevents the common Phase 5
# miss: dropping the dashboard title, filter shelf, or any pie/donut/map tile
# whose chart-kind isn't visible in the view CSV.
#
# Usage:
#   ruby scripts/parse-twb-layout.rb /tmp/<name>/workbook-content.twb \
#                                    /tmp/<name>/dashboard-layout.json
#
# Output (one JSON object per dashboard):
#   {
#     "dashboard": "Orders Overview",
#     "zones": [
#       { "id":"3", "kind":"chart", "caption":"Revenue by Region",
#         "x_pct":0, "y_pct":29.7, "w_pct":35.5, "h_pct":31.5,
#         "view_ref":"[federated.xxx].[…]",
#         "chart_kind":"bar", "mark_class":"Bar",
#         "geo_role":null },
#       { "id":"26", "kind":"chart", "caption":"Order Channel vs Ship Method",
#         "chart_kind":"pie", "mark_class":"Pie", ... },
#       { "id":"57", "kind":"text", "caption":null, ... },
#       { "id":"71", "kind":"filter", "caption":"Revenue by Region", ... }
#     ]
#   }
#
# `chart_kind` is the Sigma-relevant chart type derived from the worksheet's
# <mark class="..."> element plus a check for geographic encoding roles. Map to
# Sigma kinds with the table in refs/workbook-layout.md.

require 'json'
require 'rexml/document'

INP = ARGV[0] || abort('usage: parse-twb-layout.rb <workbook-content.twb> <out.json>')
OUT = ARGV[1] || abort('usage: parse-twb-layout.rb <workbook-content.twb> <out.json>')

xml = REXML::Document.new(File.read(INP))

def pct(v)
  return nil if v.nil?
  (v.to_f / 1_000.0).round(1)   # Tableau: 100000 == 100%
end

# ---- Column GUID → caption resolver ---------------------------------------
# Tableau filters reference columns by GUID (e.g.,
# `[federated.X].[none:c2ec6b07-...:qk]`). To translate a filter into a Sigma
# control we need the human-readable caption ("Region") plus the data type
# (categorical / date / numeric). Both live on <column> elements throughout the
# .twb (datasource-dependencies blocks AND the top-level metadata-records).
#
# We build a single lookup: { "c2ec6b07-..." => { caption:, datatype: } }.
COL_BY_GUID = {}
xml.elements.each('//column') do |c|
  raw = c.attributes['name'].to_s
  cap = c.attributes['caption']
  dt  = c.attributes['datatype']
  next if raw.empty?
  # Names look like `[guid]` or `[guid (foo)]` or `[Friendly Name]`. Strip
  # surrounding brackets and lift out the GUID-looking head.
  body = raw.sub(/^\[/, '').sub(/\]$/, '')
  head = body.split(/\s/, 2).first
  COL_BY_GUID[head] ||= { caption: cap, datatype: dt } if cap && !cap.empty?
end

# Filter columns use a column-instance level reference like
#   `[federated.X].[none:c2ec6b07-...:qk]`
# where `none` is the derivation and `qk`/`nk` is pivot/key qualifier. Strip
# both and extract the GUID.
def guid_from_param(param)
  return nil if param.nil? || param.empty?
  m = param.match(/\.\[(?:[a-z\-]+:)?([0-9a-f\-]{36})(?::[a-z]+)?\]$/i)
  m && m[1]
end

# Strip Tableau's quoted-string member encoding (`&quot;CA&quot;` → `CA`).
def unquote_member(s)
  return nil if s.nil?
  s = s.to_s.gsub('&quot;', '"').strip
  return nil if s == '%null%'
  s.sub(/^"/, '').sub(/"$/, '')
end

# Read a <filter> element and emit a normalized spec:
#   { kind: "list" | "date-range" | "relative-date" | "number-range" | "action" | "unknown",
#     column_guid: "...", column_caption: "...", datatype: "string|date|real|integer|...",
#     members: ["CA","NY",...]  (for list)
#     min/max: numbers           (for number-range)
#     first_period/last_period/period_type/include_future/include_null  (relative-date)
#     raw_param: ...,
#     is_action: true|false }
def normalize_filter(f)
  cls   = f.attributes['class'].to_s
  param = f.attributes['column'].to_s
  is_action = param.include?('[Action ') || param.include?('[Action(')
  guid  = guid_from_param(param)
  info  = guid ? COL_BY_GUID[guid] : nil

  out = {
    'raw_class'      => cls,
    'raw_param'      => param,
    'column_guid'    => guid,
    'column_caption' => info && info[:caption],
    'datatype'       => info && info[:datatype],
    'is_action'      => is_action
  }

  if is_action
    out['kind'] = 'action'
    return out
  end

  case cls
  when 'categorical'
    members = []
    f.each_element('.//groupfilter') do |gf|
      next unless gf.attributes['function'] == 'member'
      m = unquote_member(gf.attributes['member'])
      members << m if m
    end
    out['kind']    = 'list'
    out['members'] = members
  when 'relative-date'
    out['kind']           = 'relative-date'
    out['first_period']   = f.attributes['first-period']
    out['last_period']    = f.attributes['last-period']
    out['period_type']    = f.attributes['period-type-v2'] || f.attributes['period-type']
    out['include_future'] = f.attributes['include-future']
    out['include_null']   = f.attributes['include-null']
  when 'quantitative'
    out['kind'] = 'number-range'
    out['min'] = f.attributes['min']
    out['max'] = f.attributes['max']
  else
    out['kind'] = 'unknown'
  end
  out
end

# Build a lookup of worksheet name → metadata extracted from <worksheet> elements.
# - mark_class: the <mark class="..."> value (Bar / Line / Pie / Filled / Circle / etc.)
# - geo_role:   the first geographic semantic-role we find on any column (e.g. "geo:state")
# - has_lat / has_long: heuristic for point-map detection (column names contain
#   "latitude" / "longitude")
worksheets = {}
xml.elements.each('//worksheet') do |ws|
  name = ws.attributes['name']
  next unless name
  mark = ws.elements['.//mark']
  mark_class = mark ? (mark.attributes['class'].to_s) : nil

  geo_role = nil
  has_lat  = false
  has_long = false
  has_geometry = !ws.elements['.//geometry'].nil?
  ws.elements.each('.//column') do |col|
    # Tableau's `semantic-role` attribute on a column carries the geographic
    # assignment when one is set. Patterns we've seen in the wild:
    #   [Country].[ISO3166_2]      [State].[Country].[State]
    #   [State/Province].[Name]    [City].[Country].[Name]
    #   [County].[Country].[Name]  [Zip Code].[Country].[Zip]
    # If the attribute is present at all, the column carries a geo assignment.
    role = col.attributes['semantic-role'] || col.attributes['semanticRole']
    if role && !role.to_s.empty?
      geo_role ||= role
    end
    nm = col.attributes['caption'] || col.attributes['name'] || ''
    has_lat  = true if nm =~ /latitude/i
    has_long = true if nm =~ /longitude/i
  end

  # Per-worksheet sort. <sort> element under the worksheet carries direction
  # ("ascending"|"descending") and a `column` attribute referencing the sorted
  # dimension. We emit the first sort we find (Tableau allows multiple but
  # downstream tooling almost always wants the primary one).
  sort_info = nil
  if (s = ws.elements['.//sort'])
    sort_info = {
      direction: s.attributes['direction'],
      column:    s.attributes['column']
    }
  end

  # Per-worksheet view-level filters. Each filter is normalized via
  # normalize_filter (resolves GUID → caption + datatype, extracts member values
  # for categorical, period spec for relative-date, min/max for quantitative,
  # and flags action filters separately).
  filters_info = []
  ws.elements.each('.//filter') do |f|
    filters_info << normalize_filter(f)
  end

  # Per-column aggregation override. <column-instance derivation="Sum|Avg|Min|
  # Max|Median|CountD|None|User|Month-Trunc|Year-Trunc|..."> tells us what
  # aggregation Tableau is using for that column in the pane. We expose all of
  # them; the agent decides which are interesting (non-default).
  aggregations = {}
  ws.elements.each('.//column-instance') do |ci|
    col = ci.attributes['column']
    deriv = ci.attributes['derivation']
    next if col.nil? || deriv.nil?
    aggregations[col.to_s] = deriv.to_s
  end

  # Per-column format strings. Tableau emits these via
  #   <style-rule element='cell'>
  #     <format attr='text-format' field='[federated.X].[col-ref]' value='p0.0%' />
  # We capture the value verbatim keyed by the field reference. translate_format
  # below converts to Sigma's d3-format string.
  formats = {}
  ws.elements.each('.//format') do |fmt|
    next unless fmt.attributes['attr'] == 'text-format'
    field = fmt.attributes['field']
    val   = fmt.attributes['value']
    next if field.nil? || val.nil?
    formats[field.to_s] = val.to_s
  end

  # Encoding channels (color / size / detail / shape / label / tooltip).
  # Color is the key one for multi-series approximations (Sales by Segment etc).
  channels = {}
  ws.elements.each('.//encodings/encoding') do |e|
    attr = e.attributes['attr']
    next unless %w[color size shape detail label tooltip text].include?(attr.to_s)
    channels[attr.to_s] = {
      column: e.attributes['column'],
      field:  e.attributes['field']
    }
  end

  # Per-worksheet calculated fields. Tableau emits these as
  #   <column datatype='X' name='[Calc Name]' role='dimension|measure' type='...'>
  #     <calculation class='tableau' formula='...' />
  #   </column>
  # We surface them so the build script can flag (or translate) calcs that are
  # used by this worksheet's chart.
  calcs = []
  ws.elements.each('.//column') do |col|
    calc = col.elements['calculation']
    next unless calc
    cls  = calc.attributes['class']
    formula = calc.attributes['formula']
    next if formula.nil? || formula.empty?
    calcs << {
      'name'    => col.attributes['name'],
      'caption' => col.attributes['caption'],
      'datatype'=> col.attributes['datatype'],
      'role'    => col.attributes['role'],
      'class'   => cls,
      'formula' => formula
    }
  end

  worksheets[name] = {
    mark_class:    mark_class,
    geo_role:      geo_role,
    has_lat:       has_lat,
    has_long:      has_long,
    has_geometry:  has_geometry,
    sort:          sort_info,
    filters:       filters_info,
    aggregations:  aggregations,
    channels:      channels,
    formats:       formats,
    calculations:  calcs
  }
end

# ---- Tableau format → Sigma format translator -----------------------------
# Tableau format codes (subset we see in the wild):
#   p0%      → ,.0%
#   p0.0%    → ,.1%
#   p0.00%   → ,.2%
#   0        → ,.0f
#   0.0      → ,.1f
#   #,##0    → ,.0f
#   $#,##0   → $,.0f (currency)
#   $#,##0.00→ $,.2f
#   yyyy-MM-dd → %Y-%m-%d
#   MMM yyyy   → %b %Y
#   yyyy       → %Y
def translate_format(tableau_fmt)
  s = tableau_fmt.to_s
  return nil if s.empty?
  # Percent — p<digits>[.<digits>]%
  if (m = s.match(/^p\d*(?:\.(\d+))?%$/i))
    decimals = (m[1] || '').length
    return { 'kind' => 'number', 'formatString' => ",.#{decimals}%" }
  end
  # Tableau locale-currency code — C<locale>[.<digits>]% (e.g., C1033% = $#,##0)
  if (m = s.match(/^C\d+(?:\.(\d+))?%?$/))
    decimals = (m[1] || '').length
    return { 'kind' => 'number', 'formatString' => "$,.#{decimals}f", 'currencySymbol' => '$' }
  end
  # Currency
  if s.start_with?('$')
    decimals = (s.match(/\.(0+)/) || [])[1].to_s.length
    return { 'kind' => 'number', 'formatString' => "$,.#{decimals}f", 'currencySymbol' => '$' }
  end
  # Plain number — count decimals after the decimal point
  if s =~ /^[#,0]+(?:\.(0+))?$/
    decimals = ($1 || '').length
    return { 'kind' => 'number', 'formatString' => ",.#{decimals}f" }
  end
  # Date formats — translate Tableau tokens to strftime
  if s =~ /yyyy|MMM|MM|dd|HH/
    f = s
      .gsub('yyyy', '%Y').gsub('yy', '%y')
      .gsub('MMMM','%B').gsub('MMM','%b').gsub('MM','%m')
      .gsub('dd','%d').gsub('HH','%H').gsub('mm','%M').gsub('ss','%S')
    return { 'kind' => 'datetime', 'formatString' => f }
  end
  nil
end

# Translate Tableau mark class + geo signals into a Sigma-relevant chart-kind label.
# Returns one of:
#   bar | line | area | pie | scatter | map-region | map-point | table-or-text |
#   automatic | other
#
# Notes:
#   - "Automatic" is Tableau's default-pick-for-the-encodings. It usually renders
#     as a bar in our experience but is not deterministic; we emit "automatic" so
#     the agent KNOWS to look at the PNG before committing to a Sigma kind.
#   - Geographic encoding presence beats mark class for map detection.
def chart_kind_for(meta)
  return nil unless meta
  mc       = (meta[:mark_class] || '').downcase
  has_xy   = meta[:has_lat] && meta[:has_long]
  geo_mark = %w[multipolygon polygon filled map].include?(mc)

  # Map detection — STRONG signals only. Semantic-role on a column alone is not
  # enough: a column with a geographic semantic-role on the datasource flows into
  # every worksheet that uses it, including KPIs, bar charts, etc. that aren't
  # maps. Only trust:
  #   1. Mark class is one of the explicit map marks (Multipolygon / Polygon /
  #      Filled / Map). Tableau sets these when the worksheet renders as a map.
  #   2. <geometry> element present in the worksheet — auto-generated for filled
  #      maps from named regions (state / country / etc.).
  #   3. Both Latitude and Longitude column references — a lat/long symbol map.
  return 'map-region' if geo_mark || meta[:has_geometry]
  return 'map-point'  if has_xy

  case mc
  when 'bar'        then 'bar'
  when 'line'       then 'line'
  when 'area'       then 'area'
  when 'pie'        then 'pie'
  when 'circle'     then 'scatter'                # symbol marks (non-geo) = scatter
  when 'square'     then 'table-or-text'          # often heatmap-style table or text table
  when 'text'       then 'table-or-text'
  when 'shape'      then 'scatter'
  when 'automatic'  then 'automatic'              # Tableau's default-pick — verify against PNG
  when ''           then 'other'
  else 'other'
  end
end

dashboards = []
xml.elements.each('//dashboard') do |d|
  zones = []
  seen_ids = {}
  d.elements.each('.//zone') do |z|
    next if z.attributes['id'].nil?
    next if seen_ids[z.attributes['id']]
    seen_ids[z.attributes['id']] = true

    type_v2  = z.attributes['type-v2']
    caption  = z.attributes['name']
    view_ref = z.attributes['param']

    # Translate Tableau zone type-v2 → our zone-level kind label
    kind = case type_v2
           when 'layout-basic', 'layout-flow' then 'container'
           when 'text'                        then 'text'
           when 'title'                       then 'title'
           when 'filter'                      then 'filter'
           when 'paramctrl'                   then 'parameter'
           when 'color'                       then 'legend'
           when 'empty'                       then 'spacer'
           when 'dashboard-object'            then 'dashboard-object'
           when nil
             # No type-v2 + a worksheet name → this is the chart tile
             caption ? 'chart' : 'container'
           else type_v2
           end

    ws_meta    = caption ? worksheets[caption] : nil
    chart_kind = kind == 'chart' ? chart_kind_for(ws_meta) : nil

    # Resolve filter-zone param GUID → column caption when this is a filter
    # zone, so downstream tools don't need to re-walk the .twb.
    if kind == 'filter' || kind == 'parameter'
      g = guid_from_param(view_ref)
      info = g ? COL_BY_GUID[g] : nil
      filter_col_caption  = info && info[:caption]
      filter_col_datatype = info && info[:datatype]
    end

    zones << {
      'id'           => z.attributes['id'],
      'kind'         => kind,
      'caption'      => caption,
      'view_ref'     => view_ref,
      'x_pct'        => pct(z.attributes['x']),
      'y_pct'        => pct(z.attributes['y']),
      'w_pct'        => pct(z.attributes['w']),
      'h_pct'        => pct(z.attributes['h']),
      'chart_kind'   => chart_kind,
      'mark_class'   => ws_meta&.dig(:mark_class),
      'geo_role'     => ws_meta&.dig(:geo_role),
      # New per-worksheet signal fields (nil for non-chart zones)
      'sort'         => (kind == 'chart' ? ws_meta&.dig(:sort)          : nil),
      'filters'      => (kind == 'chart' ? ws_meta&.dig(:filters)       : nil),
      'aggregations' => (kind == 'chart' ? ws_meta&.dig(:aggregations)  : nil),
      'channels'     => (kind == 'chart' ? ws_meta&.dig(:channels)      : nil),
      'formats'      => (kind == 'chart' ? ws_meta&.dig(:formats)       : nil),
      'calculations' => (kind == 'chart' ? ws_meta&.dig(:calculations)  : nil),
      # Resolved filter target (filter/parameter zones only)
      'filter_column_caption'  => (kind == 'filter' || kind == 'parameter' ? filter_col_caption  : nil),
      'filter_column_datatype' => (kind == 'filter' || kind == 'parameter' ? filter_col_datatype : nil)
    }
  end
  dashboards << {
    'dashboard' => d.attributes['name'],
    'zones'     => zones
  }
end

## ---- Tableau parameters ---------------------------------------------------
# Parameters live as <column param-domain-type='list|range'> inside any
# datasource (Tableau's "Parameters" datasource for global ones, or inside a
# real datasource for legacy local params). Each has:
#   - caption        (display name)
#   - datatype       (integer | real | string | date | datetime | boolean)
#   - param_domain   ('list' | 'range' | 'any')
#   - default_value  (value attribute, raw — may be quoted)
#   - members        [{ value }] when param_domain='list'
#   - min/max/step   when param_domain='range'
# Sigma maps these to: segmented/list control (list), number/range-slider
# control (range numeric), date-range control (range date).
def unquote_value(s)
  s = s.to_s.gsub('&quot;', '"')
  s.sub(/^"/, '').sub(/"$/, '')
end

parameters = []
xml.elements.each("//column[@param-domain-type]") do |col|
  raw_name = col.attributes['name'].to_s
  caption  = col.attributes['caption'] || raw_name.gsub(/^\[|\]$/, '')
  members  = []
  col.each_element('.//members/member') do |m|
    members << unquote_value(m.attributes['value'])
  end
  rng = col.elements['range']
  parameters << {
    'name'          => raw_name,
    'caption'       => caption,
    'datatype'      => col.attributes['datatype'],
    'param_domain'  => col.attributes['param-domain-type'],
    'default_value' => unquote_value(col.attributes['value']),
    'members'       => members,
    'min'           => rng && rng.attributes['min'],
    'max'           => rng && rng.attributes['max'],
    'step'          => rng && rng.attributes['granularity']
  }
end

# Detect which worksheet calcs reference a parameter so the build script knows
# which calcs to translate via Switch(). A calc references a parameter when its
# formula contains `[Parameters].[X]` OR a bare `[X]` whose caption matches a
# known parameter caption.
param_caption_set = parameters.map { |p| p['caption'] }.compact.to_set rescue parameters.map { |p| p['caption'] }
worksheets.each do |_ws_name, w|
  next unless w[:calculations]
  w[:calculations].each do |c|
    f = c['formula'].to_s
    refs = []
    # Explicit `[Parameters].[X]` references
    f.scan(/\[Parameters?(?:\s*\([^)]*\))?\]\s*\.\s*\[([^\]]+)\]/i).flatten.each { |x| refs << x }
    # Bare bracket-refs that match a parameter caption verbatim
    f.scan(/\[([^\]\/]+)\]/).flatten.each do |x|
      refs << x if param_caption_set.include?(x)
    end
    c['parameter_refs'] = refs.uniq unless refs.empty?
  end
end

## ---- Shared-view (workbook-level) filters ---------------------------------
# Tableau emits dashboard / cross-sheet filters in <shared-view> blocks at the
# workbook level. These apply to every worksheet that uses the same datasource.
# Parsing here means a page-per-worksheet builder can auto-emit Sigma controls
# for them without the agent supplying any config.
shared_filters = []
xml.elements.each('//shared-view') do |sv|
  sv_name = sv.attributes['name']
  sv.elements.each('filter') do |f|
    spec = normalize_filter(f)
    spec['shared_view'] = sv_name
    shared_filters << spec
  end
end

meta = {
  'worksheets'     => worksheets.transform_values { |v| v.transform_keys(&:to_s) },
  'shared_filters' => shared_filters,
  'parameters'     => parameters,
  'columns_by_guid'=> COL_BY_GUID.transform_values { |v| { 'caption' => v[:caption], 'datatype' => v[:datatype] } }
}
META_OUT = OUT.sub(/\.json$/, '-meta.json')
File.write(META_OUT, JSON.pretty_generate(meta))
puts "wrote #{META_OUT} (#{meta['worksheets'].size} worksheets, #{shared_filters.size} shared filters)"

File.write(OUT, JSON.pretty_generate(dashboards))
puts "wrote #{OUT} (#{dashboards.size} dashboards, #{dashboards.sum { |d| d['zones'].size }} zones total)"
dashboards.each do |d|
  puts "  [#{d['dashboard']}]"
  d['zones'].each do |z|
    next if z['kind'] == 'container' && z['caption'].nil?
    cap = z['caption'] || '(no caption)'
    extras = []
    extras << "chart_kind=#{z['chart_kind']}" if z['chart_kind']
    extras << "mark=#{z['mark_class']}"        if z['mark_class']
    extras << "geo=#{z['geo_role']}"           if z['geo_role']
    pos = "x=#{z['x_pct']}% y=#{z['y_pct']}% w=#{z['w_pct']}% h=#{z['h_pct']}%"
    puts "    #{z['kind'].ljust(8)} #{cap.to_s[0..38].ljust(40)} #{pos.ljust(45)} #{extras.join(' ')}"
  end
end
