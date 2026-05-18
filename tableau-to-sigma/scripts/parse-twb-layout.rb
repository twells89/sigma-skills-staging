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

  worksheets[name] = {
    mark_class:    mark_class,
    geo_role:      geo_role,
    has_lat:       has_lat,
    has_long:      has_long,
    has_geometry:  has_geometry
  }
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

    zones << {
      'id'         => z.attributes['id'],
      'kind'       => kind,
      'caption'    => caption,
      'view_ref'   => view_ref,
      'x_pct'      => pct(z.attributes['x']),
      'y_pct'      => pct(z.attributes['y']),
      'w_pct'      => pct(z.attributes['w']),
      'h_pct'      => pct(z.attributes['h']),
      'chart_kind' => chart_kind,
      'mark_class' => ws_meta&.dig(:mark_class),
      'geo_role'   => ws_meta&.dig(:geo_role)
    }
  end
  dashboards << {
    'dashboard' => d.attributes['name'],
    'zones'     => zones
  }
end

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
