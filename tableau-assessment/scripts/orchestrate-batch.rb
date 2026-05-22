#!/usr/bin/env ruby
# Plan a bulk Tableau→Sigma conversion batch from migration-plan.json.
# This script doesn't itself spawn subagents — subagent spawning happens at
# the agent's conversation layer via the Agent tool. This script produces:
#
#   1. A respecting-DM-clusters execution plan as `batch-plan.json`:
#      - For each cluster: a "leader" workbook that builds the cluster's DM
#        (Phase 1-4 from scratch) and N "follower" workbooks that reuse the
#        leader's DM via Phase 1.5 (find-or-pick-dm.rb).
#      - Leaders run first, sequentially within a cluster but in parallel
#        across clusters. Followers run in parallel once their leader is done.
#      - Concurrency cap: --concurrent (default 3) controls how many
#        subagents the conversation-layer fires in any single message-batch.
#
#   2. The exact agent briefs (markdown) the conversation-layer should pass
#      into each Agent(subagent_type='general-purpose') call.
#
#   3. An empty `batch-results.json` skeleton the conversation-layer fills
#      in as each subagent completes (workbookId → status / sigma_url /
#      parity_tier / duration_s / errors).
#
# Aggregate semantics (continue-on-failure):
#   - GREEN: workbook posted clean (0 column-errors, verify-workbook.rb clean)
#            AND all chart actuals strict-PASS (or PASS in extract-mode).
#   - YELLOW: workbook posted clean BUT one or more charts diverge in values.
#            Structural conversion succeeded; needs human review.
#   - RED: column-type errors, POST failure, verify failure, or no actuals.
#
# Usage:
#   ruby scripts/orchestrate-batch.rb \
#     --plan /tmp/assessment-<site>/migration-plan.json \
#     --out  /tmp/assessment-<site>/batch/ \
#     [--concurrent 3] \
#     [--limit 8]        # max workbooks to convert this batch
#     [--workbook-ids id1,id2,...]   # override: pin a specific subset

require 'json'
require 'fileutils'
require 'optparse'

opts = { concurrent: 3, limit: 8 }
OptionParser.new do |p|
  p.on('--plan PATH')              { |v| opts[:plan] = v }
  p.on('--out DIR')                { |v| opts[:out]  = v }
  p.on('--concurrent N', Integer)  { |v| opts[:concurrent] = v }
  p.on('--limit N',      Integer)  { |v| opts[:limit]      = v }
  p.on('--workbook-ids IDS')       { |v| opts[:wb_ids] = v.split(',') }
end.parse!
%i[plan out].each { |k| abort "missing --#{k}" unless opts[k] }

FileUtils.mkdir_p(opts[:out])
plan = JSON.parse(File.read(opts[:plan]))

# Select workbooks for this batch — explicit IDs if given, else use the
# suggested_batch from the plan (top N by score, already filtered to
# tableau-to-sigma path), capped by --limit.
selected_ids =
  if opts[:wb_ids]
    opts[:wb_ids]
  else
    (plan.dig('summary', 'suggested_batch') || []).map { |w| w['workbookId'] }
  end
selected_ids = selected_ids.first(opts[:limit])
selected = plan['workbooks'].select { |w| selected_ids.include?(w['workbookId']) }
abort 'no workbooks selected' if selected.empty?

# Group by cluster — one leader per cluster, rest are followers.
by_cluster = selected.group_by { |w| w['cluster_id'] || "singleton-#{w['workbookId'][0..7]}" }
clusters = by_cluster.map do |cid, members|
  # Highest-score member is the leader (most likely to be representative).
  sorted = members.sort_by { |m| -(m['score'].to_f) }
  leader = sorted.first
  followers = sorted.drop(1)
  cluster_meta = (plan['dm_clusters'] || []).find { |c| c['id'] == cid }
  {
    'cluster_id'              => cid,
    'leader'                  => leader,
    'followers'               => followers,
    'shared_warehouse_tables' => cluster_meta ? cluster_meta['shared_warehouse_tables'] : []
  }
end

