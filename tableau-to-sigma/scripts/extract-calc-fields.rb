#!/usr/bin/env ruby
# Read a Tableau get-datasource-metadata JSON dump, extract every CALCULATION
# field (with formula), and emit a translation-ready record per calc.
#
# This script doesn't translate the formulas itself — the Tableau→Sigma
# translation is partly judgment (operator equivalents, null-handling Coalesce
# wraps, LOD vs window functions). The output gives the agent everything
# needed to do that translation: original formula, defaultAggregation, the
# field's role/dataCategory, and a literal note about the common null-fallthrough
# trap.
#
# Usage:
#   ruby extract-calc-fields.rb <datasource-metadata.json> <out.json>
#
# In production, this script would also CALL the Tableau MCP / REST API
# (get-datasource-metadata) itself, given a datasourceLuid.

require 'json'

INP = ARGV[0] || abort('usage: extract-calc-fields.rb <metadata.json> <out.json>')
OUT = ARGV[1] || abort('usage: extract-calc-fields.rb <metadata.json> <out.json>')

# Tableau table calculations and view-level expressions that Sigma CANNOT
# represent as a DM calc column or workbook master calc column. These all need
# a Sigma Custom SQL element (kind: "sql") on the data model, with the window
# operation rewritten as ANSI SQL OVER(...).
#
# Detected patterns (case-insensitive, function name + opening paren):
TABLEAU_WINDOW_FNS = %w[
  WINDOW_SUM WINDOW_AVG WINDOW_MEDIAN WINDOW_MIN WINDOW_MAX
  WINDOW_COUNT WINDOW_VAR WINDOW_VARP WINDOW_STDEV WINDOW_STDEVP
  WINDOW_PERCENTILE WINDOW_CORR WINDOW_COVAR WINDOW_COVARP
  RUNNING_SUM RUNNING_AVG RUNNING_COUNT RUNNING_MIN RUNNING_MAX
  RANK RANK_DENSE RANK_MODIFIED RANK_PERCENTILE RANK_UNIQUE
  INDEX FIRST LAST SIZE TOTAL
  LOOKUP PREVIOUS_VALUE
].freeze

