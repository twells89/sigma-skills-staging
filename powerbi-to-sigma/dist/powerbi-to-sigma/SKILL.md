---
name: powerbi-to-sigma
description: Convert a Power BI report + semantic model into a Sigma data model and matching dashboard. Use when the user has a Power BI report (in Power BI Service / Fabric, or a .pbix/.pbit file) and wants to recreate it in Sigma. Covers connecting to Power BI with no Entra app, extracting the model (TMSL) + report layout (PBIR/Report-Layout), converting via the sigma-data-model MCP, posting the data model + workbook via REST, and parity verification. Can also author dashboards back INTO Power BI via the Fabric write API.
---

# Power BI → Sigma

> Status: **foundation** (validated end-to-end 2026-05-31 on the "Employee Dashboard" workforce report).
> Beads: build = `beads-sigma-cs2`; converter gaps = `j89` (M-Snowflake path), `tkd` (element names / schemaVersion / folderId).
> Defers to: `sigma-workbooks` (canonical workbook spec), `sigma-data-models` (DM spec), the `convert_powerbi_to_sigma` MCP tool, and `tableau-to-sigma/scripts/*` (reused verbatim for posting + layout + parity).

## What's proven (the happy path, validated once)
```
1. CONNECT   device-code login, well-known PowerBI-Desktop client, NO Entra app   → scripts/fabric-extract.py
2. EXTRACT   Fabric getDefinition?format=TMSL → model.bim   (+ .pbix Report/Layout for visuals)
3. CONVERT   convert_powerbi_to_sigma MCP (model.bim + connectionId + db/schema) → Sigma DM JSON
4. POST DM   fix spec (schemaVersion + folderId/ownerId + element names) → POST /v2/dataModels/spec
5. WORKBOOK  Data page (master tables per DM element) + chart elements → POST /v2/workbooks/spec
6. LAYOUT    PBIX/PBIR visual x,y,w,h → 24-col grid XML → put-layout.rb
7. VERIFY    sigma-mcp-v2 query each element returns real rows; Phase 6 = compare vs PBI executeQueries (DAX)
```

## Phase 1 — Connect (no Entra app required)
The corporate tenant blocks Entra app creation, Git integration, and XMLA (PPU). The working path:
- `scripts/fabric-extract.py` — device-code via well-known public client **`ea0616ba-638b-4df5-95b9-636659ae5121`** (Power BI Desktop), scope `https://api.fabric.microsoft.com/.default`. User signs in once at the device URL; token cached.
- **`truststore.inject_into_ssl()` is mandatory** (first line) — corp TLS inspection on `api.fabric.microsoft.com`; uses macOS keychain CA.
- See `refs/connection.md` for the full recipe + surprises (works on My-workspace, device-code not CA-blocked).

## Phase 2 — Extract
- **Model**: `getDefinition?format=TMSL` (202 LRO → poll `Location`) → base64 `model.bim` part = the TMSL/TOM JSON the MCP eats. Works even on My-workspace.
- **Layout**: a `.pbix` is a zip; `Report/Layout` is **UTF-16LE** JSON with per-visual `x,y,w,h` (canvas px, 1280×720 default). The model in a `.pbix` is a *binary* `DataModel` blob — NOT usable; get the model via getDefinition or a `.pbit`'s `DataModelSchema`.
- See `refs/vendored/powerbi-visual-layout.md` for the Report/Layout & PBIR parsers and the visualType→Sigma-kind table.

## Phase 3 — Convert (MCP)
`convert_powerbi_to_sigma(model_json, connection_id, database, schema)`.
- DAX measures → Sigma metrics. ~70% mechanical; see `refs/vendored/dax-to-sigma-coverage.md` and `fixtures/MANIFEST.md` (test oracle: 94 DAX expressions bucketed a/b/c).
- **Known gap `j89`**: the Snowflake `Snowflake.Databases(...) + Navigation` M pattern isn't parsed → pass `database`/`schema` explicitly until fixed.

