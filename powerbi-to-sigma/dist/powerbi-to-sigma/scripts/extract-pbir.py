#!/usr/bin/env python3
"""extract-pbir.py — pull a Power BI report's PBIR and emit a normalized signals.json.

The PBI analog of tableau-to-sigma's parse-twb-layout.rb. Given a PBIR report
folder (already on disk from a Fabric getDefinition, e.g. /tmp/pbir) OR a live
(workspaceId, reportId) to fetch, it walks the report definition and emits one
normalized record per visual: chart kind, the field bindings per role
(x / y / color / value / rows / columns), and canvas position (x,y,w,h) plus the
page geometry. That normalized signals.json is the single input to
build-workbook-from-pbir.rb.

PBIR (Power BI Enhanced Report) on-disk shape (see research/powerbi-visual-layout.md §2c):
    <Report>.Report/definition/
      pages/pages.json                  -> pageOrder, activePageName
      pages/<pg>/page.json              -> displayName, width, height
      pages/<pg>/visuals/<id>/visual.json -> position{x,y,z,width,height}, visual.visualType, visual.query.queryState

Field bindings live under visual.query.queryState.<Role>.projections[].queryRef
(e.g. "EMPLOYEES.Total Salary"); Role is Category/Y/Values/Rows/Columns/Series/etc.

Usage:
    # from an already-extracted PBIR folder (no network):
    python3 scripts/extract-pbir.py --pbir-dir /tmp/pbir --out /tmp/pbir/signals.json

    # fetch a live report first (device-code, cached token), then extract:
    python3 scripts/extract-pbir.py --workspace <wsId> --report <reportId> \
        --pbir-dir /tmp/pbir --out /tmp/pbir/signals.json

Idempotent: re-running overwrites signals.json; a fetch only re-downloads when
--workspace/--report are given (otherwise it parses whatever is on disk).
"""
import argparse, base64, json, os, sys, time

CLIENT_ID = "ea0616ba-638b-4df5-95b9-636659ae5121"  # Power BI Desktop public client
AUTHORITY = "https://login.microsoftonline.com/organizations"
SCOPES    = ["https://api.fabric.microsoft.com/.default"]
CACHE     = "/tmp/pbiauth/cache.bin"
FAB_BASE  = "https://api.fabric.microsoft.com/v1"

# PBIR visualType -> Sigma element kind (research/powerbi-visual-layout.md §4e).
VISUAL_KIND = {
    "card": "kpi", "multiRowCard": "kpi", "kpi": "kpi", "gauge": "kpi",
    "textbox": "text", "actionButton": "text",
    "lineChart": "line", "areaChart": "area", "stackedAreaChart": "area",
    "barChart": "bar", "clusteredBarChart": "bar", "stackedBarChart": "bar",
    "columnChart": "bar", "clusteredColumnChart": "bar", "stackedColumnChart": "bar",
    "hundredPercentStackedColumnChart": "bar",
    "lineClusteredColumnComboChart": "combo", "lineStackedColumnComboChart": "combo",
    "pieChart": "pie", "donutChart": "donut", "scatterChart": "scatter",
    "tableEx": "table", "pivotTable": "pivot-table", "matrix": "pivot-table",
    "slicer": "control",
    "map": "bar", "filledMap": "bar", "shapeMap": "bar", "azureMap": "bar",
}


def _fetch_pbir(ws, report, out_dir):
    """Download a report's PBIR parts into out_dir via Fabric getDefinition."""
    import truststore; truststore.inject_into_ssl()  # corp TLS inspection — mandatory
    import requests, msal
    cache = msal.SerializableTokenCache()
    if os.path.exists(CACHE):
        cache.deserialize(open(CACHE).read())
    app = msal.PublicClientApplication(CLIENT_ID, authority=AUTHORITY, token_cache=cache)
    tok = None
    for a in app.get_accounts():
        r = app.acquire_token_silent(SCOPES, account=a)
        if r and "access_token" in r:
            tok = r["access_token"]; break
    if not tok:
        flow = app.initiate_device_flow(scopes=SCOPES)
        print(f">>> Go to {flow['verification_uri']} and enter code {flow['user_code']}", file=sys.stderr)
        tok = app.acquire_token_by_device_flow(flow).get("access_token")
    if cache.has_state_changed:
        open(CACHE, "w").write(cache.serialize())
    if not tok:
        sys.exit("AUTH FAIL — no token")
    h = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
    url = f"{FAB_BASE}/workspaces/{ws}/reports/{report}/getDefinition"
    r = requests.post(url, headers=h)
    if r.status_code == 202:  # long-running op
        loc = r.headers["Location"]; ra = int(r.headers.get("Retry-After", "3"))
        for _ in range(60):
            time.sleep(ra)
            sr = requests.get(loc, headers=h); st = sr.json().get("status")
            if st == "Succeeded":
                r = requests.get(loc + "/result", headers=h); break
            if st in ("Failed", "Undetermined"):
                sys.exit(f"LRO failed: {sr.text[:400]}")
        else:
            sys.exit("LRO timeout")
    if r.status_code != 200:
        sys.exit(f"getDefinition -> {r.status_code}: {r.text[:400]}")
    for p in r.json().get("definition", {}).get("parts", []):
        fp = os.path.join(out_dir, p["path"])
        os.makedirs(os.path.dirname(fp), exist_ok=True)
        open(fp, "wb").write(base64.b64decode(p["payload"]))
    print(f"[extract-pbir] fetched PBIR -> {out_dir}", file=sys.stderr)


