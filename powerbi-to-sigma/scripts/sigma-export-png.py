#!/usr/bin/env python3
"""sigma-export-png.py — render a Sigma workbook to an image via the REST export
API, for VISUAL verification (more reliable than MCP SQL for sort-dependent
aggregates like Last()/First() KPIs).

POST /v2/workbooks/{id}/export {pageId|elementId, format:{type:"png"|"pdf",...}}
  -> {queryId}; then GET /v2/query/{queryId}/download until the file is ready.

Env: SIGMA_BASE_URL + SIGMA_API_TOKEN (eval "$(get-token.sh)").
Usage:
  python3 sigma-export-png.py --workbook <id> --page <pageId>  --out /tmp/x.png
  python3 sigma-export-png.py --workbook <id> --element <elId>  --out /tmp/x.png [--w 1600 --h 900]
  python3 sigma-export-png.py --workbook <id> --all-pages        --out /tmp/wb.png   # every page, stitched vertically
  python3 sigma-export-png.py --workbook <id> --pdf              --out /tmp/wb.pdf   # whole workbook, native PDF
"""
import argparse, os, sys, time, tempfile, requests


def _download(base, tok, body, out):
    """POST an export job and poll the download endpoint until the file lands."""
    h = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
    r = requests.post(f"{base}/v2/workbooks/{body['_wb']}/export", headers=h,
                      json={k: v for k, v in body.items() if not k.startswith("_")})
    if r.status_code != 200:
        sys.exit(f"export POST {r.status_code}: {r.text[:300]}")
    qid = r.json()["queryId"]
    dl = f"{base}/v2/query/{qid}/download"
    for _ in range(80):
        g = requests.get(dl, headers={"Authorization": f"Bearer {tok}"})
        ct = g.headers.get("Content-Type", "")
        sig = g.content[:8]
        ready = g.status_code == 200 and (
            "image" in ct or "pdf" in ct or sig[:8] == b"\x89PNG\r\n\x1a\n" or sig[:4] == b"%PDF")
        if ready:
            open(out, "wb").write(g.content)
            return len(g.content)
        time.sleep(3)
    sys.exit("timed out waiting for export")


def _pages(base, tok, wb):
    g = requests.get(f"{base}/v2/workbooks/{wb}/pages",
                     headers={"Authorization": f"Bearer {tok}"})
    g.raise_for_status()
    return [(p["pageId"], p.get("name", p["pageId"])) for p in g.json().get("entries", [])]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workbook", required=True)
    ap.add_argument("--page"); ap.add_argument("--element")
    ap.add_argument("--all-pages", action="store_true", help="export every page and stitch vertically into one PNG")
    ap.add_argument("--pdf", action="store_true", help="export the whole workbook as a native PDF")
    ap.add_argument("--out", required=True)
    ap.add_argument("--w", type=int, default=1600); ap.add_argument("--h", type=int, default=900)
    a = ap.parse_args()
    base = os.environ["SIGMA_BASE_URL"]; tok = os.environ["SIGMA_API_TOKEN"]
    wb = a.workbook

    if a.pdf:
        n = _download(base, tok, {"_wb": wb, "format": {"type": "pdf", "layout": "landscape"}}, a.out)
        print(f"[pdf] {n} bytes -> {a.out}"); return

    if a.all_pages:
        from PIL import Image
        pages = _pages(base, tok, wb)
        pages = [(pid, nm) for pid, nm in pages if not pid.endswith("page-data")]  # skip hidden Data page
        imgs = []
        with tempfile.TemporaryDirectory() as td:
            for pid, nm in pages:
                p = os.path.join(td, f"{pid}.png")
                _download(base, tok, {"_wb": wb, "pageId": pid,
                                      "format": {"type": "png", "pixelWidth": a.w, "pixelHeight": a.h}}, p)
                imgs.append(Image.open(p).convert("RGB"))
                print(f"  [page] {nm}", file=sys.stderr)
            if not imgs:
                sys.exit("no pages to export")
            gap, bg = 24, (240, 242, 245)
            width = max(im.width for im in imgs)
            total = sum(im.height for im in imgs) + gap * (len(imgs) - 1)
            canvas = Image.new("RGB", (width, total), bg)
            y = 0
            for im in imgs:
                canvas.paste(im, ((width - im.width) // 2, y))
                y += im.height + gap
            canvas.save(a.out)
        print(f"[png] {len(imgs)} page(s) stitched -> {a.out}"); return

    fmt = {"type": "png", "pixelWidth": a.w, "pixelHeight": a.h}
    body = {"_wb": wb, "format": fmt}
    if a.element: body["elementId"] = a.element
    elif a.page:  body["pageId"] = a.page
    else: sys.exit("need --page, --element, --all-pages, or --pdf")
    n = _download(base, tok, body, a.out)
    print(f"[png] {n} bytes -> {a.out}")


if __name__ == "__main__":
    main()