## Phase 3.5 — Reuse an existing DM? (avoid sprawl — mirrors tableau Phase 1.5)
Before posting a NEW data model, check whether an existing Sigma DM already
covers the same warehouse tables (don't add a 4th near-identical "Orders" DM):
```
python3 scripts/pbi-dm-signature.py --bim /tmp/pbix/model.bim --out $WORK/dm-signature.json
ruby scripts/find-or-pick-dm.rb --workbook-signature $WORK/dm-signature.json \
  --out $WORK/dm-match.json --auto-pick     # exit 0 = candidate ≥ min-score
```
`pbi-dm-signature.py` derives `{warehouse_tables (DB.SCHEMA.TABLE from the M
nav), referenced_columns, measures}` from the model.bim. If a candidate scores
high AND there's no tie, `--auto-pick` recommends reuse (sets `auto_picked:true`
— WARN about inherited columns/RLS/metrics); on a tie it falls back to ASK. To
reuse: skip Phase 4, point the workbook masters at the matched `recommended_dm_id`
+ its element ids (describe it), and continue at Phase 5. Otherwise post new.

## Phase 4 — Post the data model
The converter output (`sigmaDataModel`) needs 3 fixups before `POST /v2/dataModels/spec` (gap `tkd`):
1. **`schemaVersion: 1`** at top level (else `schemaVersion: Invalid 1: undefined`).
2. **`folderId` + `ownerId`** at top level — pull from a reference DM (the **tableau-to-sigma reuse logic**, `find-or-pick-dm.rb`).
3. **Element `name`** on each base warehouse-table element (= `source.path[-1]`) — the converter only names joined View elements, but workbook masters reference DM elements by name.
Then: `tableau-to-sigma/scripts/post-and-readback.rb --type datamodel`. See `refs/spec-fixups.md`.

## Phase 5 — Build the workbook
- **Data page**: one hidden `table` master per DM element used (`source: {kind:data-model, dataModelId, elementId}`, columns `[ElementName/Col]`).
- **Chart elements** source from a master (`source:{kind:table, elementId:<master>}`), columns `[dim, meas]`:
  - bar/line: `xAxis:{columnId}`, `yAxis:{columnIds:[...]}`
  - pie/donut: `color:{id}`, `value:{id}`
  - text: `{kind:text, body:"## ..."}`
  - measure formula wraps the master col: `CountDistinct([Master/Col])`, `Sum([Master/Col])`, date dim `DateTrunc("month",[Master/Col])`.
- `POST /v2/workbooks/spec` (post-and-readback `--type workbook`). Chart-element shapes mirror `tableau-to-sigma/scripts/build-charts-from-signals.rb`.

## Phase 5d — Layout (do NOT skip — stacked ≠ done)
Map each visual's `x,y,w,h` → 24-col grid (`COL_UNIT = page_w/24`, `ROW_UNIT ≈ 30`) → single top-level `layout` XML (one `<Page>` per page, server page IDs) → `tableau-to-sigma/scripts/put-layout.rb`. Math + snap rules in `refs/vendored/powerbi-visual-layout.md §4`.

## Phase 6 — Verify (mandatory)
- `sigma-mcp-v2 query` each element → confirm real rows (not blank).
- True parity: PBI `POST /v1.0/myorg/groups/{ws}/datasets/{id}/executeQueries` (DAX) vs the same Sigma aggregation. DAX-only; breaks under service-principal if RLS.

## Reverse direction — author INTO Power BI
The Fabric API is symmetric: `POST .../semanticModels` (TMSL parts) + `POST .../reports` (PBIR) create live items. Same device-code token (`user_impersonation` covers writes). Needs a Fabric-capacity workspace. See `scripts/fabric-auth-check.py` for the write-capability/capacity check.

## Scripts — the conversion pipeline
The conversion is script-driven (mirrors `tableau-to-sigma/scripts/`). `scripts/run.sh` orchestrates connect → extract → convert → post-DM → build-workbook → layout → parity; it runs every deterministic stage and STOPS at the two MCP gates (the `convert_powerbi_to_sigma` conversion and the `sigma-mcp-v2` actuals collection) with a clear instruction, then resume any stage with `--from <stage>`. All scripts are idempotent and re-run-safe.

