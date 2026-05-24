#!/usr/bin/env ruby
# Detect whether a prior Phase-1 conversion run already produced the discovery
# artifacts we'd otherwise re-fetch from Tableau (views CSVs, view PNGs, the
# .twb, gap-scan output, layout JSON). If yes, emit absolute paths so the new
# conversion can reuse them instead of re-running tableau-discover.rb /
# scan-workbook-gaps.rb / parse-twb-layout.rb — easily saves 3+ minutes.
#
# Usage:
#   ruby scripts/find-prior-cache.rb --name <workbook-slug> [--out <file>.json]
#
# Output JSON shape:
#   {
#     "name": "workforce",
#     "found": true|false,
#     "cache_dirs": ["/tmp/audit-run-1/workforce", "/tmp/converter-test/workforce"],
#     "views_csv_dir": ".../views",            # or null
#     "views_png_dir": ".../views-png",        # or null
#     "twb":           ".../workbook-content.twb",   # or null
#     "gaps_report":   ".../*-gaps-report.md", # or null
#     "gaps_json":     ".../*-gaps.json",
#     "dashboard_layout":      ".../dashboard-layout.json",
#     "dashboard_layout_meta": ".../dashboard-layout-meta.json",
#     "get_workbook":  ".../get-workbook.json",
#     "dm_spec":       ".../dm-spec.json",
#     "wb_spec":       ".../wb-spec.json",
#     "dm_ids":        ".../dm-ids.json",
#     "wb_ids":        ".../wb-ids.json"
#   }
#
# Search locations (in order, first hit wins per artifact):
#   /tmp/audit-run-*/<name>/...
#   /tmp/converter-test/<name>/...
#   /tmp/<name>/...

require 'json'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--name N') { |v| opts[:name] = v }
  p.on('--out P')  { |v| opts[:out]  = v }
end.parse!
abort 'missing --name' unless opts[:name]

name = opts[:name]
candidate_dirs = (
  Dir.glob("/tmp/audit-run-*/#{name}") +
  ["/tmp/converter-test/#{name}",
   "/tmp/#{name}"]
).select { |d| File.directory?(d) }

# For each artifact, find the first matching file across candidate_dirs.
def first_existing(dirs, *suffixes)
  dirs.each do |d|
    suffixes.each do |s|
      candidates = Dir.glob(File.join(d, s))
      hit = candidates.find { |f| File.file?(f) || File.directory?(f) }
      return hit if hit
    end
  end
  nil
end

result = {
  'name'                  => name,
  'found'                 => !candidate_dirs.empty?,
  'cache_dirs'            => candidate_dirs,
  'views_csv_dir'         => first_existing(candidate_dirs, 'views'),
  'views_png_dir'         => first_existing(candidate_dirs, 'views-png'),
  'twb'                   => first_existing(candidate_dirs, 'workbook-content.twb', '*.twb'),
  'gaps_report'           => first_existing(candidate_dirs, '*-gaps-report.md', 'gaps-report.md'),
  'gaps_json'             => first_existing(candidate_dirs, '*-gaps.json', 'gaps.json'),
  'dashboard_layout'      => first_existing(candidate_dirs, 'dashboard-layout.json'),
  'dashboard_layout_meta' => first_existing(candidate_dirs, 'dashboard-layout-meta.json'),
  'dashboard_render_png'  => first_existing(candidate_dirs, 'dashboard-render.png'),
  'get_workbook'          => first_existing(candidate_dirs, 'get-workbook.json'),
  'dm_spec'               => first_existing(candidate_dirs, 'dm-spec.json'),
  'wb_spec'               => first_existing(candidate_dirs, 'wb-spec.json'),
  'dm_ids'                => first_existing(candidate_dirs, 'dm-ids.json'),
  'wb_ids'                => first_existing(candidate_dirs, 'wb-ids.json'),
  'master_columns'        => first_existing(candidate_dirs, 'master-columns.json'),
  'workbook_signature'    => first_existing(candidate_dirs, 'workbook-signature.json')
}

out_json = JSON.pretty_generate(result)
if opts[:out]
  File.write(opts[:out], out_json)
  warn "wrote #{opts[:out]}"
end
puts out_json
