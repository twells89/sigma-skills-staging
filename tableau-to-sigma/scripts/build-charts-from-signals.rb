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
  p.on('--meta PATH', 'parse-twb-layout sister meta file (worksheets+shared_filters)') { |v| opts[:meta] = v }
  p.on('--master-map PATH')         { |v| opts[:mmap] = v }
  p.on('--master-element-id ID')    { |v| opts[:master_id] = v }
  p.on('--controls PATH', 'JSON file: array of control specs to emit alongside the chart elements') { |v| opts[:controls] = v }
  p.on('--title STR',     'Dashboard title text element to emit (e.g., "Orders Dashboard")')         { |v| opts[:title] = v }
  p.on('--page-per-worksheet', 'Emit one Sigma page per Tableau worksheet (ignore dashboard layout)') { opts[:pages_mode] = :worksheet }
  p.on('--auto-controls', 'Auto-emit Sigma controls from shared-view filters in --meta')              { opts[:auto_controls] = true }
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
meta   = opts[:meta] ? JSON.parse(File.read(opts[:meta])) : { 'worksheets' => {}, 'shared_filters' => [] }
gw     = JSON.parse(File.read(File.join(opts[:tab], 'get-workbook.json')))
views  = gw.dig('views', 'view') || []
views  = [views] unless views.is_a?(Array)
view_by_name = views.each_with_object({}) { |v, h| h[v['name']] = v }

# Translate a Tableau format-value string (already parsed by the parser's
# translate_format) into a Sigma format hash. Done here so we don't fork the
# parser logic — we just call into it via a duplicated minimal translator.
def tableau_format_to_sigma(s)
  return nil if s.nil? || s.empty?
  if (m = s.match(/^p\d*(?:\.(\d+))?%$/i))
    decimals = (m[1] || '').length
    return { 'kind' => 'number', 'formatString' => ",.#{decimals}%" }
  end
  if (m = s.match(/^C\d+(?:\.(\d+))?%?$/))
    decimals = (m[1] || '').length
    return { 'kind' => 'number', 'formatString' => "$,.#{decimals}f", 'currencySymbol' => '$' }
  end
  if s.start_with?('$')
    decimals = (s.match(/\.(0+)/) || [])[1].to_s.length
    return { 'kind' => 'number', 'formatString' => "$,.#{decimals}f", 'currencySymbol' => '$' }
  end
  if s =~ /^[#,0]+(?:\.(0+))?$/
    decimals = ($1 || '').length
    return { 'kind' => 'number', 'formatString' => ",.#{decimals}f" }
  end
  if s =~ /yyyy|MMM|MM|dd|HH/
    f = s.gsub('yyyy','%Y').gsub('yy','%y').gsub('MMMM','%B').gsub('MMM','%b').gsub('MM','%m')
         .gsub('dd','%d').gsub('HH','%H').gsub('mm','%M').gsub('ss','%S')
    return { 'kind' => 'datetime', 'formatString' => f }
  end
  nil
end

# Sigma formulas reference controls by `controlId` in brackets, NOT by display
# name. This helper computes the controlId the auto-controls block will emit
# for a given parameter caption so the translated Switch/If formulas match.
def param_control_ref(caption)
  "[ctl-param-#{caption.downcase.gsub(/\W+/, '-').sub(/-$/, '')}]"
end

# ---- Parameter / CASE translator ------------------------------------------
# Tableau CASE-on-parameter:
#   CASE [Parameters].[Analysis Type]
#     WHEN "Customer Type" THEN [CUSTOMER_TYPE]
#     WHEN "Overall"       THEN "Overall"
#     WHEN "Region"        THEN [REGION_NAME]
#     ELSE "Country"
#   END
# Sigma:
#   Switch([Analysis Type], "Customer Type", [Customer Type], "Overall",
#          "Overall", "Region", [Region Name], "Country")
#
# We accept the slightly-loose form Tableau uses (`Case` token-case insensitive,
# bracket refs for parameter and for dim columns, mixed quoted strings).
def translate_case_on_param(formula, param_captions)
  return nil unless formula =~ /\bCASE\b/i
  # Strip newlines + collapse spaces
  s = formula.gsub(/\s+/, ' ').strip
  m = s.match(/\bCASE\b\s+(.*?)\s+(WHEN\b.*?)\s+\bEND\b/i)
  return nil unless m
  param_ref = m[1].strip   # the value being switched, e.g. [Parameters].[X] or [X]
  body = m[2]
  # Pull WHEN ... THEN ... pairs + optional ELSE
  pairs = body.scan(/WHEN\s+(.+?)\s+THEN\s+(.+?)(?=\s+WHEN\b|\s+ELSE\b|\z)/i).map { |a, b| [a.strip, b.strip] }
  else_match = body.match(/\bELSE\b\s+(.+)\z/i)
  else_expr = else_match && else_match[1].strip
  return nil if pairs.empty?
  # Normalise parameter reference: prefer the human caption when we know it,
  # otherwise strip [Parameters].[...] wrapping.
  param_caption = nil
  if (mm = param_ref.match(/\[Parameters?(?:\s*\([^)]*\))?\]\s*\.\s*\[([^\]]+)\]/i))
    param_caption = mm[1]
  elsif (mm = param_ref.match(/\[([^\]]+)\]/))
    param_caption = mm[1] if param_captions.include?(mm[1])
  end
  return nil unless param_caption
  parts = [param_control_ref(param_caption)]
  pairs.each { |when_val, then_val| parts << when_val; parts << then_val }
  parts << else_expr if else_expr
  "Switch(#{parts.join(', ')})"