# Wave-style schedule:
# - Wave 0: all cluster leaders fire in parallel (up to --concurrent at a time).
#   Each leader runs the FULL tableau-to-sigma pipeline including building or
#   reusing a DM. The leader's result becomes the cluster's canonical DM id.
# - Wave 1: all followers fire in parallel, each told to reuse their cluster
#   leader's DM via find-or-pick-dm.rb + inspect-dm-shape.rb.
# Within each wave, the conversation-layer batches subagents into messages of
# `--concurrent` parallel Agent() calls.
waves = []
waves << { 'wave' => 0, 'kind' => 'leaders',    'subagents' => clusters.map { |c| { 'cluster_id' => c['cluster_id'], 'workbook' => c['leader'] } } }
follower_subs = clusters.flat_map do |c|
  c['followers'].map { |f| { 'cluster_id' => c['cluster_id'], 'workbook' => f, 'reuse_leader' => true } }
end
waves << { 'wave' => 1, 'kind' => 'followers', 'subagents' => follower_subs } if follower_subs.any?

# Brief generator. The conversation-layer feeds this string into the `prompt:`
# of an Agent() call. Brief is self-contained — subagent doesn't see the
# outer session's history.
def agent_brief(sub, cluster, batch_results_path, leader_dm_id_path)
  wb = sub['workbook']
  reuse = sub['reuse_leader']
  <<~BRIEF
    Convert one Tableau workbook to Sigma using the tableau-to-sigma skill.

    WORKBOOK
    - name:       #{wb['name']}
    - workbookId: #{wb['workbookId']}
    - priority:   #{wb['priority_tier']}

    SKILL: ~/.claude/skills/tableau-to-sigma/  (read SKILL.md fully)

    #{reuse ? <<~REUSE : <<~LEAD}
      DM REUSE — your cluster leader has already built/picked the DM. Read
      `#{leader_dm_id_path}` for `{ dataModelId, fact_element_id, denorm_plan_path }`.
      Skip Phase 2 + 3 entirely. In Phase 4, source your workbook's master
      table(s) using the leader's DM. Use the denorm plan at `denorm_plan_path`
      verbatim — direct refs for `location:fact`, Lookup formulas for
      `location:dim`. This is the dd7 preflight pattern.
    REUSE

      DM LEAD — your cluster's first workbook. You'll either:
      (a) find a reusable DM in this org via Phase 1.5 picker, then run
          Phase 1.5b inspect-dm-shape.rb on it, OR
      (b) build a new DM (Phases 2-4) sourcing from these shared warehouse
          tables: #{cluster['shared_warehouse_tables'].inspect}
      Once your DM is determined, WRITE `#{leader_dm_id_path}` with
      `{ dataModelId, fact_element_id, denorm_plan_path }` so followers can
      reuse it. If you ran inspect-dm-shape.rb, that's the denorm_plan_path.
    LEAD

    PERF
    - Fire all `mcp__tableau__get-view-data` calls in ONE parallel batch.
    - Use `find-or-pick-dm.rb --auto-pick` to skip the UX prompt.
    - Run `verify-workbook.rb`, NOT the deprecated .sh.
    - Fetch chart actuals via `mcp__sigma-mcp-v2__query` in one parallel batch.
    - Source `phase-timer.sh` and write phase-timings.json to your working dir.

    DELIVERABLES on completion — APPEND ONE LINE to `#{batch_results_path}`
    as JSON (newline-delimited; tolerate races with file locking):
      { workbookId, cluster_id: "#{sub['cluster_id']}", role: "#{reuse ? 'follower' : 'leader'}",
        sigma_workbook_url, sigma_workbook_id, dm_id_used,
        parity_tier: "GREEN" | "YELLOW" | "RED",
        column_errors: <int>, verify_status: "clean" | "fail",
        charts_pass: <int>, charts_total: <int>,
        duration_s: <float>, error_summary: <string|null> }

    PARITY TIER RULES
    - GREEN: column_errors==0 AND verify=="clean" AND charts_pass==charts_total
    - YELLOW: column_errors==0 AND verify=="clean" AND charts_pass<charts_total
    - RED: any column_error OR verify=="fail" OR POST failure

    CONTINUE-ON-FAILURE — if you hit a hard blocker (POST rejects, column-type
    error you can't resolve in 2 retry attempts, etc.), file a beads ticket
    via `bd create` and write a RED result line. Do not block other workbooks.

    Do NOT push any code changes.
  BRIEF
end

# Emit the plan: per-wave, per-subagent briefs the conversation-layer fires.
batch_results_path = File.join(opts[:out], 'batch-results.jsonl')
File.write(batch_results_path, '')   # empty file for subagent appends

cluster_lookup = clusters.each_with_object({}) { |c, h| h[c['cluster_id']] = c }
schedule = waves.map do |wave|
  {
    'wave'              => wave['wave'],
    'kind'              => wave['kind'],
    'concurrency'       => opts[:concurrent],
    'subagent_count'    => wave['subagents'].size,
    'subagents'         => wave['subagents'].map do |sub|
      cluster = cluster_lookup[sub['cluster_id']]
      leader_dm_id_path = File.join(opts[:out], "#{sub['cluster_id']}-leader-dm.json")
      {
        'subagent_label'   => "#{sub['workbook']['name'].gsub(/\W+/, '-')[0..40]}",
        'cluster_id'       => sub['cluster_id'],
        'role'             => sub['reuse_leader'] ? 'follower' : 'leader',
        'workbookId'       => sub['workbook']['workbookId'],
        'workbook_name'    => sub['workbook']['name'],
        'leader_dm_id_path'=> leader_dm_id_path,
        'agent_brief'      => agent_brief(sub, cluster, batch_results_path, leader_dm_id_path)
      }
    end
  }
end

File.write(File.join(opts[:out], 'batch-plan.json'),
           JSON.pretty_generate({
             'concurrent'           => opts[:concurrent],
             'continue_on_failure'  => true,
             'parity_tiers'         => {
               'GREEN'  => 'workbook clean + all charts strict-PASS',
               'YELLOW' => 'workbook clean + some chart parity diverges',
               'RED'    => 'column errors / POST fail / verify fail'
             },
             'cluster_count'        => clusters.size,
             'workbook_count'       => selected.size,
             'batch_results_path'   => batch_results_path,
             'waves'                => schedule
           }))

# Render an aggregation script the conversation-layer can run after each wave.
# Single-quoted heredoc disables ALL interpolation; the path is injected via
# a templated placeholder (avoids the #{...} collision with the embedded
# Ruby code in this heredoc).
agg_path = File.join(opts[:out], 'aggregate-results.rb')
agg_src = <<~'AGG'
  #!/usr/bin/env ruby
  # Read batch-results.jsonl and emit a summary table.
  require 'json'
  results_path = '__BATCH_RESULTS_PATH__'
  results = File.readlines(results_path).map { |l| JSON.parse(l) rescue nil }.compact
  if results.empty?
    puts "no results yet"
    exit 0
  end
  by_tier = results.group_by { |r| r["parity_tier"] }
  puts "Batch result (#{results.size} workbooks):"
  %w[GREEN YELLOW RED].each do |t|
    rs = by_tier[t] || []
    next if rs.empty?
    puts "  #{t}: #{rs.size}"
    rs.each { |r| puts "    - #{r["workbook_name"] || r["workbookId"]} (#{r["duration_s"]&.round(1)}s) → #{r["sigma_workbook_url"]}" }
  end
  total_s = results.sum { |r| r["duration_s"].to_f }
  puts ""
  puts "Total wall time across subagents (parallel): #{total_s.round(1)}s"
  if (max_r = results.max_by { |r| r["duration_s"].to_f })
    puts "Effective wall time (max in any wave):       #{max_r['duration_s']&.round(1)}s"
  end
AGG
File.write(agg_path, agg_src.sub('__BATCH_RESULTS_PATH__', batch_results_path))
File.chmod(0755, agg_path)

puts "wrote #{File.join(opts[:out], 'batch-plan.json')}"
puts "  clusters:  #{clusters.size}"
puts "  workbooks: #{selected.size}"
schedule.each do |w|
  puts "  wave #{w['wave']} (#{w['kind']}): #{w['subagent_count']} subagents @ concurrency=#{w['concurrency']}"
end
puts ""
puts "To execute (from the conversation-layer agent):"
puts "  1. For each wave in order, batch its subagents into messages of #{opts[:concurrent]} parallel Agent() calls"
puts "  2. Use each subagent_label as the Agent() description, agent_brief as the prompt"
puts "  3. After each wave: ruby #{agg_path}  → mid-batch summary"
puts "  4. After all waves:  ruby #{agg_path}  → final batch report"
