# gap-scout subagent

A focused subagent the main tableau-to-sigma agent spawns when `scan-workbook-gaps.rb`
flags an **❌ Unhandled** or **⚠️ Hint** feature in the customer's workbook.

The scout takes ONE gap at a time, attempts a translation, validates it against
Sigma's API, and either:
1. ✅ Writes the working rule to `~/.tableau-to-sigma/learned-rules.yaml`
   so future conversions on the same site pick it up automatically
2. ❌ Files a structured issue at github.com/twells89/sigma-skills-staging
   with the XML snippet + failed attempts so the maintainer sees the pattern

## When to spawn this subagent

The main agent should spawn it when the gap report shows any `:unhandled` row
OR when an `:hint` row has count >5 (high enough to be worth automating). The
main agent does NOT do this discovery itself — the scout runs in isolation with
its own context budget so the main conversion isn't disturbed.

## Inputs (passed in the prompt)

- `gap`: a single object from `<workbook>-gaps.json`'s `detected_features` list
- `twb_path`: path to the customer's `.twb` (for extracting example formulas)
- `sigma_dm_id`: an existing Sigma data-model id with master columns the scout
  can use for validation POSTs
- `sigma_master_element_id`: typically `master`
- `budget`: max number of Sigma POSTs (default: 3 per attempt, 3 attempts = 9)

## Procedure

1. **Find concrete examples in the .twb**
   Use `grep` / REXML to pull 3-5 example XML snippets matching the gap's pattern.
   Excerpt: formula text, surrounding column metadata, datatype.

2. **Propose a Sigma translation**
   Use the existing skill knowledge (refs/data-model-spec.md +
   refs/workbook-layout.md + scripts/lib/sigma_functions.rb's whitelist) to
   propose 1-3 candidate Sigma formulas. Prefer translations that use ONLY
   functions in `SigmaFunctions::ALL` — anything outside that list silently
   errors in Sigma.

3. **Build a minimal test workbook**
   Construct a workbook spec with:
   - The existing master element (via `sigma_dm_id` + `sigma_master_element_id`)
   - One chart that uses the candidate translation as a column formula
   - Any required control / filter
   POST to `/v2/workbooks/spec` and read back `/v2/workbooks/{id}/elements/{el}/columns`.

4. **Validate via column-type guard**
   - If every column's `type.type != "error"` → SUCCESS, capture the rule
   - If any column errors → record the error, try the next candidate, repeat
     up to `budget` times

5. **On SUCCESS**
   Append the rule to `~/.tableau-to-sigma/learned-rules.yaml`:
   ```yaml
   - feature: "Tableau WINDOW_AVG"
     tableau_pattern: '\bWINDOW_AVG\s*\(SUM\s*\(\[([^\]]+)\]\)\s*\)'
     sigma_formula:   'MovingAvg(Sum([Master/$1]), -10, 10)'
     hint:            'Sigma window functions silently error in grouping-table charts'
     validated_at:    '2026-05-19T16:42:00Z'
     example_xml:     '<formula>WINDOW_AVG(SUM([Sales]))</formula>'
     example_from:    'workbook.twb (line 1234)'
   ```
   Future runs of the main agent should load this file at start and apply rules
   before falling back to WARN-only behavior.

6. **On FAILURE**
   Write a structured escalation:
   ```yaml
   gap: <name>
   tableau_snippet: <XML fragment>
   attempts:
     - sigma_formula: <candidate 1>
       error: <error from Sigma API>
     - sigma_formula: <candidate 2>
       error: ...
   ```
   Save to `~/.tableau-to-sigma/escalations/<timestamp>-<gap-slug>.yaml`.
   ALSO: invoke `gh issue create` (if `gh` available) OR `bd create` (if
   .beads-sigma present) to file the issue automatically. Issue body includes
   the snippet, attempts, and a one-line headline like
   "Tableau→Sigma: figure out translation for WINDOW_AVG(SUM(x))".

## Output

Return to the main agent:
- `status`: "auto-now-handled" | "needs-manual-followup" | "escalated-to-issue"
- `rule_path`: path to the learned-rules.yaml entry (if success)
- `escalation_path`: path to the escalation file (if failure)
- `attempts`: count
- `sigma_workbook_ids`: list of test workbook IDs to clean up later

## Why a separate subagent

- **Context isolation**: the scout makes many POST attempts; each round-trip
  could be 200-500 tokens of Sigma error output. Keeping that out of the main
  conversion's context window is critical for long migrations.
- **Bounded budget**: cap N attempts to prevent runaway costs. Main agent
  isn't blocked on the scout — can continue other work in parallel.
- **Reusable across workbooks**: when the scout figures out a rule, every
  future customer running the skill picks it up via learned-rules.yaml.

## Status

Phase 1: scan-workbook-gaps.rb (DONE — shipped 2026-05-19)
Phase 2: gap-scout subagent definition (THIS FILE — DONE, prototype)
Phase 3: actual subagent invocation wiring + learned-rules.yaml loader (TODO,
  tracked in beads-sigma-<id-tbd>)
Phase 4: github issue auto-filing on escalation (TODO)