end

# Translate IF/ELSEIF chains on a parameter ref:
#   IF [Param] = "A" THEN x ELSEIF [Param] = "B" THEN y ELSE z END
# → Switch([Param], "A", x, "B", y, z)
def translate_if_chain_on_param(formula, param_captions)
  s = formula.gsub(/\s+/, ' ').strip
  return nil unless s =~ /\bIF\b.*\bEND\b/i
  return nil unless param_captions.any? { |cap| s.include?("[#{cap}]") }
  m = s.match(/\bIF\b\s+(.+?)\s+\bEND\b/i)
  return nil unless m
  body = m[1]
  # Pull `<cond> THEN <result>` segments delimited by ELSEIF
  segs = body.scan(/(.+?)\s+THEN\s+(.+?)(?=\s+ELSEIF\b|\s+ELSE\b|\z)/i).map { |c, r| [c.strip, r.strip] }
  else_match = body.match(/\bELSE\b\s+(.+)\z/i)
  else_expr = else_match && else_match[1].strip
  return nil if segs.empty?
  # All conditions must be `[Param] = "..."` for the same parameter
  param_caption = nil
  cases = []
  segs.each do |cond, result|
    cm = cond.match(/\[([^\]]+)\]\s*=\s*("[^"]*"|'[^']*'|\S+)/)
    return nil unless cm
    p_cap = cm[1]
    return nil unless param_captions.include?(p_cap)
    param_caption ||= p_cap
    return nil unless p_cap == param_caption
    val = cm[2]
    val = val.gsub("'", '"') if val.start_with?("'")
    cases << val << result
  end
  parts = [param_control_ref(param_caption)] + cases
  parts << else_expr if else_expr
  "Switch(#{parts.join(', ')})"
end

# Pick the Tableau format for a given header against a worksheet's formats dict.
# Match by best-effort: field ref contains a column GUID OR a friendly name
# fragment that overlaps with the header.
def pick_tableau_format(formats, header)
  return nil if formats.nil? || formats.empty?
  hkey = header.to_s.downcase.gsub(/\W+/, '')
  formats.each do |field, val|
    body = field.to_s.downcase
    # Friendly-name match: format key looks like `[usr:Return Rate:qk]`. Pull
    # the human chunk and compare to header.
    inner = body.scan(/\[([^\]]+)\]/).flatten.last.to_s
    parts = inner.split(':')
    friendly = parts.length >= 3 ? parts[1].to_s.gsub(/\W+/, '') : ''
    if !friendly.empty? && (friendly == hkey || hkey.include?(friendly) || friendly.include?(hkey))
      sigma = tableau_format_to_sigma(val)
      return sigma if sigma
    end
  end
  nil
