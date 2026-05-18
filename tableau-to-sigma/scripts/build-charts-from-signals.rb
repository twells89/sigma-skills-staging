#!/usr/bin/env ruby
# Build Sigma chart-element specs from parse-twb-layout.rb output + view CSVs +
# a master-column map.
#
# The agent's job is the data model + master table (deciding which DM columns
# the master needs, naming them, wiring Lookup/Coalesce as needed). This
# script's job is the chart layer: translating each Tableau chart zone into a
# Sigma element using the new parser signals (chart_kind, sort, aggregations,
# channels, filters) so chart kind / aggregator / sort match the source instead
# of relying on agent defaults.
#
# Usage:
#   ruby scripts/build-charts-from-signals.rb \
#     --tableau-dir /tmp/<name> \
#     --layout /tmp/<name>/dashboard-layout.json \
#     --master-map /tmp/<name>/master-columns.json \
#     --master-element-id master \
#     --out /tmp/<name>/chart-specs.json
#
# Inputs:
#   --tableau-dir       directory with get-workbook.json + views/<viewId>.csv
#   --layout            parse-twb-layout.rb output (per-dashboard zone list)
#   --master-map        JSON: regex-string → { id, name } mapping CSV header tokens
#                       to master-table column IDs. Example:
#                       { "(?i)region":      { "id": "m-region",  "name": "Region" },
#                         "(?i)gross revenue": { "id": "m-gross-rev", "name": "Gross Revenue" } }
#   --master-element-id ID of the master table in the workbook (default "master")
#   --out               output JSON: array of chart-element specs ready to embed
#                       in a workbook spec's pages[].elements[]
#
# Per chart zone, the script reads the matching view CSV's first two headers
# (dim + measure). It then:
#   - Maps each header to a master column using the regex map.
#   - Picks the Sigma element `kind` from chart_kind (with `automatic` → bar
#     fallback + a warning to verify against the PNG).
#   - Reads zone.sort: emits xAxis.sort iff Tableau had a <sort>. Otherwise
#     leaves xAxis unsorted (Sigma renders natural categorical / date order).
#   - Reads zone.aggregations: applies the right Sigma aggregator. Tableau
#     "Sum"→Sum, "Avg"→Avg, "Min"→Min, "Max"→Max, "Median"→Median,
#     "CountD"→CountDistinct, "None"→raw column (no agg), "User"→already-
#     aggregated calc field formula (use as-is via the master column).
#   - Reads zone.channels.color: if present, build one yAxis per category in
#     the master column's distinct values (best-effort — agent should fill in
#     the real category list when they know it; we emit a TODO marker).
#   - Skips action filters ("[Action (Foo)]") — those are cross-chart dashboard
#     actions, not value filters.
#
# Output: array of element specs. Drop into pages[].elements[] in the workbook
# spec and POST via post-and-readback.rb.

require 'json'
require 'csv'
require 'optparse'

opts = { master_id: 'master' }
OptionParser.new do |p|
  p.on('--tableau-dir DIR')         { |v| opts[:tab] = v }
  p.on('--layout PATH')             { |v| opts[:layout] = v }
  p.on('--master-map PATH')         { |v| opts[:mmap] = v }
  p.on('--master-element-id ID')    { |v| opts[:master_id] = v }
  p.on('--out PATH')                { |v| opts[:out] = v }
end.parse!
%i[tab layout mmap out].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }

# ---- chart_kind → Sigma element kind ----
SIGMA_KIND = {
  'bar'           => 'bar-chart',
  'line'          => 'line-chart',
  'area'          => 'area-chart',
  'pie'           => 'pie-chart',
  'scatter'       => 'scatter-chart',
  'map-region'    => 'region-map',
  'map-point'     => 'point-map',
  'table-or-text' => 'table',
  'automatic'     => 'bar-chart',     # fallback; agent verifies against PNG
  'other'         => 'bar-chart'
}.freeze

# ---- Tableau derivation → Sigma aggregation function name ----
SIGMA_AGG = {
  'Sum'    => 'Sum',
  'Avg'    => 'Avg',
  'Min'    => 'Min',
  'Max'    => 'Max',
  'Median' => 'Median',
  'CountD' => 'CountDistinct',
  'Count'  => 'CountIf(IsNotNull(%s))',  # special — see render_agg below
  'None'   => nil,                       # no aggregation; raw column ref
  'User'   => nil                        # user-defined calc — already aggregated
}.freeze

# ---- Date truncation derivations ----
DATE_TRUNC = {
  'Year-Trunc'   => 'year',
  'Quarter-Trunc'=> 'quarter',
  'Month-Trunc'  => 'month',
  'Week-Trunc'   => 'week',
  'Day-Trunc'    => 'day',
  'Hour-Trunc'   => 'hour'
}.freeze

