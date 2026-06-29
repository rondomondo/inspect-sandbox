#!/usr/bin/env -S uv run python3
"""
screenshot_report.py -- Render inspector.html as a multi-page A4 PDF.

Patches inspector.html to inline all data (bypassing fetch()), loads it via
file:// in Playwright/Chromium, then renders each tab as one A4 page in a
combined PDF.

Usage (run from skill working directory):
    python3 scripts/screenshot_report.py [--out-dir output/sandbox]
                                         [--width 1280]

Output:
    <out-dir>/sandbox-report.pdf   (one A4 page per tab + overview cover)
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

CHROMIUM_DEFAULT = "/opt/pw-browsers/chromium-1194/chrome-linux/chrome"
PLAYWRIGHT_IMAGE = "mcr.microsoft.com/playwright:v1.59.1-jammy"

# A4 at 96dpi: 794 x 1123px  |  Playwright pdf() uses CSS pt units
# We use a wider viewport so text doesn't wrap badly, then let PDF scale it
A4_WIDTH_PT = 841.89  # landscape A4 in pt (swap for portrait: 595.28)
A4_HEIGHT_PT = 595.28


def _in_sandbox() -> bool:
    """Return True when running inside a container/sandbox environment."""
    import os
    if os.environ.get("IS_SANDBOX", "").lower() in ("yes", "1", "true"):
        return True
    return Path("/.dockerenv").exists() or Path("/run/.containerenv").exists()


def _docker_available() -> bool:
    import shutil
    if not shutil.which("docker"):
        return False
    result = subprocess.run(["docker", "info"], capture_output=True)
    return result.returncode == 0


def find_chromium():
    if Path(CHROMIUM_DEFAULT).exists():
        return CHROMIUM_DEFAULT
    result = subprocess.run(["find", "/opt/pw-browsers", "-name", "chrome"], capture_output=True, text=True)
    candidates = [line for line in result.stdout.splitlines() if "headless" not in line]
    if candidates:
        return candidates[0]
    raise RuntimeError("Chromium not found. Check /opt/pw-browsers.")


def render_pdf_via_docker(patched_html: Path, pdf_path: Path, width: int) -> None:
    """Run the PDF render step inside the Playwright Docker image."""
    # We need a self-contained renderer script the container can execute.
    renderer = patched_html.parent / "_docker_render.py"
    container_work = "/work"
    html_rel = patched_html.relative_to(Path.cwd())
    pdf_rel = pdf_path.relative_to(Path.cwd())

    renderer.write_text(f"""\
import time, sys
from pathlib import Path
from playwright.sync_api import sync_playwright

file_url = (Path("{container_work}") / "{html_rel}").resolve().as_uri()
pdf_path = Path("{container_work}") / "{pdf_rel}"
pdf_path.parent.mkdir(parents=True, exist_ok=True)

with sync_playwright() as p:
    browser = p.chromium.launch(
        args=["--no-sandbox", "--disable-setuid-sandbox", "--allow-file-access-from-files"],
    )
    page = browser.new_page(viewport={{"width": {width}, "height": 900}})
    page.goto(file_url, wait_until="networkidle", timeout=20000)
    time.sleep(1.5)
    page.evaluate(\"\"\"() => {{
        document.querySelectorAll('details').forEach(d => {{ d.open = true; }});
        document.querySelectorAll('.tab-panel').forEach(p => {{
            p.classList.add('active');
            p.style.display = 'block';
        }});
    }}\"\"\")
    time.sleep(0.5)
    page.pdf(
        path=str(pdf_path),
        format="A4",
        landscape=True,
        margin={{"top": "12mm", "bottom": "12mm", "left": "12mm", "right": "12mm"}},
    )
    browser.close()
print(f"  docker-rendered {{pdf_path.name}}")
""")

    cmd = [
        "docker",
        "run",
        "--rm",
        "-v",
        f"{Path.cwd()}:{container_work}",
        "-w",
        container_work,
        PLAYWRIGHT_IMAGE,
        "python3",
        f"{container_work}/{renderer.relative_to(Path.cwd())}",
    ]
    print(f"  Running Playwright via Docker ({PLAYWRIGHT_IMAGE}) ...")
    result = subprocess.run(cmd, capture_output=False)
    renderer.unlink(missing_ok=True)
    if result.returncode != 0:
        raise RuntimeError(f"Docker Playwright render failed (exit {result.returncode})")


def build_patched_html(sandbox_dir: Path) -> Path:
    """Inline all data into inspector.html and intercept fetch() calls."""
    html = Path("inspector.html").read_text()
    report = (sandbox_dir / "report.txt").read_text()
    diagrams = json.loads((sandbox_dir / "diagrams.json").read_text())

    inline_files = {}
    for d in diagrams:
        for key in ("image_file", "file"):
            fname = d.get(key)
            if fname:
                fpath = sandbox_dir / fname
                if fpath.exists():
                    inline_files[f"output/sandbox/{fname}"] = fpath.read_text()

    data_script = (
        "<script>\n"
        f"window.__INLINE_REPORT__ = {json.dumps(report)};\n"
        f"window.__INLINE_DIAGRAMS__ = {json.dumps(diagrams)};\n"
        f"window.__INLINE_FILES__ = {json.dumps(inline_files)};\n"
        "</script>"
    )

    fetch_patch = """<script>