end

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
    # Format priority:
    #   1. explicit `format` on the master-map entry
    #   2. Tableau's own format string for this measure (zone.formats — only set
    #      when --meta was provided)
    #   3. heuristic by header name
    meas_col_obj['format'] = meas['format'] if meas['format'].is_a?(Hash)
    if meas_col_obj['format'].nil?
      tab_fmt = pick_tableau_format(z['formats'], meas_hdr) ||
                pick_tableau_format(z['formats'], meas['name'])
      meas_col_obj['format'] = tab_fmt if tab_fmt
    end
    if meas_col_obj['format'].nil?
      meas_col_obj['format'] =
        case meas['name'].downcase
        when /(revenue|profit|cost|sales|amount|spend)/
          { 'kind' => 'number', 'formatString' => '$,.0f', 'currencySymbol' => '$' }
        when /(rate|margin|pct|percent|ratio)/
          { 'kind' => 'number', 'formatString' => ',.1%' }
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

    # Per-chart value filters (skip action filters — already warned above).
    # Translate each non-action filter into a Sigma element-level filter spec
    # using the parser's normalized fields (column_caption, kind, members,
    # period_type, etc.). We map the caption → master column via the same
    # regex map used for dim/measure.
    value_filters = (z['filters'] || []).reject { |f| f['is_action'] }
    el_filters = []
    value_filters.each do |f|
      fcap = f['column_caption'] || f['raw_param']
      m = fcap ? map_column(fcap, mmap) : nil
      if m.nil?
        warnings << "value filter on '#{cap}' targets '#{fcap}' — no master column matched, skipping"
        next
      end
      case f['kind']
      when 'list'
        el_filters << {
          'columnId' => m['id'],
          'kind' => 'list', 'mode' => 'include', 'selectionMode' => 'multiple',
          'values' => (f['members'] || []), 'includeNulls' => false
        }
      when 'relative-date'
        # Tableau first-period=0, last-period=0 + period-type=year means
        # "this year". Translate to Sigma relative date-range.
        el_filters << {
          'columnId' => m['id'], 'kind' => 'date-range', 'mode' => 'relative',
          'unit' => f['period_type'] || 'year', 'count' => 1,
          'includeNulls' => f['include_null'].to_s == 'true'
        }
      when 'number-range'
        el_filters << {
          'columnId' => m['id'], 'kind' => 'number-range', 'mode' => 'between',
          'min' => f['min'], 'max' => f['max']
        }
      end
    end
    element['filters'] = el_filters unless el_filters.empty?

    # Surface Tableau-side calculated fields the worksheet uses, and auto-
    # translate the ones we know how to handle (parameter-driven Switch).
    # Otherwise emit a translation hint so the agent can wire it up by hand.
    param_caps = (meta['parameters'] || []).map { |p| p['caption'] }.compact
    (z['calculations'] || []).each do |c|
      formula = c['formula'].to_s
      next if formula.empty?
      next if formula =~ /\A\s*(SUM|COUNT|AVG|MIN|MAX)\(\[[^\]]+\]\)\s*\z/
      next if formula =~ /\A\s*\[[^\]]+\]\s*\z/

      # Try parameter-driven translations first (CASE / IF chain on param).
      translated = translate_case_on_param(formula, param_caps) ||
                   translate_if_chain_on_param(formula, param_caps)
      if translated
        # Drop the calc onto the chart element as an inline calc column. The
        # column id is derived from the calc name (strip brackets) so it's
        # stable across re-runs.
        calc_name = c['name'].to_s.gsub(/^\[|\]$/, '')
        calc_id   = "calc-#{calc_name.downcase.gsub(/\W+/, '-')[0..40]}".sub(/-$/, '')
        element['columns'] << {
          'id'      => calc_id,
          'name'    => calc_name,
          'formula' => translated
        }
        warnings << "'#{cap}' parameter-driven calc #{c['name']} → translated to Switch: #{translated[0..120]}"
        next
      end

      hint = if formula =~ /\bIIF\(.*=.*0.*,\s*SUM.*\/\s*SUM/
               'ratio calc — translate as `Sum(num) / NullIf(Sum(den), 0)` on master OR via Custom SQL'
             elsif formula =~ /\bIF\b.*\bELSEIF\b.*\bEND\b/i
               'IF/ELSEIF chain — translate to nested Sigma If(...) or Switch(...) on master'
             elsif formula =~ /\bCASE\b/i
               'CASE statement — translate to Sigma Switch(value, when1, then1, ...) on master'
             elsif formula =~ /\bSUM\(.*\)\s*\/\s*COUNT\(/i
               'ratio calc — translate as `Sum(...) / Count(...)` (or CountIf for NotNull) on master'
             elsif formula =~ /\[Parameters?\]\.|\[Parameters?\s+\(/
               'parameter-driven calc — translate to Sigma control + Switch()/If() formula'
             else
               'calc — translate to Sigma formula and add as a master column or workbook calc'
             end
      warnings << "'#{cap}' uses Tableau calc #{c['name']}: #{hint}. Formula: #{formula[0..120]}"
    end

    # Stamp with worksheet name so the page-per-worksheet emitter can group.
    element['_worksheet'] = cap
    elements << element
  end
end

# ---- Title text element ----
# If --title given, emit a text element. If --title omitted AND the parser
# found a title/text zone, infer the dashboard name from the parser output.
auto_title = nil
if opts[:title].nil?
  layout.each do |dash|
    next unless dash['zones'].any? { |z| %w[title text].include?(z['kind']) && (z['y_pct'] || 100) < 10 }
    auto_title = dash['dashboard']
    break
  end
end
title_text = opts[:title] || auto_title

extras = []
if title_text
  extras << {
    'id'   => 'title-text',
    'kind' => 'text',
    'body' => "## #{title_text}"
  }
end

# ---- Auto-generated parameter controls (--auto-controls) ------------------
# Tableau parameters become Sigma controls. The control's name matches the
# parameter caption so any translated `Switch([Param Caption], ...)` formula
# resolves to this control.
param_controls = []
if opts[:auto_controls]
  (meta['parameters'] || []).each_with_index do |p, i|
    cap = p['caption'].to_s.strip
    next if cap.empty?
    slug = cap.downcase.gsub(/\W+/, '-').sub(/-$/, '')
    spec = {
      'id'        => "el-param-#{slug}",
      'kind'      => 'control',
      'controlId' => "ctl-param-#{slug}",
      'name'      => cap,
      'includeNulls' => 'when-no-value-is-selected'
    }
    if p['param_domain'] == 'list'
      spec['controlType']   = 'segmented'
      spec['source'] = {
        'kind' => 'manual', 'valueType' => 'text',
        'values' => p['members'] || [], 'labels' => []
      }
      spec['value'] = p['default_value']
    elsif p['param_domain'] == 'range' && %w[integer real].include?(p['datatype'])
      # Numeric range parameters need a control shape that the workbook spec
      # API currently doesn't accept under controlType=number. Emit a warning
      # so the agent can add the control by hand; don't break the spec.
      warnings << "parameter '#{cap}' is a numeric range (#{p['datatype']}) — skipped auto-control; agent should add a number/range control manually"
      next
    elsif p['param_domain'] == 'range' && %w[date datetime].include?(p['datatype'])
      spec['controlType'] = 'date-range'
      spec['mode'] = 'between'
    else
      # Generic fallback — text input
      spec['controlType'] = 'text'
      spec['value'] = p['default_value']
    end
    param_controls << spec
  end
end

# ---- Auto-generated controls from shared-view filters (--auto-controls) ----
auto_controls = []
if opts[:auto_controls]
  (meta['shared_filters'] || []).each_with_index do |f, i|
    next if f['is_action']
    cap = f['column_caption']
    if cap.nil?
      warnings << "shared filter ##{i} has no resolvable column_caption (raw_param=#{f['raw_param']}) — skipping auto-control"
      next
    end
    m = map_column(cap, mmap)
    if m.nil?
      warnings << "shared filter on '#{cap}' has no master-map entry — add a regex to master-columns.json"
      next
    end
    slug = cap.downcase.gsub(/\W+/, '-').sub(/-$/, '')
    spec = {
      'id'           => "el-ctl-#{slug}",
      'kind'         => 'control',
      'controlId'    => "ctl-#{slug}",
      'name'         => cap.strip,
      'includeNulls' => 'when-no-value-is-selected'
    }
    case f['kind']
    when 'list'
      spec['controlType']   = 'list'
      spec['mode']          = 'include'
      spec['selectionMode'] = 'multiple'
      spec['values']        = []  # default to all; user adjusts in UI
      spec['source'] = {
        'kind'     => 'source',
        'source'   => { 'kind' => 'table', 'elementId' => opts[:master_id] },
        'columnId' => m['id']
      }
      spec['filters'] = [{
        'source'   => { 'kind' => 'table', 'elementId' => opts[:master_id] },
        'columnId' => m['id']
      }]
    when 'relative-date'
      # Tableau's relative-date with first-period=0/last-period=0 +
      # period-type=year means "this year". Sigma's "current" mode + unit takes
      # the same role; count=0 isn't valid so we omit it.
      spec['controlType'] = 'date-range'
      spec['mode']        = 'current'
      spec['unit']        = f['period_type'] || 'year'
      spec['filters'] = [{
        'source'   => { 'kind' => 'table', 'elementId' => opts[:master_id] },
        'columnId' => m['id']
      }]
    when 'number-range'
      spec['controlType'] = 'range-slider'
      spec['filters'] = [{
        'source'   => { 'kind' => 'table', 'elementId' => opts[:master_id] },
        'columnId' => m['id']
      }]
    end
    auto_controls << spec
  end
end

# ---- Filter controls ----
# Caller supplies the column targets explicitly via --controls. We don't try
# to infer the column from filter zone metadata because the Tableau filter
# shelf doesn't reliably tell us which dimension it filters in this XML.
if opts[:controls]
  controls = JSON.parse(File.read(opts[:controls]))
  controls.each_with_index do |c, i|
    spec = {
      'id'          => "el-ctl-#{c['name'] ? c['name'].downcase.gsub(/\W+/, '-') : "f#{i}"}",
      'kind'        => 'control',
      'controlId'   => "ctl-#{c['name'] ? c['name'].downcase.gsub(/\W+/, '-') : "f#{i}"}",
      'name'        => c['name'] || "Filter #{i + 1}",
      'controlType' => c['type'] || 'list',
      'includeNulls' => 'when-no-value-is-selected',
      'filters' => [
        {
          'source'   => { 'kind' => 'table', 'elementId' => opts[:master_id] },
          'columnId' => c['column']
        }
      ]
    }
    case spec['controlType']
    when 'list'
      spec['mode'] = c['mode'] || 'include'
      spec['selectionMode'] = c['selectionMode'] || 'multiple'
      spec['values'] = c['values'] || []
      spec['source'] = {
        'kind'     => 'source',
        'source'   => { 'kind' => 'table', 'elementId' => opts[:master_id] },
        'columnId' => c['column']
      }
    when 'date-range'
      spec['mode'] = c['mode'] || 'between'
      if c['default']
        d = c['default']
        spec['startDate'] = d['startDate'] if d['startDate']
        spec['endDate']   = d['endDate']   if d['endDate']
        spec['unit']      = d['unit']      if d['unit']
        spec['mode']      = d['mode']      if d['mode']
      end
    when 'segmented'
      spec['source'] = c['source'] || {
        'kind' => 'manual', 'valueType' => 'text', 'values' => c['values'] || [], 'labels' => []
      }
      spec['value'] = c['value']
    end
    extras << spec
  end
end

all_extras = extras + param_controls + auto_controls

# ---- Output mode ----
#   Default       → flat array of elements (legacy behaviour). Extras first.
#   --page-per-worksheet → emit { pages: [{name, elements:[]}] }. One page per
#                          worksheet that has a chart, with the shared-filter
#                          auto-controls AND a title text duplicated onto each
#                          page so the customer sees the same filter set on
#                          every page (Tableau dashboard-level filter semantics).
if opts[:pages_mode] == :worksheet
  pages = []
  by_ws = elements.group_by { |e| e['_worksheet'] }
  by_ws.each do |ws_name, els|
    els.each { |e| e.delete('_worksheet') }
    page_extras = []
    if title_text
      page_extras << {
        'id'   => "title-text-#{ws_name.downcase.gsub(/\W+/,'-')[0..30]}".sub(/-$/, ''),
        'kind' => 'text',
        'body' => "## #{ws_name}"
      }
    end
    # Auto-controls duplicated per page (Sigma controls are page-scoped). Each
    # page gets its own copy with a unique element `id` (workbook-globally
    # unique); the `controlId` stays the same across pages because controls are
    # page-scoped and formulas resolve against the current page's controls.
    # Parameter controls go first so the rendered order is param → filters.
    (param_controls + auto_controls).each do |c|
      dup = JSON.parse(c.to_json)
      ws_slug = ws_name.downcase.gsub(/\W+/, '-')[0..20]
      dup['id'] = "#{dup['id']}-#{ws_slug}"
      page_extras << dup
    end
    pages << {
      'name'     => ws_name,
      'elements' => page_extras + els
    }
  end
  File.write(opts[:out], JSON.pretty_generate({ 'pages' => pages }))
  warn "wrote #{opts[:out]} (page-per-worksheet: #{pages.size} pages, #{auto_controls.size} auto-controls per page)"
else
  elements.each { |e| e.delete('_worksheet') }
  all_elements = all_extras + elements
  File.write(opts[:out], JSON.pretty_generate(all_elements))
  warn "wrote #{opts[:out]}  (#{all_elements.size} elements: #{all_extras.size} controls/text + #{elements.size} charts)"
end
warnings.each { |w| warn "  WARN  #{w}" }
