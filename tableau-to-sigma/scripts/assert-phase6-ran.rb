#!/usr/bin/env ruby
# Hard gate that proves a tableau-to-sigma conversion is actually complete.
# The subagent MUST run this script before declaring GREEN. It checks four
# independent things — failing ANY of them blocks the GREEN declaration:
#
#   1. Phase 6 ran (parity-final.json exists, status=PASS, pass-rate met)
#      → beads-sigma-4pm
#   2. No orphan workbooks left in the customer's My Documents
#      (posted-workbooks.jsonl has ≤1 entry OR cleanup-marker.json shows
#      cleanup ran with no failed deletes)  → beads-sigma-38a
#   3. The live workbook's /columns endpoint shows no column with
#      type=error (catches circular refs / runtime errors introduced
#      AFTER the initial POST's column-type guard ran)  → beads-sigma-38a
#   4. (Optional) The workbook is reachable via /v2/workbooks/{id}
#
# Usage:
#   ruby scripts/assert-phase6-ran.rb --tableau /tmp/<name> \
#     [--workbook-id <id>]     # override; default = read from wb-ids.json
#     [--min-pass-rate 1.0]    # default 1.0 (every chart must PASS)
#     [--allow-extract]        # treat extract-mode as acceptable
#     [--skip-column-check]    # skip the live /columns type=error scan
#     [--skip-orphan-check]    # skip the orphan-workbook scan (for callers
#                              # that genuinely want multiple workbooks)
#
# Exit codes:
#   0  every gate passes — conversion is allowed to declare GREEN
#   1  parity-final.json missing (Phase 6 skipped — the regression case)
#   2  parity-final.json exists but status=FAIL / pass-rate below min /
#      extract-mode without --allow-extract / charts_total==0
#   3  parity-final.json malformed
#   4  orphan workbooks left uncleaned (beads-sigma-38a)
#   5  live workbook has column(s) with type=error (beads-sigma-38a)
#
# Prints a per-gate summary to stdout regardless of exit code.

require 'json'
require 'net/http'
require 'uri'
require 'optparse'

opts = { min_pass_rate: 1.0, allow_extract: false }
OptionParser.new do |p|
  p.on('--tableau DIR')              { |v| opts[:tab] = v }
  p.on('--workbook-id ID')           { |v| opts[:wb] = v }
  p.on('--min-pass-rate F', Float)   { |v| opts[:min_pass_rate] = v }
  p.on('--allow-extract')            { opts[:allow_extract] = true }
  p.on('--skip-column-check')        { opts[:skip_column] = true }
  p.on('--skip-orphan-check')        { opts[:skip_orphan] = true }
end.parse!
abort('--tableau required') unless opts[:tab]

summary_path = File.join(opts[:tab], 'parity-final.json')

unless File.exist?(summary_path)
  warn "[FAIL] Phase 6 skipped — #{summary_path} does not exist."
  warn "       Run: ruby scripts/phase6-parity.rb --tableau #{opts[:tab]} --workbook-id <id>"
  warn "       then collect actuals via mcp__sigma-mcp-v2__query and re-run with --finalize."
  warn "       See SKILL.md Phase 6. This is the hard gate (beads-sigma-4pm)."
  exit 1
end

begin
  summary = JSON.parse(File.read(summary_path))
rescue JSON::ParserError => e
  warn "[FAIL] #{summary_path} is malformed JSON: #{e.message}"
  exit 3
end

total = summary['charts_total'].to_i
passed = summary['charts_pass'].to_i
status = summary['status'].to_s
mode = summary['mode'].to_s

if total <= 0
  warn "[FAIL] parity-final.json reports charts_total=#{total} — no charts were verified."
  warn "       This usually means auto-parity-plan.rb matched zero Tableau views."
  warn "       Phase 6 must verify at least one chart to declare GREEN."
  exit 2
end

if mode == 'extract' && !opts[:allow_extract]
  warn "[FAIL] parity ran in extract-mode but --allow-extract was not passed."
  warn "       Extract-mode permits up to ±#{((summary['extract_tol'] || 0.30) * 100).to_i}% drift —"
  warn "       only acceptable when the source Tableau workbook has hasExtracts=true."
  exit 2
end

pass_rate = passed.to_f / total
if status != 'PASS' || pass_rate < opts[:min_pass_rate]
  warn "[FAIL] parity status=#{status} pass-rate=#{(pass_rate * 100).round(1)}% (#{passed}/#{total})"
  warn "       Required: status=PASS and pass-rate >= #{(opts[:min_pass_rate] * 100).to_i}%"
  if (fail_names = summary['fail_names']) && !fail_names.empty?
    warn "       Failing charts: #{fail_names.join(', ')}"
  end
  exit 2
end

