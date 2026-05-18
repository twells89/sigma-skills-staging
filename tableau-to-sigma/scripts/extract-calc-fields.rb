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

# Heuristics for the most common Tableau→Sigma formula gotchas. These do NOT
# attempt full translation — they flag what the agent should handle by hand.
def gotchas(formula)
  notes = []
  notes << 'IF/ELSEIF chain ending in literal — wrap nullable inputs in Coalesce to match Tableau ELSE-catches-null semantics' if formula =~ /\bIF\b[\s\S]+\bELSE\b/i
  notes << 'IIF(c, t, e) → If(c, t, e) in Sigma' if formula =~ /\bIIF\s*\(/i
  notes << 'LOD expression (FIXED/INCLUDE/EXCLUDE) — Sigma equivalent depends on grain; consider Lookup/window or pre-aggregation' if formula =~ /\{\s*(FIXED|INCLUDE|EXCLUDE)/i
  notes << 'COUNTD → CountDistinct in Sigma' if formula =~ /\bCOUNTD\b/i
  notes << 'Tableau IF NULL falls through to ELSE; Sigma If returns Null — wrap nullable source with Coalesce' if formula =~ /\bIF\b[\s\S]+>=|<=|=|<|>/i
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
      calcs << {
        name:       f['name'] || f['fieldCaption'],
        logical_table: table_id,
        data_type:  f['dataType'],
        role:       f['role'] || f['fieldRole'],
        data_category: f['dataCategory'],
        default_agg: f['defaultAggregation'],
        formula:    f['formula'],
        translation_notes: gotchas(f['formula'].to_s)
      }
    end
  end
elsif meta['data']
  (meta['data'] || []).each do |f|
    next unless f['columnClass'] == 'CALCULATION'
    calcs << {
      name:       f['fieldCaption'] || f['fieldName'],
      logical_table: f['logicalTableId'], # nil = workbook-level calc, not tied to a table
      data_type:  f['dataType'],
      role:       f['fieldRole'],
      data_category: f['dataCategory'],
      default_agg: f['defaultAggregation'],
      formula:    f['formula'],
      translation_notes: gotchas(f['formula'].to_s)
    }
  end
else
  abort "unrecognized metadata shape — expected 'fieldGroups' (MCP) or 'data' (VDS REST)"
end

File.write(OUT, JSON.pretty_generate(calcs))
puts "wrote #{OUT}  (#{calcs.size} calculated fields)"
calcs.each do |c|
  puts "  #{c[:name]}#{c[:logical_table] ? " (#{c[:logical_table][0..30]}…)" : ' (workbook-level)'}: #{c[:formula][0..80]}#{'…' if c[:formula].length > 80}"
end
