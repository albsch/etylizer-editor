#!/usr/bin/env python3
"""Assemble the single self-contained editor HTML from the staged _build/web/ tree.

Inline Ace, the Emscripten loader (beam.js) and base64 of beam.wasm + beam.data into
_build/release/etylizer-editor.html. Mode is selected by $ETY_THREADS (default pthreads):

  single   : also inline the per-check worker (beam-worker.js). No SharedArrayBuffer /
             cross-origin isolation needed → the one HTML is fully self-contained.
  pthreads : NO worker inlined (beam.js runs PROXY_TO_PTHREAD). The BEAM needs SAB, so the
             page needs cross-origin isolation; coi-serviceworker.js is written ALONGSIDE
             the HTML (a service worker must be a separate file at a stable URL).

Either way the page must be SERVED over http(s) (assets load via Blob URLs / a SW, both
blocked from file://).

    ETY_THREADS=pthreads python3 build-release.py -> _build/release/etylizer-editor.html (+ coi-serviceworker.js)
    ETY_THREADS=single   python3 build-release.py -> _build/release/etylizer-editor.html
"""
import base64
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.join(HERE, "_build", "web")
OUT_DIR = os.path.join(HERE, "_build", "release")
OUT_HTML = os.path.join(OUT_DIR, "etylizer-editor.html")
THREADS = os.environ.get("ETY_THREADS", "pthreads")

# JS that is inlined inside a <script>…</script> must not contain a literal
# "</script>" (the parser would close the element early). It only ever appears
# inside string/regex literals in our assets, where "<\/script>" is equivalent.
def esc(js: str) -> str:
    return js.replace("</script", "<\\/script").replace("</SCRIPT", "<\\/SCRIPT")


def read_text(rel: str) -> str:
    with open(os.path.join(WEB, rel), "r", encoding="utf-8") as f:
        return f.read()


def read_b64(rel: str) -> str:
    with open(os.path.join(WEB, rel), "rb") as f:
        return base64.b64encode(f.read()).decode("ascii")


def main() -> int:
    html = read_text("editor.html")

    # 1) Inline the script-src assets (Ace editor + Erlang/Elixir modes + theme).
    for rel in ("ace/ace.min.js", "ace/theme-tomorrow_night.min.js",
                "ace/mode-erlang.min.js", "ace/mode-elixir.min.js"):
        tag = f'<script src="{rel}"></script>'
        if tag not in html:
            print(f"ERROR: expected tag not found: {tag}", file=sys.stderr)
            return 1
        html = html.replace(tag, "<script>\n" + esc(read_text(rel)) + "\n</script>")

    # 2) Embed beam.{js,wasm,data} (and, for single mode, the per-check worker) as
    #    <script> holders the page reads at boot. beam.js / beam-worker.js are text;
    #    wasm/data are base64 (decoded to byte buffers in the page).
    holders = ""
    if THREADS == "single":
        holders += ('<script type="text/plain" id="beam-worker">'
                    + esc(read_text("beam-worker.js")) + "</script>\n")
    holders += (
        '<script type="application/octet-stream" id="beam-wasm">'
        + read_b64("beam.wasm") + "</script>\n"
        '<script type="application/octet-stream" id="beam-data">'
        + read_b64("beam.data") + "</script>\n"
        '<script type="text/plain" id="beam-js">'
        + esc(read_text("beam.js")) + "</script>\n"
    )
    marker = "<!-- BEAM-ASSETS -->"
    if marker not in html:
        print("ERROR: insertion marker not found", file=sys.stderr)
        return 1
    html = html.replace(marker, holders + marker, 1)

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_HTML, "w", encoding="utf-8") as f:
        f.write(html)
    size = os.path.getsize(OUT_HTML)
    print(f"wrote {OUT_HTML}  ({size/1e6:.1f} MB)  [THREADS={THREADS}]")

    # pthreads needs cross-origin isolation → ship the COI service worker alongside.
    if THREADS != "single":
        shutil.copy(os.path.join(WEB, "coi-serviceworker.js"),
                    os.path.join(OUT_DIR, "coi-serviceworker.js"))
        print(f"wrote {os.path.join(OUT_DIR, 'coi-serviceworker.js')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
