#!/usr/bin/env python3
"""build-bookmark-workbooks.py — one Sigma workbook per Power BI bookmark.

Power BI bookmarks that show/hide or spotlight visuals map cleanly to Sigma as
a workbook over the bookmark's *visible subset* of visuals. Given the base
signals.json (what built the main workbook) + normalized bookmarks.json
(extract-bookmarks.py), this filters the visuals per bookmark and shells out to
build-workbook-from-pbir.rb to emit one workbook spec + layout per bookmark:

  - spotlight non-empty -> keep ONLY the spotlighted visuals (focus view)
  - else                -> all visuals MINUS the bookmark's hidden set

(The "Overview"/all-visible bookmark reproduces the base workbook.) Filter-state
bookmarks aren't auto-applied here — surface bookmarks.json[].filters_raw to the
agent to bake as element filters if needed.

Usage:
  python3 build-bookmark-workbooks.py --signals base/signals.json \
    --bookmarks bm.json --master-map mm.json --data-model <dmId> \
    --folder-id <uuid> --name-prefix "Retail Trends" --out-dir /tmp/bm
Then POST each $OUT_DIR/<name>/workbook-spec.json + put-layout (agent step).
"""
import argparse, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--signals", required=True); ap.add_argument("--bookmarks", required=True)
    ap.add_argument("--master-map", required=True); ap.add_argument("--data-model", required=True)
    ap.add_argument("--folder-id", required=True); ap.add_argument("--name-prefix", required=True)
    ap.add_argument("--out-dir", required=True)
    a = ap.parse_args()
    base = json.load(open(a.signals)); bms = json.load(open(a.bookmarks))["bookmarks"]
    os.makedirs(a.out_dir, exist_ok=True)
    page = base["pages"][0]; all_vis = page["visuals"]
    built = []
    for b in bms:
        hidden, spot = set(b.get("hidden", [])), set(b.get("spotlight", []))
        if spot:
            vis = [v for v in all_vis if v["visual_id"] in spot]
        else:
            vis = [v for v in all_vis if v["visual_id"] not in hidden]
        if not vis:
            print(f"  [skip] {b['displayName']}: no visible visuals", file=sys.stderr); continue
        d = os.path.join(a.out_dir, b["name"]); os.makedirs(d, exist_ok=True)
        sig = dict(base); sig["pages"] = [dict(page, visuals=vis)]
        sigp = os.path.join(d, "signals.json"); json.dump(sig, open(sigp, "w"), indent=2)
        spec = os.path.join(d, "workbook-spec.json"); lay = os.path.join(d, "layout.xml")
        name = f"{a.name_prefix} — {b['displayName']} (from Power BI)"
        r = subprocess.run(["ruby", os.path.join(HERE, "build-workbook-from-pbir.rb"),
            "--signals", sigp, "--master-map", a.master_map, "--data-model", a.data_model,
            "--name", name, "--folder-id", a.folder_id, "--out", spec, "--layout-out", lay],
            capture_output=True, text=True)
        ok = r.returncode == 0 and os.path.exists(spec)
        print(f"  {'OK ' if ok else 'ERR'} {b['displayName']:22} {len(vis)} visual(s) -> {spec}", file=sys.stderr)
        if not ok: print(r.stderr[-300:], file=sys.stderr)
        else: built.append({"bookmark": b["name"], "name": name, "spec": spec, "layout": lay, "visuals": len(vis)})
    json.dump({"built": built}, open(os.path.join(a.out_dir, "manifest.json"), "w"), indent=2)
    print(f"[bookmark-workbooks] built {len(built)} -> {a.out_dir}/manifest.json", file=sys.stderr)

if __name__ == "__main__":
    main()
