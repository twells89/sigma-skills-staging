# Spotfire → Sigma — converter design notes

Design sketch for a future `spotfire-to-sigma` skill, parallel to the existing
`tableau-to-sigma` converter. Not yet built. Captures the translation
surface, the **central engineering risk** (DXP binary payload), MVP scope,
and what would be reusable.

> Status: research / design only. No code yet. Last touched 2026-05-28.

---

## Headline finding

**Spotfire's `.dxp` analysis file is mostly an undocumented proprietary
binary serialization.** Visualizations, marking, calculated columns, and
page layout cannot be parsed without Spotfire Analyst. This is materially
worse than Tableau `.twb` (pure XML) and worse than Power BI `.pbix`
(closed binary, but has a documented `.pbit` XML companion).

The realistic Phase 1 input is **NOT** the DXP itself — it's:
- Spotfire's **Library REST API** for inventory
- **Information Links XML** (Spotfire's data-modeling layer) for the data model
- **Screenshots / PNG export** for visualization layout reconstruction (same pattern as the Tableau converter's PNG-read step)

Treat the DXP visualization payload as opaque until someone publishes a parser.

---

## Source formats

| Artifact | Format | Notes |
|---|---|---|
| **`.dxp` (Spotfire Analysis)** | ZIP container. Unzip yields `meta-data.xml`, `lastfileindicator`, `expectlastfileindicator`, and GUID-named blobs. | `meta-data.xml` parseable; **GUID blobs are proprietary serialized binary** holding the visualization tree, data manager, calc columns, properties. No public schema. |
| **`.sbdf` (Spotfire Binary Data Format)** | Columnar data file, **format is documented** by TIBCO. | Python reader: [`spotfire` on PyPI](https://pypi.org/project/spotfire/) (official-ish, ships `sbdf.read/write`). Embedded data only — not interesting for migration logic. |
| **Information Links** | XML, stored in Spotfire Library. The data-modeling layer (Information Designer). Defines data sources, joins, column elements, filters. | **The closest analog to a Sigma data model.** Far more useful to migrate than the DXP payload. |
| **IronPython / JS automation scripts** | Embedded in DXP, extractable via [emersonian/spotty](https://github.com/emersonian/spotty) / [spotless](https://github.com/emersonian/spotless). | **Drop** — no reasonable Sigma migration target. |

OSS DXP parsers found: **only `spotty` / `spotless`**, both extract only the
IronPython/JS scripts. **Nothing OSS extracts visualizations, marking, calc
columns, or page layout from a .dxp.**

---

## API access

[Library REST API v2](https://docs.tibco.com/pub/spotfire_server/latest/doc/api/TIB_sfire_server_REST_API_Reference/library-v2.html) at `https://<host>/spotfire/api/rest/library/v2/`:
- `GET /items` — list, filter by path / type / searchExpression
- `GET /items/{itemId}` — metadata
- `GET /items/{itemId}/contents` — downloads the `.dxp` bytes (octet-stream). Also accessible at `/spotfire/library?guid=<id>`.
- Auth: OAuth 2.0 client_credentials against `/spotfire/oauth2/token`. Scopes `api.library.read` / `.write`.
- Older SOAP `LibraryService` still exists; Cloud Spotfire exposes the same REST surface — **no major divergence on-prem vs cloud**.
- **Information Services / Information Designer** has its own SOAP API (`InformationModelService`, etc.).

Docs:
- [Library REST API v2](https://docs.tibco.com/pub/spotfire_server/latest/doc/api/TIB_sfire_server_REST_API_Reference/library-v2.html)
- [LibraryService SOAP](https://docs.tibco.com/pub/sfire_dev/area/doc/api/TIB_sfire_server_WebServices_API_Reference/com/spotfire/ws/pub/LibraryService.html)
- [Spotfire Web Services overview](https://community.spotfire.com/articles/spotfire/spotfire-web-services-api-tutorials-and-examples/)
- [Revvity: extract .dxp from Library](https://support.revvitysignals.com/hc/en-us/articles/23600188449172-How-to-extract-a-dxp-file-from-the-TIBCO-Spotfire-Library)

---

## Translation surface

| Spotfire concept | Sigma equivalent | Difficulty |
|---|---|---|
| Information Link / Data Source | DM source + tables | **easy** — XML-defined in Library, high-fidelity input |
| Data Table (in-analysis) | DM element or workbook table | medium |
| Calculated column / Custom expression | Calc column / formula | medium — Spotfire expression language ≠ Sigma; `If`, `Sum`, `Case`, date funcs map cleanly |
| Marking | Cross-element selection / action | hard — depends on visualization metadata locked in binary |
| Document / Data Property | Control / parameter | medium |
| Property Control | Control element | medium |
| Page + visuals (bar, line, scatter, cross table, KPI, map) | Page + chart/pivot/KPI elements | hard — binary payload, must rebuild from screenshots |
| Cross table | Pivot element | clean 1:1 once we have the field mapping |
| Details-on-demand | Linked detail element / drill | medium |
| Tags / Lists | No clean equivalent | drop |
| Data Function (TERR / R / Python) | **Drop or flag.** No reasonable auto-translation. | **needs a clear "drop with report" policy** |
| IronPython automation scripts | **Drop.** Extractable via spotty but no migration target. | out of scope |

### Spotfire expression language gotchas

Many functions don't have 1:1 Sigma analogs:
- `OVER` clause — Spotfire's window-function syntax (closer to MDX than SQL). Maps roughly to Sigma `*Over` functions but with very different scoping rules.
- `Intersect()` / hierarchies — Spotfire's multi-dimensional axis intersection.
- `AllPrevious()` / `AllNext()` — running-total directionals.
- Hierarchies as first-class objects — Sigma uses column-list parameters instead.

---

## Reverse-engineering difficulty

- **DXP visualization payload:** undocumented binary. Must drive Spotfire Analyst headlessly OR rely on Information Services + Library XML for what we can.
- **No OSS prior art** for full DXP → anything conversion. KNIME community thread explicitly says DXP visuals can't be opened without Spotfire.
- **Commercial migrators** (Travinto, Bizmetric, Inforiver, Jade, EPC Group, WinWire) are consultancy + tooling, not OSS. None publishes a parser.
- The **only programmatic route to visualization metadata without parsing the binary** is the [Spotfire Mods Action API](https://spotfiresoftware.github.io/spotfire-mods/api-docs/action-mods/), which runs *inside* Spotfire Analyst — not headless.

Commercial prior art (no OSS):
- [Travinto Tibco Spotfire → Power BI Dataflows](https://travinto.com/products/code-converter/tibco-spotfire-to-power-bi-dataflows)
- [Inforiver migration webinar](https://inforiver.com/webinars/migrate-power-bi-tableau-spotfire-qlik-cognos-sap/)
- [Bizmetric Spotfire → Power BI](https://marketplace.microsoft.com/en-us/marketplace/consulting-services/biz-metricpartners1621024445855.spotfire_to_powerbi_migration)

---

## MVP scope (5–8 focused weeks, ~2–3× Tableau)

Phase 0: REST inventory via Library API + per-analysis PNG export — same pattern as `tableau-assessment`. **Treat the DXP payload as opaque.**

Phase 1: **Information Links XML → Sigma DM.** Highest leverage, cleanest input. Cover sources → DM sources, joins → DM relations, column elements → columns, filters → DM filters.

Phase 2: **Calculated columns / custom expressions → Sigma formulas.** Function-map translation table. Flag `OVER` clauses for manual review.

Phase 3: **Reconstruct visualizations from PNG + metadata sidecar.** Two options for the sidecar:
1. Drive Spotfire Analyst via the [Action Mods API](https://spotfiresoftware.github.io/spotfire-mods/api-docs/action-mods/) to dump a JSON inventory (requires Spotfire to be installed somewhere).
2. Lean entirely on Information Links + screenshots + LLM reconstruction (same shape as the Tableau PNG-read step).

Phase 4: Property controls → Sigma controls.

Phase 5: Data Functions (TERR / R / Python) — emit a **block list** in the readout with manual-rework guidance. No auto-translation.

### Out of scope

- IronPython automation scripts (drop)
- Marking-based custom interactions (drop or flag)
- Custom Spotfire Mods (drop)
- TERR / R / Python data functions (drop with report)

---

## Effort estimate

**2–3× Tableau, ~5–8 focused weeks** for parity to the current Tableau converter,
primarily because:

1. **No XML for visuals** — must either drive Analyst headlessly or rely entirely on PNG reconstruction
2. **Spotfire expression language** has many functions without 1:1 Sigma analogs (`OVER`, `Intersect`, `AllPrevious`, hierarchies)
3. **TERR / Data Functions are unmigratable** — need a clear "drop with report" policy and good readout messaging
4. **Marking semantics** are tightly coupled to the visualization binary

The DXP binary is the dominant unknown. If a parser surfaces (open-source or
acquired), drop the estimate to ~3–4 weeks (closer to Tableau parity).

---

## What's reusable from `tableau-to-sigma`

- `scripts/lib/` token / auth wrapper pattern → `spotfire-to-sigma/scripts/lib/spotfire_rest.rb` (OAuth2 client_credentials flow)
- The Tableau converter's PNG-read step (`feedback_phase1d_dashboard_png`) — **directly applies** here, more critical than for Tableau since we don't have visualization XML at all
- Phase 5 workbook repointing pattern
- Cluster / DM-reuse orchestration (leader/follower)
- Assessment skill shape — would translate well to `spotfire-assessment` (Library API has equivalents to Tableau Admin Insights for usage tracking)

Not reusable:
- The .twb/.tds XML parser
- VizQL Data Service usage (Spotfire's equivalent is the Information Services SOAP API)
- Calc field auto-discovery via Metadata API (no equivalent — must parse Information Links XML)

---

## Recommendation

**Build Cognos first.** Cognos has documented XML schemas, REST API, and a
clean Data Module JSON path. Spotfire's binary DXP is a significant unknown
and warrants its own scoping work (or partnering with a customer willing to
share fixtures) before committing to the build. If a Spotfire deal is hot,
start with the assessment skill + Information Links + PNG-reconstruction path
and defer the DXP binary RE.
