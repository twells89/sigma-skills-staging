#!/usr/bin/env ruby
# Hard gate that proves Phase 6 (parity verification) actually ran for this
# conversion. The subagent MUST run this script before declaring GREEN —
# without it, an agent can silently skip phase6-parity.rb and self-report
# `charts_pass: 0, charts_total: 0` to slip past the brief's GREEN tier rule
# (which only checked equality, not non-zero count).
#
# See beads-sigma-4pm — Phase 6 silently skipped in subagent runs.
#
# Usage:
#   ruby scripts/assert-phase6-ran.rb --tableau /tmp/<name> \
#     [--min-pass-rate 1.0]    # default 1.0 (every chart must PASS)
#     [--allow-extract]        # treat extract-mode as acceptable (no strict)
#
# Exit codes:
#   0  Phase 6 ran AND all parity checks passed at the required rate
#   1  parity-final.json missing (Phase 6 was skipped — the regression case)
#   2  parity-final.json exists but `status` is FAIL or pass-rate below min
#   3  parity-final.json malformed
#
# Prints a one-line summary to stdout regardless of exit code.

require 'json'
require 'optparse'

opts = { min_pass_rate: 1.0, allow_extract: false }
OptionParser.new do |p|
  p.on('--tableau DIR')          { |v| opts[:tab] = v }
  p.on('--min-pass-rate F', Float) { |v| opts[:min_pass_rate] = v }
  p.on('--allow-extract')        { opts[:allow_extract] = true }
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

puts "[OK] Phase 6 ran cleanly — #{passed}/#{total} charts PASS (mode=#{mode}, status=#{status})"
exit 0