def render_agg(agg, master_col_ref)
  return master_col_ref if agg.nil?
  if agg.include?('%s')
    agg.sub('%s', master_col_ref)
  else
    "#{agg}(#{master_col_ref})"
  end
end

# Translate the Tableau column reference inside aggregations dict to a clean key
# we can look up. Tableau uses internal IDs like "[33b6c718-9b55-3dc0-9698-…]"
# OR friendly names like "[NET_REVENUE]". We strip the brackets for matching.
def strip_brackets(s)
  s.to_s.sub(/^\[/, '').sub(/\]$/, '')
end

# Match a CSV header (e.g., "Gross Revenue", "Distinct count of Order Id") to
# a master-table column using regex map.
def map_column(header, mmap)
  mmap.each do |pat, info|
    return info if Regexp.new(pat).match?(header.to_s)
  end
  nil
end

# Pick the best aggregation for a header. CSV headers often hint at the
# aggregation ("Sum of X" / "Distinct count of X" / etc.).
def infer_csv_agg(header)
  case header.to_s
  when /^sum of /i        then 'Sum'
  when /^avg of /i        then 'Avg'
  when /^min of /i        then 'Min'
  when /^max of /i        then 'Max'
  when /^median of /i     then 'Median'
  when /\bdistinct count\b/i then 'CountD'
  when /\bcount\b/i       then 'Count'
  else nil
  end
end

# ---- Load inputs ----
layout = JSON.parse(File.read(opts[:layout]))
mmap   = JSON.parse(File.read(opts[:mmap]))
gw     = JSON.parse(File.read(File.join(opts[:tab], 'get-workbook.json')))
views  = gw.dig('views', 'view') || []
views  = [views] unless views.is_a?(Array)
view_by_name = views.each_with_object({}) { |v, h| h[v['name']] = v }

# A workbook may have multiple dashboards; iterate all and concatenate elements.
# Drop the chart_kind=automatic warnings to stderr so the caller can act on them.
elements = []
warnings = []

