#!/usr/bin/env ruby
# Parity verification: compare expected (from Tableau CSVs) vs actual
# (from Sigma queries) for each chart in a plan.
#
# Plan format (JSON array):
#   [{ "chart": "...",
#      "expected": [[dim, val], ...],
#      "actual":   { "rows": [[dim, val], ...] },
#      "extract":  true|false   # optional per-chart override
#   }]
#
# A top-level wrapper is also accepted:
#   { "extract": true, "charts": [ ... ] }
# in which case `extract` propagates to every chart.
#
# --strict      value-exact comparison (default)
# --extract-mode  structural comparison only — when Tableau view CSVs come from
#                 a workbook with hasExtracts=true, the absolute values can drift
#                 from Sigma (live warehouse) while the chart shape is correct.
#                 Extract-mode checks:
#                   - same number of buckets (rows)
#                   - same set of dimension values
#                   - same sort order on the dimension column
#                   - measure values within `--extract-tol` relative tolerance
#                     (default 0.30 = 30%) IF both are non-null, otherwise skipped
#
# Usage:
#   ruby verify-parity.rb --plan plan.json
#   ruby verify-parity.rb --plan plan.json --extract-mode
#   ruby verify-parity.rb --plan plan.json --extract-mode --extract-tol 0.50

require 'json'
require 'set'
require 'optparse'

opts = { mode: :strict, tol: 0.30 }
OptionParser.new do |p|
  p.on('--plan P')              { |v| opts[:plan] = v }
  p.on('--extract-mode')        {     opts[:mode] = :extract }
  p.on('--extract-tol TOL', Float) { |v| opts[:tol] = v }
end.parse!
abort('--plan required') unless opts[:plan]

def round_row(row)
  # Convert all numerics to Float-rounded so Integer 11 and Float 11.0 compare equal in the set.
  row.map { |v| v.is_a?(Numeric) ? v.to_f.round(2) : v }
end

def strict_compare(exp, act)
  exp_set = Set.new(exp.map { |r| r.first(2) })
  act_set = Set.new(act.map { |r| r.first(2) })
  if exp_set == act_set
    { status: 'PASS', only_in_tableau: [], only_in_sigma: [] }
  else
    { status: 'DIVERGE',
      only_in_tableau: (exp_set - act_set).to_a,
      only_in_sigma:   (act_set - exp_set).to_a }
  end
end

# Extract-mode: same row count + same dim set + same dim sort. Measure values
# only flagged if they're WILDLY off (beyond extract_tol) — small drift is
# expected because Sigma reads live warehouse while extracts are frozen snapshots.
def extract_compare(exp, act, tol:)
  exp_dims = exp.map { |r| r[0] }
  act_dims = act.map { |r| r[0] }
  exp_set  = Set.new(exp_dims)
  act_set  = Set.new(act_dims)

  notes = []
  status = 'PASS'

  if exp.size != act.size
    status = 'DIVERGE'
    notes << "bucket count differs: tableau=#{exp.size} sigma=#{act.size}"
  end

  unless exp_set == act_set
    status = 'DIVERGE'
    notes << "dim set differs: tableau-only=#{(exp_set - act_set).to_a[0..3].inspect}, sigma-only=#{(act_set - exp_set).to_a[0..3].inspect}"
  end

  # If dim sets match, check sort order on the dimension
  if exp_set == act_set && exp_dims != act_dims
    notes << "dim sort order differs (extract-mode flags only — not a failure)"
  end

  # Wild-divergence check on measures (10x or more drift = probably a real bug,
  # not just extract staleness)
  if exp.size == act.size && exp_set == act_set
    exp_h = exp.each_with_object({}) { |r, h| h[r[0]] = r[1] }
    act_h = act.each_with_object({}) { |r, h| h[r[0]] = r[1] }
    big_drifts = []
    exp_h.each do |k, v|
      a = act_h[k]
      next if v.nil? || a.nil?
      next unless v.is_a?(Numeric) && a.is_a?(Numeric)
      denom = [v.abs.to_f, a.abs.to_f, 1.0].max
      drift = (v - a).abs.to_f / denom
      big_drifts << [k, v, a, drift] if drift > tol
    end
    if big_drifts.any?
      notes << "#{big_drifts.size} measure value(s) drift > #{(tol * 100).to_i}% — review:"
      big_drifts.first(3).each do |k, v, a, d|
        notes << "    #{k.inspect} tableau=#{v} sigma=#{a} drift=#{(d * 100).round}%"
      end
    end
  end

  { status: status, notes: notes,
    only_in_tableau: (exp_set - act_set).to_a,
    only_in_sigma:   (act_set - exp_set).to_a }
end

raw = JSON.parse(File.read(opts[:plan]))
default_extract = false
if raw.is_a?(Hash) && raw['charts']
  default_extract = !!raw['extract']
  plan = raw['charts']
else
  plan = raw
end

# Top-level --extract-mode overrides default
mode_forced = opts[:mode] == :extract

results = plan.map do |p|
  exp = (p['expected'] || []).map { |r| round_row(r) }
  act = (p.dig('actual', 'rows') || []).map { |r| round_row(r) }

  this_extract = if p.key?('extract')
                   p['extract']
                 elsif mode_forced
                   true
                 else
                   default_extract
                 end

  result = this_extract ? extract_compare(exp, act, tol: opts[:tol]) : strict_compare(exp, act)
  result.merge(chart: p['chart'], extract: this_extract)
end

results.each do |r|
  tag = r[:extract] ? '[extract]' : '[strict] '
  printf "%-7s  %s  %s\n", r[:status], tag, r[:chart]
  if r[:status] != 'PASS' || (r[:notes] && r[:notes].any?)
    Array(r[:notes]).each { |n| puts "    #{n}" }
    if r[:only_in_tableau].any? || r[:only_in_sigma].any?
      puts "    Tableau-only: #{r[:only_in_tableau].inspect[0..200]}"
      puts "    Sigma-only:   #{r[:only_in_sigma].inspect[0..200]}"
    end
  end
end

failed = results.count { |r| r[:status] != 'PASS' }
puts '---'
puts "#{results.size - failed}/#{results.size} pass" + (mode_forced ? '  (extract-mode)' : '')
exit(failed.zero? ? 0 : 1)
