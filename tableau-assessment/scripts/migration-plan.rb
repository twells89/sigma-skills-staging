#!/usr/bin/env ruby
# Compose a migration-plan.json that the assessment hands to downstream
# migration skills (tableau-to-sigma, tableau-vds-to-snowflake) for direct
# invocation.
#
# Inputs (all from /tmp/assessment-<site>/):
#   shortlist.json     — per-workbook score/tag (migrate-first / easy-win /
#                        moderate / retire / needs-gap-scout)
#   data-sources.json  — per-datasource Sigma-readiness verdict
#                        (drop-in / verify-network / verify-db / verify-modeling /
#                         land-in-warehouse / red-flag)
#   complexity.json    — per-workbook gap-scan summary (auto/hint/manual/unhandled)
#   twbs/              — downloaded .twb files (for warehouse-table extraction)
#
# Output: migration-plan.json with:
#   - workbooks[]: { workbookId, name, recommended_path, priority_tier, blockers,
#                    warehouse_tables, cluster_id }
#   - datasources[]: { id, name, recommended_path, verdict, reason }
#   - dm_clusters[]: { id, workbookIds, shared_warehouse_tables }
#   - summary: counts + suggested batch
#
# `recommended_path` values:
#   "tableau-to-sigma"          → workbook ready for conversion
#   "tableau-to-sigma-with-scout" → conversion needs gap-scout iterations first
#   "vds-to-snowflake"          → datasource should land in Snowflake before workbook conversion
#   "retire"                    → unused (accesses==0); recommend not migrating
#   "blocked"                   → known unsupported features; needs manual rework
#
# Usage: ruby scripts/migration-plan.rb --out /tmp/assessment-<site>

require 'json'
require 'optparse'
require 'set'
require 'rexml/document'

opts = { similarity: 0.5 }
OptionParser.new do |p|
  p.on('--out DIR')                 { |v| opts[:out] = v }
  p.on('--similarity F', Float,
       'Jaccard threshold for DM clustering (default 0.5)') { |v| opts[:similarity] = v }
end.parse!
abort('--out required') unless opts[:out]

shortlist_path  = File.join(opts[:out], 'shortlist.json')
ds_path         = File.join(opts[:out], 'data-sources.json')
complexity_path = File.join(opts[:out], 'complexity.json')
twb_dir         = File.join(opts[:out], 'twbs')

shortlist  = File.exist?(shortlist_path)  ? JSON.parse(File.read(shortlist_path))  : []
data_srcs  = File.exist?(ds_path)         ? JSON.parse(File.read(ds_path))         : { 'sources' => [] }
complexity = File.exist?(complexity_path) ? JSON.parse(File.read(complexity_path)) : { 'workbooks' => {} }

# Per-workbook warehouse-table extraction from .twb. Same logic as
# tableau-to-sigma/scripts/build-real-sig.rb but inlined.
def extract_warehouse_tables(twb_path)
  return [] unless File.exist?(twb_path)
  begin
    doc = REXML::Document.new(File.read(twb_path, encoding: 'utf-8', invalid: :replace))
  rescue StandardError
    return []
  end
  out = []
  doc.elements.each('//relation[@type="table"]') do |r|
    raw = r.attributes['table'].to_s.gsub(/[\[\]]/, '')
    table =
      if (m = raw.match(/\(([^)]+)\)$/));               m[1]
      elsif (m = raw.match(/[0-9a-f-]{30,}\.(.+)$/i));  m[1]
      else;                                              raw
      end
    out << table.to_s.upcase.strip if table && !table.empty?
  end
  out.uniq
end

# --- workbook side ---
workbook_entries = shortlist.map do |w|
  name = w['name']
  workbookId = w['workbookId'] || w['id']
  tag = w['tag']
  # Find the local .twb (fetch-all-twbs.rb names files by sanitized workbook name)
  twb_candidates = Dir.glob(File.join(twb_dir, '*.twb'))
  twb_path = twb_candidates.find { |p| File.basename(p, '.twb').gsub(/[^a-z0-9]/i, '').downcase == name.to_s.gsub(/[^a-z0-9]/i, '').downcase }
  whouse_tables = twb_path ? extract_warehouse_tables(twb_path) : []
  cx = (complexity['workbooks'] || {})[name] || {}

  recommended_path =
    case tag
    when 'retire'           then 'retire'
    when 'needs-gap-scout'  then 'tableau-to-sigma-with-scout'
    when 'migrate-first', 'easy-win', 'moderate'
      # Block if too many manual/unhandled features
      if (cx['manual'].to_i + cx['unhandled'].to_i) > 5
        'blocked'
      else
        'tableau-to-sigma'
      end
    else
      'tableau-to-sigma'
    end

  blockers = []
  blockers << "#{cx['unhandled']} unhandled feature(s)"  if cx['unhandled'].to_i > 0
  blockers << "#{cx['manual']} manual-setup feature(s)"  if cx['manual'].to_i > 0
  blockers << 'no usage (accesses=0)'                    if tag == 'retire'

  {
    'workbookId'        => workbookId,
    'name'              => name,
    'recommended_path'  => recommended_path,
    'priority_tier'     => tag,
    'score'             => w['score'],
    'accesses'          => w['accesses'],
    'actors'            => w['actors'],
    'warehouse_tables'  => whouse_tables,
    'blockers'          => blockers
  }