const _origFetch = window.fetch;
window.fetch = function(url, opts) {
  const u = url ? url.toString() : '';
  const rel = u.replace(/^file:[/][/][^/]*[/]/, '').replace(/^[/]/, '');
  if (window.__INLINE_REPORT__ && (u.includes('report') || u.includes('latest')))
    return Promise.resolve(new Response(window.__INLINE_REPORT__, {status: 200}));
  if (window.__INLINE_DIAGRAMS__ && u.includes('diagrams.json'))
    return Promise.resolve(new Response(JSON.stringify(window.__INLINE_DIAGRAMS__), {status: 200}));
  if (window.__INLINE_FILES__) {
    for (const [key, content] of Object.entries(window.__INLINE_FILES__)) {
      if (u.endsWith(key) || rel.endsWith(key.replace(/^output[/]sandbox[/]/, ''))) {
        const ct = key.endsWith('.svg') ? 'image/svg+xml' : 'text/plain';
        return Promise.resolve(new Response(content, {status: 200, headers: {'Content-Type': ct}}));
      }
    }
  }
  return _origFetch(url, opts);
};
</script>"""

    # PDF-specific style overrides.
    # Render ALL text tab panels as one long vertical document.
    # Skip the diagrams tab -- SVGs are too wide/tall for clean print pagination.
    pdf_styles = """<style id="pdf-overrides">
  body {
    height: auto !important;
    overflow: visible !important;
    display: block !important;
    background: #f1f5f9 !important;
  }
  .sidebar  { display: none !important; }
  .top-info { display: none !important; }
  .main     { min-width: 0 !important; display: block !important; }
  .content-area {
    overflow: visible !important;
    height: auto !important;
    padding: 24px 32px !important;
    display: block !important;
  }
  /* Show all panels except the diagrams panel */
  .tab-panel {
    display: block !important;
    max-width: 100% !important;
    page-break-before: always;
    break-before: page;
    padding-top: 8px;
  }
  .tab-panel:first-of-type,
  #panel-diagrams {
    display: none !important;
  }
  pre {
    white-space: pre-wrap !important;
    word-break: break-word !important;
  }
  .report-card {
    box-shadow: none !important;
    border: 1px solid #ddd !important;
    break-inside: avoid;
  }
</style>"""

    # Replace mermaid script tag with a lightweight stub.
    # Under file:// the relative src path fails to resolve, which aborts app init
    # before fetch() fires, producing a blank PDF.
    # Do NOT inline mermaid.min.js as a <script> block -- at ~3MB of minified JS
    # with no newlines, Chromium's PDF renderer treats it as visible body text.
    mermaid_stub = "<script>window.mermaid = {initialize(){}, run(){}, contentLoaded(){}};</script>"
    patched = html.replace('<script src="vendor/js/mermaid.min.js"></script>', mermaid_stub, 1)
    patched = patched.replace("</head>", data_script + fetch_patch + pdf_styles + "\n</head>", 1)
    out_path = sandbox_dir / "inspector_patched.html"
    out_path.write_text(patched)
    return out_path


def main():
    parser = argparse.ArgumentParser(description="Render inspector.html as multi-page A4 PDF")
    parser.add_argument("--out-dir", default="output/sandbox")
    parser.add_argument("--width", type=int, default=1400, help="Viewport width in px (content scales to A4)")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    patched_html = build_patched_html(out_dir)
    pdf_path = out_dir / "sandbox-report.pdf"

    use_docker = not _in_sandbox() and _docker_available()

    if use_docker:
        render_pdf_via_docker(patched_html, pdf_path, args.width)
    else:
        chromium = find_chromium()
        file_url = patched_html.resolve().as_uri()

        try:
            from playwright.sync_api import sync_playwright
        except ImportError:
            print("ERROR: playwright not installed.", file=sys.stderr)
            sys.exit(1)

        with sync_playwright() as p:
            browser = p.chromium.launch(
                executable_path=chromium,
                args=["--no-sandbox", "--disable-setuid-sandbox", "--allow-file-access-from-files"],
            )
            page = browser.new_page(viewport={"width": args.width, "height": 900})

            print(f"  Loading {file_url} ...")
            page.goto(file_url, wait_until="networkidle", timeout=20000)
            time.sleep(1.5)

            page.evaluate("""() => {
                document.querySelectorAll('details').forEach(d => { d.open = true; });
                document.querySelectorAll('.tab-panel').forEach(p => {
                    p.classList.add('active');
                    p.style.display = 'block';
                });
            }""")
            time.sleep(0.5)

            print("  Rendering PDF (all tabs as one document) ...")
            page.pdf(
                path=str(pdf_path),
                format="A4",
                landscape=True,
                margin={"top": "12mm", "bottom": "12mm", "left": "12mm", "right": "12mm"},
            )
            browser.close()

    patched_html.unlink(missing_ok=True)

    size_kb = pdf_path.stat().st_size // 1024
    print(f"  [x] {pdf_path}  ({size_kb} KB total)")
    return pdf_path


if __name__ == "__main__":
    main()
