#!/usr/bin/env ruby
# Parse the dashboard layout out of a .twb XML file.
#
# The dashboard image PNG only shows pixels; the .twb XML carries the actual
# zone tree with chart positions, captions, and underlying view refs. Reading
# this BEFORE building the workbook spec prevents the common Phase 5 miss:
# dropping the dashboard title, filter shelf, and any pie/donut chart hints
# whose chart-kind isn't visible in the view CSV.
#
# This script is opt-in. Use it when:
#   - The MCP path doesn't give you `.twb` access (it doesn't).
#   - Or you want a deterministic layout scaffold rather than eyeballing the PNG.
#
# Usage:
#   ruby scripts/parse-twb-layout.rb /tmp/<name>/workbook-content.twb \
#                                    /tmp/<name>/dashboard-layout.json
#
# Output (one JSON object per dashboard):
#   {
#     "dashboard": "Orders Overview",
#     "size": {"w_pct": 100, "h_pct": 100},
#     "zones": [
#       {"id":"71","kind":"chart","caption":"Revenue by Region",
#        "x_pct":0,"y_pct":0,"w_pct":33,"h_pct":50,
#        "view_ref":"[federated.xxx].[none:abc:qk]"},
#       {"id":"57","kind":"title","caption":"Orders Dashboard",
#        "x_pct":0,"y_pct":0,"w_pct":100,"h_pct":7},
#       ...
#     ]
#   }
#
# The agent should use this to:
#   - Confirm every Tableau tile has a corresponding Sigma element (chart, text,
#     control). Missing one is almost always a mistake.
#   - Seed the layout XML row/column spans from x_pct/y_pct/w_pct/h_pct
#     (Tableau uses units of 100,000 = 100% — this script normalizes to %).
#   - Recognize text/title zones (zones with no `param` pointing to a worksheet
#     but with caption text or a free-text style).

require 'json'
require 'rexml/document'

INP = ARGV[0] || abort('usage: parse-twb-layout.rb <workbook-content.twb> <out.json>')
OUT = ARGV[1] || abort('usage: parse-twb-layout.rb <workbook-content.twb> <out.json>')

xml = REXML::Document.new(File.read(INP))

def pct(v)
  return nil if v.nil?
  (v.to_f / 1_000.0).round(1)   # Tableau: 100000 == 100%
end

dashboards = []
xml.elements.each('//dashboard') do |d|
  zones = []
  seen_ids = {}
  d.elements.each('.//zone') do |z|
    next if z.attributes['id'].nil?
    # Tableau .twb often emits the same zone tree in multiple contexts; dedupe by id.
    next if seen_ids[z.attributes['id']]
    seen_ids[z.attributes['id']] = true
    # Skip pure layout-container zones (those with no name/param and no fixed size)
    has_param   = !z.attributes['param'].nil?
    has_name    = !z.attributes['name'].nil?
    caption     = z.attributes['name']
    # Layout zones often have w=100000 h=100000; we keep them but mark kind=container
    kind = if has_param && caption
             'chart'
           elsif z.elements['formatted-text'] || z.elements['style']
             'text-or-filter'
           else
             'container'
           end
    zones << {
      'id'       => z.attributes['id'],
      'kind'     => kind,
      'caption'  => caption,
      'view_ref' => z.attributes['param'],
      'x_pct'    => pct(z.attributes['x']),
      'y_pct'    => pct(z.attributes['y']),
      'w_pct'    => pct(z.attributes['w']),
      'h_pct'    => pct(z.attributes['h'])
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
    pos = "x=#{z['x_pct']}% y=#{z['y_pct']}% w=#{z['w_pct']}% h=#{z['h_pct']}%"
    puts "    #{z['kind'].ljust(15)} #{cap.to_s[0..40].ljust(42)} #{pos}"
  end
end