# Translation hints from Tableau function → Sigma Custom SQL.
TABLEAU_WINDOW_TO_SQL = {
  /\bWINDOW_SUM\b/i      => 'SUM(<expr>) OVER (<partition / order>)',
  /\bWINDOW_AVG\b/i      => 'AVG(<expr>) OVER (<partition / order>)',
  /\bWINDOW_MIN\b/i      => 'MIN(<expr>) OVER (...)',
  /\bWINDOW_MAX\b/i      => 'MAX(<expr>) OVER (...)',
  /\bWINDOW_COUNT\b/i    => 'COUNT(<expr>) OVER (...)',
  /\bWINDOW_MEDIAN\b/i   => 'PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY <expr>) OVER (...)',
  /\bWINDOW_PERCENTILE\b/i => 'PERCENTILE_CONT(<p>) WITHIN GROUP (ORDER BY <expr>) OVER (...)',
  /\bRUNNING_SUM\b/i     => 'SUM(<expr>) OVER (ORDER BY <time> ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)',
  /\bRUNNING_AVG\b/i     => 'AVG(<expr>) OVER (ORDER BY <time> ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)',
  /\bRUNNING_COUNT\b/i   => 'COUNT(<expr>) OVER (ORDER BY <time> ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)',
  /\bRUNNING_MIN\b/i     => 'MIN(<expr>) OVER (ORDER BY <time> ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)',
  /\bRUNNING_MAX\b/i     => 'MAX(<expr>) OVER (ORDER BY <time> ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)',
  /\bRANK_DENSE\b/i      => 'DENSE_RANK() OVER (PARTITION BY <p> ORDER BY <expr> DESC)',
  /\bRANK_MODIFIED\b/i   => 'RANK() OVER (PARTITION BY <p> ORDER BY <expr> DESC) — Tableau\'s "modified" tie-handling',
  /\bRANK_UNIQUE\b/i     => 'ROW_NUMBER() OVER (PARTITION BY <p> ORDER BY <expr> DESC)',
  /\bRANK_PERCENTILE\b/i => 'PERCENT_RANK() OVER (PARTITION BY <p> ORDER BY <expr>)',
  /\bRANK\b/i            => 'RANK() OVER (PARTITION BY <p> ORDER BY <expr> DESC)',
  /\bINDEX\(\s*\)/i      => 'ROW_NUMBER() OVER (PARTITION BY <p> ORDER BY <expr>)',
  /\bFIRST\(\s*\)/i      => 'INDEX - 1 (negative offset from first row); inline as ROW_NUMBER() OVER (...) - 1',
  /\bLAST\(\s*\)/i       => 'COUNT(*) OVER (...) - ROW_NUMBER() OVER (...) (offset to last row)',
  /\bSIZE\(\s*\)/i       => 'COUNT(*) OVER (PARTITION BY <p>)',
  /\bTOTAL\b/i           => 'SUM(<expr>) OVER (PARTITION BY <p>) — Tableau TOTAL is a window sum across the partition',
  /\bLOOKUP\s*\(/i       => 'LAG(<expr>, <offset>) OVER (ORDER BY <time>) — or LEAD for positive offsets',
  /\bPREVIOUS_VALUE\s*\(/i => 'LAG(<expr>) OVER (ORDER BY <time>) — Tableau previous-row reference'
}.freeze

def detect_window_fns(formula)
  hits = []
  TABLEAU_WINDOW_FNS.each do |fn|
    if formula =~ /\b#{Regexp.escape(fn)}\s*\(/i
      hits << fn
    end
  end
  hits.uniq
end

def sql_hints_for(formula)
  hints = []
  TABLEAU_WINDOW_TO_SQL.each do |re, sql|
    hints << "  #{re.source.gsub(/\\b|\\\(/, '').strip} → #{sql}" if formula =~ re
  end
  hints
end

# Heuristics for the most common Tableau→Sigma formula gotchas. These do NOT
# attempt full translation — they flag what the agent should handle by hand.
def gotchas(formula)
  notes = []
  notes << 'IF/ELSEIF chain ending in literal — wrap nullable inputs in Coalesce to match Tableau ELSE-catches-null semantics' if formula =~ /\bIF\b[\s\S]+\bELSE\b/i
  notes << 'IIF(c, t, e) → If(c, t, e) in Sigma' if formula =~ /\bIIF\s*\(/i
  notes << 'COUNTD → CountDistinct in Sigma' if formula =~ /\bCOUNTD\b/i
  notes << 'Tableau IF NULL falls through to ELSE; Sigma If returns Null — wrap nullable source with Coalesce' if formula =~ /\bIF\b[\s\S]+>=|<=|=|<|>/i

  # Window function detection — these REQUIRE a Sigma Custom SQL element.
  window_hits = detect_window_fns(formula)
  if window_hits.any?
    notes << "REQUIRES SIGMA CUSTOM SQL ELEMENT (kind: \"sql\"). Tableau window functions detected: #{window_hits.join(', ')}. Sigma CountOver/SumOver/RankOver/etc. SILENTLY ERROR in DM calc columns and grouping-table master calcs — never use them as a calc column. Translate as ANSI SQL OVER(...) inside a Custom SQL element on the data model."
    sql_hints = sql_hints_for(formula)
    notes.concat(sql_hints.map { |h| "  SQL hint: #{h}" }) if sql_hints.any?
  end

  # LOD expressions — Tableau view-level aggregates. Need Custom SQL when the LOD
  # grain doesn't match the master element's grain (which is almost always the case
  # for FIXED). INCLUDE/EXCLUDE coarsen/refine the view's grain and require
  # rewriting too.
  if formula =~ /\{\s*FIXED\b/i
    notes << 'REQUIRES SIGMA CUSTOM SQL ELEMENT. Tableau {FIXED <dim> : <agg>} pre-aggregates at a fixed grain. Translate as SQL with a window: <agg>(<expr>) OVER (PARTITION BY <dim>) — or as a pre-aggregated subquery joined back. Do NOT use a Sigma Lookup; Lookup is row-level, not aggregate.'
  end
  if formula =~ /\{\s*INCLUDE\b/i
    notes << 'REQUIRES SIGMA CUSTOM SQL ELEMENT. Tableau {INCLUDE <dim> : <agg>} computes at a finer grain than the view, then aggregates. Translate as SQL pre-aggregated subquery at the include-grain joined back to the view-grain.'
  end
  if formula =~ /\{\s*EXCLUDE\b/i
    notes << 'REQUIRES SIGMA CUSTOM SQL ELEMENT. Tableau {EXCLUDE <dim> : <agg>} computes at a coarser grain. Translate as SQL <agg>(<expr>) OVER (PARTITION BY <view-dims-minus-excluded>).'
  end

  notes
end

meta = JSON.parse(File.read(INP))

calcs = []

# Two input shapes:
#   1. MCP get-datasource-metadata → { fieldGroups: [{logicalTableId, fields:[...]}], ... }
#   2. REST VDS read-metadata      → { data: [{...field..., logicalTableId?:...}], ... }
# Detect which and normalize.
if meta['fieldGroups']
  (meta['fieldGroups'] || []).each do |grp|
    table_id = grp['logicalTableId']
    (grp['fields'] || []).each do |f|
      next unless f['columnClass'] == 'CALCULATION'
      formula = f['formula'].to_s
      notes = gotchas(formula)
      calcs << {
        name:       f['name'] || f['fieldCaption'],
        logical_table: table_id,
        data_type:  f['dataType'],
        role:       f['role'] || f['fieldRole'],
        data_category: f['dataCategory'],
        default_agg: f['defaultAggregation'],
        formula:    formula,
        requires_custom_sql: detect_window_fns(formula).any? || formula =~ /\{\s*(FIXED|INCLUDE|EXCLUDE)\b/i ? true : false,
        translation_notes: notes
      }
    end
  end
elsif meta['data']
  (meta['data'] || []).each do |f|
    next unless f['columnClass'] == 'CALCULATION'
    formula = f['formula'].to_s
    calcs << {
      name:       f['fieldCaption'] || f['fieldName'],
      logical_table: f['logicalTableId'], # nil = workbook-level calc, not tied to a table
      data_type:  f['dataType'],
      role:       f['fieldRole'],
      data_category: f['dataCategory'],
      default_agg: f['defaultAggregation'],
      formula:    formula,
      requires_custom_sql: detect_window_fns(formula).any? || formula =~ /\{\s*(FIXED|INCLUDE|EXCLUDE)\b/i ? true : false,
      translation_notes: gotchas(formula)
    }
  end
else
  abort "unrecognized metadata shape — expected 'fieldGroups' (MCP) or 'data' (VDS REST)"
end

File.write(OUT, JSON.pretty_generate(calcs))
sql_count = calcs.count { |c| c[:requires_custom_sql] }
puts "wrote #{OUT}  (#{calcs.size} calculated fields, #{sql_count} REQUIRE Custom SQL element)"
calcs.each do |c|
  prefix = c[:requires_custom_sql] ? '⚠ SQL  ' : '       '
  puts "  #{prefix}#{c[:name]}#{c[:logical_table] ? " (#{c[:logical_table][0..30]}…)" : ' (workbook-level)'}: #{c[:formula][0..80]}#{'…' if c[:formula].length > 80}"
end
if sql_count > 0
  puts
  puts "⚠  #{sql_count} calc field(s) require a Sigma Custom SQL element on the data model (kind: \"sql\")."
  puts "   See refs/data-model-spec.md \"Custom SQL element\" for the spec shape."
  puts "   Each flagged calc's translation_notes include SQL hints — read them per-calc."
end