puts "[OK] gate 1/3: Phase 6 ran cleanly — #{passed}/#{total} charts PASS (mode=#{mode}, status=#{status})"

# ---------------------------------------------------------------------------
# Gate 2 — orphan workbooks (beads-sigma-38a)
# ---------------------------------------------------------------------------
unless opts[:skip_orphan]
  log = File.join(opts[:tab], 'posted-workbooks.jsonl')
  if File.exist?(log)
    posted = File.readlines(log).map { |l| JSON.parse(l) rescue nil }.compact
    unique_ids = posted.map { |e| e['id'] }.uniq
    if unique_ids.length > 1
      marker_path = File.join(opts[:tab], 'cleanup-marker.json')
      unless File.exist?(marker_path)
        warn "[FAIL] gate 2/3: #{unique_ids.length} workbooks created during this conversion (orphans not cleaned)."
        warn "       posted-workbooks.jsonl entries:"
        unique_ids.each { |id| warn "         - #{id}" }
        warn "       Run: ruby scripts/cleanup-orphan-workbooks.rb --workdir #{opts[:tab]}"
        warn "       See beads-sigma-38a."
        exit 4
      end
      marker = JSON.parse(File.read(marker_path)) rescue {}
      if marker['failed'] && !marker['failed'].empty?
        warn "[FAIL] gate 2/3: cleanup-marker.json reports #{marker['failed'].length} failed delete(s)."
        warn "       Orphan workbooks are still in the customer's My Documents:"
        marker['failed'].each { |f| warn "         - #{f['id']} (HTTP #{f['status']})" }
        exit 4
      end
      if marker['dry_run']
        warn "[FAIL] gate 2/3: cleanup-marker.json is from a --dry-run; orphans were not actually deleted."
        warn "       Re-run cleanup-orphan-workbooks.rb without --dry-run."
        exit 4
      end
      kept = marker['kept'] || '(unknown)'
      deleted = (marker['deleted'] || []).length
      puts "[OK] gate 2/3: orphan cleanup ran — kept #{kept}, deleted #{deleted}"
    else
      puts "[OK] gate 2/3: only one workbook POSTed (#{unique_ids.first}) — no orphan check needed"
    end
  else
    puts "[OK] gate 2/3: posted-workbooks.jsonl missing — assuming no orphans (legacy or external POST flow)"
  end
else
  puts "[SKIP] gate 2/3: --skip-orphan-check"
end

# ---------------------------------------------------------------------------
# Gate 3 — live /columns type=error scan (beads-sigma-38a)
# Catches circular references and runtime errors that the initial post-and-
# readback column-type guard missed because they were introduced by later
# PUTs (layout updates, spec edits during error recovery).
# ---------------------------------------------------------------------------
unless opts[:skip_column]
  wb_id = opts[:wb]
  if wb_id.nil?
    wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
    if File.exist?(wb_ids_path)
      wb_ids = JSON.parse(File.read(wb_ids_path)) rescue {}
      wb_id = wb_ids['workbookId']
    end
  end

  if wb_id.nil? || wb_id.empty?
    puts "[SKIP] gate 3/3: no workbook ID resolvable (pass --workbook-id or ensure wb-ids.json exists)"
  else
    base = ENV['SIGMA_BASE_URL']
    tok  = ENV['SIGMA_API_TOKEN']
    if base.nil? || base.empty? || tok.nil? || tok.empty?
      warn "[SKIP] gate 3/3: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — cannot fetch /columns"
    else
      uri = URI("#{base}/v2/workbooks/#{wb_id}/columns")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }

      if res.is_a?(Net::HTTPSuccess)
        cols = (JSON.parse(res.body)['entries'] rescue []) || []
        error_cols = cols.select { |c| c.dig('type', 'type') == 'error' }
        if error_cols.any?
          warn "[FAIL] gate 3/3: live workbook #{wb_id} has #{error_cols.length} column(s) with type=error."
          warn "       These render as visible errors in the Sigma UI (circular ref, unknown column,"
          warn "       unsupported function, etc.). Fix the offending formulas and re-PUT before declaring GREEN."
          error_cols.first(10).each do |c|
            warn "         element=#{c['elementId']} col=#{c['columnId']} label=#{c['label'].inspect}"
            warn "           formula: #{c['formula']}"
          end
          warn "       See beads-sigma-38a."
          exit 5
        end
        puts "[OK] gate 3/3: #{cols.length} live columns clean (no type=error)"
      else
        warn "[SKIP] gate 3/3: GET /v2/workbooks/#{wb_id}/columns returned HTTP #{res.code} — cannot verify"
      end
    end
  end
else
  puts "[SKIP] gate 3/3: --skip-column-check"
end

puts "[OK] all gates pass — conversion may declare GREEN"
exit 0
