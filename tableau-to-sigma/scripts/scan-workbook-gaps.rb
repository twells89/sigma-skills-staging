#!/usr/bin/env ruby
# Scan a customer's Tableau .twb (or .twbx after unzip) and emit a markdown gap
# report listing every workbook feature the skill currently handles vs. doesn't.
#
# This is the FIRST thing a customer should run when starting a migration:
# it sets expectations up front (rather than discovering gaps mid-conversion)
# and gives the agent a concrete plan for what to translate auto vs. by hand
# vs. defer.
#
# Usage:
#   ruby scripts/scan-workbook-gaps.rb /path/to/workbook.twb [out.md]
#
# Output: a markdown file (default: <name>-gaps-report.md) with:
#   - Workbook summary (worksheets, dashboards, datasource count)
#   - Auto-handled features (with count)
#   - Hint-only features (count + brief translation guidance)
#   - Unhandled features (count + escalation path)
#   - Manual-setup features (action filters, ref-marks etc. that need
#     post-publish UI work)
#
# The same data is also written as <name>-gaps.json so the gap-scout subagent
# and other downstream tools can consume it programmatically.

require 'json'
require 'rexml/document'

# --- Feature inventory: what the skill handles today ----------------------
# Each entry: { pattern: regex_or_lambda, name: "feature", status: :auto |
# :hint | :manual | :unhandled, blurb: "..." }
INVENTORY = [
  # AUTO — fully translated end-to-end, no manual step needed
  { name: 'Bar / line / area / pie / scatter chart',  pat: /<mark class='(Bar|Line|Area|Pie|Circle|Shape)'/,
    status: :auto, blurb: 'Translated to Sigma bar/line/area/pie/scatter chart with the right marker.' },
  { name: 'Region / filled map',                       pat: /<mark class='(Multipolygon|Polygon|Filled|Map)'/,
    status: :auto, blurb: 'Translated to Sigma region-map.' },
  { name: 'Point / symbol map',                        pat: /<column[^>]+caption='Latitude'/i,
    status: :auto, blurb: 'Translated to Sigma point-map when lat+long both present.' },
  { name: 'Column aliases (value→display)',            pat: /<column[^>]+(?:caption='[^']+')?[^>]*>\s*<aliases>\s*<alias key=/,
    status: :auto, blurb: 'Aliased dim columns get a Switch() formula on the chart.' },
  { name: 'Tableau format strings',                    pat: /<format attr='text-format'/,
    status: :auto, blurb: 'p0.0% / C1033% / $#,##0;(...) etc. translated to Sigma d3-format with paren-negative.' },
  { name: 'Shared-view dashboard filters',             pat: /<shared-view[^>]*>\s*<datasources>/,
    status: :auto, blurb: 'List/relative-date/quantitative shared filters become Sigma controls per page.' },
  { name: 'Per-worksheet sort',                        pat: /<sort\s+[^>]*direction=/,
    status: :auto, blurb: "Tableau's sort direction carries into the chart's xAxis.sort." },
  { name: 'Parameter (list domain) + CASE-on-param',   pat: /param-domain-type='list'/,
    status: :auto, blurb: "List parameters become segmented controls; CASE/IF-on-param calcs translate to Sigma Switch()." },
  { name: 'Dual-axis (synchronized) combo charts',     pat: /synchronized='true'/,
    status: :auto, blurb: 'Synchronized-axis worksheets emit Sigma combo-chart with two yAxis groups.' },
  { name: 'Custom SQL data source',                    pat: /<relation type='text'/,
    status: :auto, blurb: 'Custom SQL becomes a Sigma data-model element with source.kind="sql".' },
  { name: 'Table-calc INDEX/LOOKUP/TOTAL/RANK/ZN/IIF', pat: /\b(INDEX\(\)|LOOKUP\(|TOTAL\(|RANK\b|RANK_DENSE|RANK_PERCENTILE|\bZN\(|\bIIF\(|\bCOUNTD\()/,
    status: :auto, blurb: 'Auto-translated to Sigma RowNumber/Lag/Lead/Rank/Coalesce/If/CountDistinct.' },
  { name: 'Negative number format (parens)',           pat: /;\s*\([^)]*\)/,
    status: :auto, blurb: 'Parens-on-negative segment translates to Sigma d3-format with ( prefix.' },

  # HINT — surfaces a translated formula or setup note as a WARN; agent acts
  { name: 'IF/ELSEIF chain calc',                      pat: /\bIF\b[^']+\bELSEIF\b[^']+\bEND\b/i,
    status: :hint, blurb: 'WARN with suggested Sigma If(...) chain or Switch(). Agent adds to master.' },
  { name: 'Ratio calc (SUM/SUM, SUM/COUNT)',           pat: /SUM\s*\([^)]+\)\s*\/\s*(?:SUM|COUNT)\s*\(/i,
    status: :hint, blurb: 'WARN suggests Sum(x) / NullIf(Sum(y), 0) — agent wires on master.' },
  { name: 'FIXED LOD calc',                            pat: /\{\s*FIXED\b/i,
    status: :hint, blurb: 'WARN with suggested Sigma window aggregate or Custom SQL element.' },
  { name: 'INCLUDE/EXCLUDE LOD',                       pat: /\{\s*(INCLUDE|EXCLUDE)\b/i,
    status: :hint, blurb: 'WARN with chart-grouping adjustment suggestion.' },
  { name: 'Reference lines / bands / trendlines',      pat: /<(reference-line|reference-band|reference-distribution|trendline-model)\b/,
    status: :hint, blurb: 'WARN per chart; agent adds Sigma referenceMarks manually post-publish (see beads-sigma-7ak).' },
  { name: 'Color encoding on measure',                 pat: /<encoding attr='color'[^>]+field-type='quantitative'/,
    status: :hint, blurb: 'WARN; agent adds Sigma colorBy on chart with palette manually (see beads-sigma-0b5).' },

  # MANUAL — non-translatable today; needs customer to do post-publish work
  { name: 'Dashboard filter / highlight / nav actions', pat: /command='tsc:tsl-(filter|highlight|navigate|set-action|parameter-action|url)'/,
    status: :manual, blurb: 'Skill writes actions.md listing each action; customer wires Sigma cross-element filtering after publish.' },
  { name: 'Forecast / trendline model',                pat: /<forecast\b/,
    status: :manual, blurb: 'No Sigma forecast primitive; agent emits a note + Custom SQL option (beads-sigma-yi0).' },
  { name: 'Story points (sequential narrative)',       pat: /<story\b/,
    status: :manual, blurb: 'Each story point becomes a separate Sigma page; navigation control added by hand (beads-sigma-y6b).' },
  { name: 'Drill hierarchies',                         pat: /<drill-paths>|<drill-path /,
    status: :manual, blurb: 'Hierarchies map to pivot rowsBy OR a segmented drill-level control (beads-sigma-jbw).' },

  # UNHANDLED — feature actively used in real workbooks but not surfaced yet
  { name: 'Parameter (numeric range domain)',          pat: /param-domain-type='range'/,
    status: :unhandled, blurb: 'Skill detects but does NOT auto-emit control (Sigma API gap, see beads-sigma-ebw).' },
  { name: 'WINDOW_* aggregates (WINDOW_SUM/AVG/MAX...)', pat: /\bWINDOW_(SUM|AVG|MIN|MAX|COUNT|MEDIAN|PERCENTILE|VAR|STDEV)\b/,
    status: :unhandled, blurb: 'Skill warns; needs translation to Sigma Cumulative*/Moving* or Custom SQL (beads-sigma-427).' },
  { name: 'RUNNING_* totals',                          pat: /\bRUNNING_(SUM|AVG|COUNT|MIN|MAX)\b/,
    status: :unhandled, blurb: 'Skill warns; translates to Sigma CumulativeSum/Avg in non-grouping context (beads-sigma-427).' },
  { name: 'Tableau SCRIPT_* (R/Python)',               pat: /\bSCRIPT_(REAL|STR|INT|BOOL)\b/,
    status: :unhandled, blurb: 'No Sigma equivalent. Customer rewrites in SQL/Python via Custom SQL or external prep.' },
  { name: 'Phone / mobile-specific layout',            pat: /<device-layout\b|<phone-layout\b/,
    status: :unhandled, blurb: 'Sigma has no separate mobile layout; one responsive layout applies.' },
  { name: 'Show/hide containers',                      pat: /show-hide-container|is-modal='true'/,
    status: :unhandled, blurb: 'Sigma containers can be conditionally hidden via a control; needs manual wiring.' },
  { name: 'Sets (computed / manual)',                  pat: /<groupfilter function='set'|<set\s/,
    status: :unhandled, blurb: 'No Sigma direct equivalent. Approximate with a calculated boolean column.' }
].freeze

def categorize(content)
  results = INVENTORY.map do |entry|
    matches = content.scan(entry[:pat]).length
    entry.merge(count: matches)
  end
  results.select { |r| r[:count] > 0 }
end

def render_md(wb_name, summary, results)
  by_status = results.group_by { |r| r[:status] }
  md = String.new
  md << "# Tableau→Sigma gap report — `#{wb_name}`\n\n"
  md << "Generated by `scan-workbook-gaps.rb`. Run BEFORE conversion to set expectations.\n\n"
  md << "## Workbook summary\n\n"
  summary.each { |k, v| md << "- **#{k}:** #{v}\n" }
  md << "\n"

  emit = lambda do |status, label, header|
    rows = by_status[status] || []
    md << "## #{header} (#{rows.length})\n\n"
    if rows.empty?
      md << "_None detected._\n\n"
      return
    end
    md << "| Feature | Count | What the skill does |\n|---|---|---|\n"
    rows.sort_by { |r| -r[:count] }.each do |r|
      md << "| #{r[:name]} | #{r[:count]} | #{r[:blurb]} |\n"
    end
    md << "\n"
  end

  emit.call(:auto,      'Auto', '✅ Fully auto-translated')
  emit.call(:hint,      'Hint', '⚠️ Translation suggested, agent action required')
  emit.call(:manual,    'Manual','🛠 Post-publish manual setup required')
  emit.call(:unhandled, 'Unhandled','❌ Not yet handled — escalation path')

  md << "## Suggested next steps\n\n"
  if (by_status[:unhandled] || []).any?
    md << "1. Review the **Unhandled** features above. For each, the agent will either:\n"
    md << "   - Attempt translation via the `gap-scout` subagent (validates against Sigma API)\n"
    md << "   - File an issue at github.com/twells89/sigma-skills-staging if no translation is possible\n"
  end
  if (by_status[:manual] || []).any?
    md << "2. The **Manual** features need post-publish work. See `<workbook>-actions.md` after conversion for action-filter mappings.\n"
  end
  if (by_status[:hint] || []).any?
    md << "3. The **Hint** features will show as `WARN` lines during conversion with copy-paste-ready Sigma formulas — review each before publishing.\n"
  end
  md << "\n_Generated by tableau-to-sigma skill. Issues: https://github.com/twells89/sigma-skills-staging/issues_\n"
  md
end

def main
  inp = ARGV[0] || abort('usage: scan-workbook-gaps.rb <workbook.twb> [out.md]')
  out = ARGV[1] || inp.sub(/\.(twbx?|xml)$/i, '-gaps-report.md')
  abort("not found: #{inp}") unless File.exist?(inp)

  content = File.read(inp, encoding: 'utf-8', invalid: :replace)

  # Workbook summary via REXML
  begin
    xml = REXML::Document.new(content)
    n_dash = xml.elements.to_a('//dashboard').count
    n_ws   = xml.elements.to_a('//worksheet').count
    n_ds   = xml.elements.to_a('//datasource[@caption]').count
  rescue StandardError
    n_dash = n_ws = n_ds = '?'
  end

  summary = {
    'Workbook' => File.basename(inp),
    'Worksheets' => n_ws,
    'Dashboards' => n_dash,
    'Datasources' => n_ds,
    '.twb size' => "#{(File.size(inp) / 1024.0).round(1)} KB"
  }

  results = categorize(content)
  md_path = out
  json_path = out.sub(/\.md$/, '.json')

  File.write(md_path, render_md(File.basename(inp), summary, results))
  File.write(json_path, JSON.pretty_generate({
    'workbook' => summary,
    'detected_features' => results.map { |r| r.transform_keys(&:to_s) }
  }))

  warn "wrote #{md_path}"
  warn "wrote #{json_path}"
  warn ""
  warn "Summary: " + results.group_by { |r| r[:status] }.map { |s, rs| "#{rs.length} #{s}" }.join(', ')
end

main if $PROGRAM_NAME == __FILE__