layout.each do |dash|
  dash['zones'].each do |z|
    next unless z['kind'] == 'chart'
    cap = z['caption']
    next if cap.nil? || cap.empty?

    view = view_by_name[cap]
    if view.nil?
      warnings << "no Tableau view matched '#{cap}'"
      next
    end
    csv_path = File.join(opts[:tab], 'views', "#{view['id']}.csv")
    unless File.exist?(csv_path)
      warnings << "missing CSV for '#{cap}' at #{csv_path}"
      next
    end
    rows = CSV.read(csv_path)
    next if rows.empty?
    headers = rows.shift
    next unless headers.length >= 2

    dim_hdr  = headers[0]
    meas_hdr = headers[1]
    dim  = map_column(dim_hdr,  mmap)
    meas = map_column(meas_hdr, mmap)
    if dim.nil?
      warnings << "no master column matched dim header '#{dim_hdr}' for '#{cap}' — falling back to raw header"
      dim  = { 'id' => "m-#{dim_hdr.downcase.gsub(/\W+/,'-')}", 'name' => dim_hdr }
    end
    if meas.nil?
      warnings << "no master column matched measure header '#{meas_hdr}' for '#{cap}'"
      meas = { 'id' => "m-#{meas_hdr.downcase.gsub(/\W+/,'-')}", 'name' => meas_hdr }
    end

    # Decide the Sigma aggregator. Priority:
    #   1. parse-twb-layout.rb's aggregations dict (most authoritative — comes
    #      from Tableau's column-instance derivation)
    #   2. CSV header naming heuristic ("Sum of X" → Sum)
    #   3. Default Sum for numeric, no-agg for text
    agg_label = nil
    (z['aggregations'] || {}).each do |col_ref, deriv|
      stripped = strip_brackets(col_ref)
      if stripped.casecmp(meas['name']).zero? ||
         stripped.casecmp(meas_hdr).zero? ||
         meas_hdr.downcase.include?(stripped.downcase[0..15])
        agg_label = deriv
        break
      end
    end
    agg_label ||= infer_csv_agg(meas_hdr)
    agg_label ||= 'Sum'
    sigma_agg = SIGMA_AGG[agg_label] || 'Sum'

    # Decide if the dimension is a date that needs DateTrunc. The parser's
    # aggregations dict surfaces Month-Trunc / Year-Trunc / etc. on the date col.
    dim_trunc = nil
    (z['aggregations'] || {}).each do |col_ref, deriv|
      stripped = strip_brackets(col_ref)
      if DATE_TRUNC.key?(deriv) &&
         (stripped.casecmp(dim['name']).zero? || dim_hdr.downcase.include?('date'))
        dim_trunc = DATE_TRUNC[deriv]
        break
      end
    end

    el_id = "el-#{cap.downcase.gsub(/\W+/, '-')[0..40]}".sub(/-$/, '')

    dim_formula = if dim['formula']                     # explicit formula override
                    dim['formula']
                  elsif dim_trunc
                    %(DateTrunc("#{dim_trunc}", [Master/#{dim['name']}]))
                  else
                    "[Master/#{dim['name']}]"
                  end
    # If the measure mapping carries a `formula` key, that's a workbook-level
    # calc like Return Rate = Sum(...)/Count(...). Use it verbatim. Otherwise
    # wrap the master-table column with the Sigma aggregator picked above.
    measure_formula = if meas['formula']
                        meas['formula']
                      else
                        render_agg(sigma_agg, "[Master/#{meas['name']}]")
                      end

    dim_col_obj = { 'id' => "x-#{el_id}", 'name' => dim['name'], 'formula' => dim_formula }
    dim_col_obj['format'] = { 'kind' => 'datetime', 'formatString' => '%b %Y' } if dim_trunc
    meas_col_obj = { 'id' => "y-#{el_id}", 'name' => meas['name'], 'formula' => measure_formula }
    # Format priority: explicit `format` on the map entry, else heuristic by name.
    meas_col_obj['format'] = meas['format'] if meas['format'].is_a?(Hash)
    if meas_col_obj['format'].nil?
      meas_col_obj['format'] =
        case meas['name'].downcase
        when /(revenue|profit|cost|sales|amount|spend)/
          { 'kind' => 'number', 'formatString' => '$,.0f', 'currencySymbol' => '$' }
        when /(rate|margin|pct|percent|ratio)/
          { 'kind' => 'number', 'formatString' => ',.2%' }
        else
          { 'kind' => 'number', 'formatString' => ',.0f' }
        end
    end
    # Allow `format` on map entries to be either a Sigma format object OR a
    # bare formatString string for convenience.
    if meas['format'].is_a?(String)
      meas_col_obj['format'] = { 'kind' => 'number', 'formatString' => meas['format'] }
    end

    kind = SIGMA_KIND[z['chart_kind']] || 'bar-chart'
    if z['chart_kind'] == 'automatic'
      warnings << "'#{cap}' has chart_kind=automatic — defaulted to bar-chart; verify against PNG"
    end

    element = {
      'id'      => el_id,
      'kind'    => kind,
      'name'    => cap,
      'source'  => { 'kind' => 'table', 'elementId' => opts[:master_id] },
      'columns' => [dim_col_obj, meas_col_obj]
    }

    if kind == 'pie-chart' || kind == 'donut-chart'
      element['color'] = { 'id' => dim_col_obj['id'] }
      element['value'] = { 'id' => meas_col_obj['id'] }
    else
      x_axis = { 'id' => dim_col_obj['id'] }
      # Sort: only set when Tableau explicitly sorted. parse-twb-layout emits
      # nil when there's no <sort> on the worksheet — leave Sigma's xAxis
      # unsorted in that case (natural order matches Tableau's default).
      if z['sort']
        dir = z.dig('sort', 'direction').to_s
        sigma_dir = (dir =~ /desc/i) ? 'descending' : 'ascending'
        x_axis['sort'] = { 'by' => meas_col_obj['id'], 'direction' => sigma_dir }
      end
      element['xAxis'] = x_axis
      element['yAxis'] = [{ 'id' => meas_col_obj['id'] }]
    end

    # Surface action filters (they get skipped — these are cross-chart actions,
    # not value filters)
    action_filters = (z['filters'] || []).select { |f|
      f['column'].to_s.include?('[Action (') || f['column'].to_s.start_with?('[Action ')
    }
    if action_filters.any?
      warnings << "'#{cap}' has #{action_filters.size} Tableau action filter(s) — skipped (cross-chart actions, not value filters)"
    end

    # If channels.color is set, that's a multi-series signal. Emit a TODO note
    # so the agent can fan-out the yAxis with one If() per category. We don't
    # auto-fan because we don't have a reliable categorical-values list here.
    if z.dig('channels', 'color', 'column')
      warnings << "'#{cap}' has a color channel on #{z['channels']['color']['column']} — chart is single-series; agent should fan-out yAxis with one If() per category (see refs/workbook-layout.md \"Multi-series chart patterns\")"
    end

    elements << element
  end
end

File.write(opts[:out], JSON.pretty_generate(elements))
warn "wrote #{opts[:out]}  (#{elements.size} chart elements)"
warnings.each { |w| warn "  WARN  #{w}" }