def _role_bindings(query_state):
    """{Role: [queryRef, ...]} from visual.query.queryState."""
    out = {}
    for role, blk in (query_state or {}).items():
        refs = [p.get("queryRef") or p.get("nativeQueryRef")
                for p in blk.get("projections", []) if isinstance(p, dict)]
        out[role] = [r for r in refs if r]
    return out


def _textbox_body(visual):
    """Best-effort text body for textbox/card-title visuals."""
    objs = visual.get("objects", {})
    for key in ("general", "text"):
        for item in objs.get(key, []):
            t = item.get("properties", {}).get("text", {}).get("expr", {}).get("Literal", {}).get("Value")
            if t:
                return t.strip("'")
    return None


def extract(pbir_dir):
    defn = os.path.join(pbir_dir, "definition")
    if not os.path.isdir(defn):
        sys.exit(f"no definition/ under {pbir_dir} — is this a PBIR folder?")
    pages_meta = json.load(open(os.path.join(defn, "pages", "pages.json")))
    page_order = pages_meta.get("pageOrder", [])
    out_pages = []
    for pname in page_order:
        pdir = os.path.join(defn, "pages", pname)
        page = json.load(open(os.path.join(pdir, "page.json")))
        visuals = []
        vroot = os.path.join(pdir, "visuals")
        for vid in sorted(os.listdir(vroot)) if os.path.isdir(vroot) else []:
            vf = os.path.join(vroot, vid, "visual.json")
            if not os.path.exists(vf):
                continue
            v = json.load(open(vf))
            pos = v.get("position", {})
            visual = v.get("visual", {})
            vtype = visual.get("visualType", "unknown")
            qs = visual.get("query", {}).get("queryState", {})
            rec = {
                "visual_id": v.get("name", vid),
                "visual_type": vtype,
                "sigma_kind": VISUAL_KIND.get(vtype, "bar"),
                "x": pos.get("x", 0), "y": pos.get("y", 0),
                "w": pos.get("width", 0), "h": pos.get("height", 0),
                "z": pos.get("z", 0),
                "parent_group": v.get("parentGroupName"),
                "bindings": _role_bindings(qs),
            }
            if rec["sigma_kind"] == "text":
                rec["text"] = _textbox_body(visual)
            visuals.append(rec)
        visuals.sort(key=lambda r: (r["y"], r["x"]))
        out_pages.append({
            "page_id": page.get("name", pname),
            "page_title": page.get("displayName", pname),
            "page_w": page.get("width", 1280),
            "page_h": page.get("height", 720),
            "visuals": visuals,
        })
    return {"source": "pbir", "pbir_dir": pbir_dir, "pages": out_pages}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pbir-dir", default="/tmp/pbir")
    ap.add_argument("--workspace", help="fetch live report from this workspace id first")
    ap.add_argument("--report", help="fetch this report id first")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    if a.workspace and a.report:
        os.makedirs(a.pbir_dir, exist_ok=True)
        _fetch_pbir(a.workspace, a.report, a.pbir_dir)
    signals = extract(a.pbir_dir)
    out = a.out or os.path.join(a.pbir_dir, "signals.json")
    json.dump(signals, open(out, "w"), indent=2)
    nvis = sum(len(p["visuals"]) for p in signals["pages"])
    print(f"[extract-pbir] {len(signals['pages'])} page(s), {nvis} visual(s) -> {out}", file=sys.stderr)
    for p in signals["pages"]:
        for v in p["visuals"]:
            print(f"  {p['page_id']:>6} {v['visual_type']:>22} -> {v['sigma_kind']:<11} "
                  f"{ {k: vv for k, vv in v['bindings'].items()} }", file=sys.stderr)


if __name__ == "__main__":
    main()