end

# --- datasource side ---
datasource_entries = (data_srcs['sources'] || []).map do |s|
  v = s['verdict']
  recommended_path =
    case v
    when 'land-in-warehouse', 'red-flag' then 'vds-to-snowflake'
    when 'drop-in'                        then 'drop-in'
    when 'verify-network', 'verify-db', 'verify-modeling' then 'verify-then-migrate'
    else 'verify-then-migrate'
    end
  {
    'id'                => s['datasourceId'] || s['id'],
    'name'              => s['name'],
    'verdict'           => v,
    'recommended_path'  => recommended_path,
    'reason'            => s['reason'] || s['action']
  }
end

# --- DM clustering ---
# Cluster workbooks whose warehouse-table sets are Jaccard-similar ≥ threshold
# AND share at least one "fact-shaped" table (ends in _FACT or contains FACT).
def jaccard(a, b)
  a = a.to_set; b = b.to_set
  return 0.0 if (a | b).empty?
  (a & b).size.to_f / (a | b).size
end

def has_fact_overlap?(a, b)
  shared = (a.to_set & b.to_set).to_a
  shared.any? { |t| t.upcase.include?('FACT') } || shared.any? { |t| t.upcase.end_with?('_FACT') }
end

clusterable = workbook_entries.select do |w|
  %w[tableau-to-sigma tableau-to-sigma-with-scout].include?(w['recommended_path']) &&
    !w['warehouse_tables'].empty?
end

clusters = []
unassigned = clusterable.dup
while (seed = unassigned.shift)
  members = [seed]
  unassigned.reject! do |w|
    sim = jaccard(seed['warehouse_tables'], w['warehouse_tables'])
    if sim >= opts[:similarity] && has_fact_overlap?(seed['warehouse_tables'], w['warehouse_tables'])
      members << w
      true
    end
  end
  shared = members.map { |m| m['warehouse_tables'].to_set }.reduce(:&) || Set.new
  cluster_id = "cluster-#{(clusters.size + 1).to_s.rjust(2, '0')}-#{seed['warehouse_tables'].first&.downcase&.gsub(/[^a-z0-9]/, '-') || 'misc'}"
  members.each { |m| m['cluster_id'] = cluster_id }
  clusters << {
    'id'                       => cluster_id,
    'seed_workbook'            => seed['name'],
    'workbookIds'              => members.map { |m| m['workbookId'] },
    'workbook_names'           => members.map { |m| m['name'] },
    'shared_warehouse_tables'  => shared.to_a.sort,
    'cluster_size'             => members.size
  }
end

# --- summary ---
by_path = workbook_entries.group_by { |w| w['recommended_path'] }
suggested_batch = workbook_entries
  .select { |w| w['recommended_path'] == 'tableau-to-sigma' }
  .sort_by { |w| -(w['score'].to_f) }
  .first(8)
  .map { |w| { 'workbookId' => w['workbookId'], 'name' => w['name'], 'cluster_id' => w['cluster_id'] } }

result = {
  'workbooks'   => workbook_entries,
  'datasources' => datasource_entries,
  'dm_clusters' => clusters,
  'summary' => {
    'workbooks_total'              => workbook_entries.size,
    'workbooks_ready_for_conversion' => (by_path['tableau-to-sigma']            || []).size,
    'workbooks_need_scout'         => (by_path['tableau-to-sigma-with-scout']  || []).size,
    'workbooks_blocked'            => (by_path['blocked']                       || []).size,
    'workbooks_retire'             => (by_path['retire']                        || []).size,
    'datasources_vds_to_snowflake' => datasource_entries.count { |d| d['recommended_path'] == 'vds-to-snowflake' },
    'datasources_drop_in'          => datasource_entries.count { |d| d['recommended_path'] == 'drop-in' },
    'cluster_count'                => clusters.size,
    'suggested_batch'              => suggested_batch
  }
}

File.write(File.join(opts[:out], 'migration-plan.json'), JSON.pretty_generate(result))

puts "wrote #{File.join(opts[:out], 'migration-plan.json')}"
puts "workbooks total: #{result['summary']['workbooks_total']}"
puts "  ready for tableau-to-sigma: #{result['summary']['workbooks_ready_for_conversion']}"
puts "  need gap-scout iterations:  #{result['summary']['workbooks_need_scout']}"
puts "  blocked (manual/unhandled): #{result['summary']['workbooks_blocked']}"
puts "  retire (no usage):          #{result['summary']['workbooks_retire']}"
puts "datasources: #{datasource_entries.size}"
puts "  recommend VDS→Snowflake:  #{result['summary']['datasources_vds_to_snowflake']}"
puts "  drop-in to Sigma:         #{result['summary']['datasources_drop_in']}"
puts "DM clusters: #{result['summary']['cluster_count']}"
clusters.each do |c|
  puts "  #{c['id']}: #{c['cluster_size']} workbooks, #{c['shared_warehouse_tables'].size} shared tables"
end
puts
puts "suggested first batch (top #{suggested_batch.size} ready workbooks by score):"
suggested_batch.each_with_index { |w, i| puts "  #{i + 1}. #{w['name']} (cluster: #{w['cluster_id'] || '-'})" }