| Script | Stage | What it does |
|---|---|---|
| `extract-pbir.py` | 1 extract | Fetch a report's PBIR (or parse one already on disk) → normalized `signals.json` (per-visual `sigma_kind` + role bindings + x/y/w/h). The PBI analog of `parse-twb-layout.rb`. |
| `convert-model.rb` | 2–3 convert/post | MODE A prints the exact `convert_powerbi_to_sigma` MCP call for a `model.bim`; MODE B takes the converter output and applies the 3 fixups (schemaVersion + folderId/ownerId via a ref-DM harvest + base-element names) → postable DM spec. |
| `build-workbook-from-pbir.rb` | 4 build | `signals.json` + a `master-map.json` → full workbook spec + 24-col layout XML. Applies the measure-translation patterns in `refs/measure-patterns.md`; **line charts default to a single series** (`beads-sigma-c07`) unless PBI bound a Series/Legend role. Analog of `build-charts-from-signals.rb`. |
| `phase6-parity-pbi.rb` | 7 parity | executeQueries(DAX) adapter: `--emit-dax` runs the PBI side and writes the parity plan's `expected` rows; `--finalize` injects Sigma actuals and runs the shared `verify-parity.rb`. The PBI analog of Tableau's view-CSV parity adapter. |

The agent authors one PBI-specific artifact: `master-map.json` (maps each PBI Entity → a Data-page master element and each `Entity.Field` queryRef → `{ref, agg}`), which encodes the DM element ids + DAX-measure→Sigma-aggregator decisions. Everything else is mechanical.

**Validated unattended end-to-end 2026-05-31** against the KitchenSink (PBI report `0bebf272` / model `049863fa`, CSA.TJ): `run.sh` drove extract → convert (MCP gate) → post-DM (26 cols, 0 errors) → build → post-WB → **layout** into a throwaway DM + workbook in `tj-wells-1989`. `assert-phase6-ran.rb` passed all 4 gates: **0 `error` columns** (34 live cols), grouped `Department Summary` table (6 depts, real ranked rows), **single-series** YTD line (2025 Jul–Dec = `3536,7412,10932,14700,18080,21844`, parity-exact vs PBI), pivot with `rowsBy`/`values`, and a 12-element grid layout that **survived the final write** (no single-column wipe). Throwaway items deleted after.

> **Phase 5 time-intelligence tradeoff (`beads-sigma-c07`):** the builder emits PBI line charts as a **single series** (`xAxis`=month, `yAxis`=`CumulativeSum(Sum(...))`, **no `color` block**). A continuous `CumulativeSum` reproduces a within-year YTD exactly (2025 matched PBI to the unit) but does NOT reset at the Jan year boundary. For a true `TOTALYTD` per-year-reset on one line, precompute a year-partitioned YTD in a hidden grouped level table and plot it with `Max()` (recipe in `refs/measure-patterns.md §4`). Never reproduce the reset by adding `color:{by:category,column:year}` — that renders TWO lines, diverging from PBI's one.

## Reuse, don't reinvent (and packaging)
These vendor-agnostic Sigma-side scripts are reused: `get-token.sh`, `lib/sigma_rest.rb`, `post-and-readback.rb`, `put-layout.rb`, `find-or-pick-dm.rb`, `validate-spec.rb`, `verify-parity.rb`, `cleanup-orphan-workbooks.rb`. In the repo they are **symlinks** into `tableau-to-sigma/scripts/` (DRY), but symlinks break when the skill is downloaded standalone — so always ship via **`./package.sh`**, which dereferences every symlink into a real file and vendors the out-of-tree reference docs into `refs/vendored/`. The result (`dist/powerbi-to-sigma/`) is fully self-contained: 0 symlinks, the whole pipeline runs from inside the bundle. The shared core is being extracted to `sigma-conversion-core` (`beads-sigma-6k9`); until then, package before distributing.
