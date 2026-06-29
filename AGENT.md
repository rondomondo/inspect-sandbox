# AGENT.md -- inspect-sandbox

## Purpose

`inspect-sandbox` inspects the current Linux environment (container or sandbox) and produces:

- A structured plain-text report covering filesystem mounts, process security context, network configuration, running processes, runtime availability, and skill tool availability
- Mermaid diagrams visualising the above as interactive SVGs
- A multi-page landscape A4 PDF of all text sections (via Playwright/Chromium)
- A self-contained zip bundle the user can download and run locally

Sensitive environment variables (matching patterns like `KEY`, `TOKEN`, `SECRET`, `PASSWORD`, `AUTH`, `API_*`) are automatically redacted to `***REDACTED***` in the report before any output is written. Credentials embedded in proxy URLs are stripped too.

## Trigger

Use the `/inspect-sandbox` skill. Do not call scripts directly.

## Entry Point

```bash
make inspect
```

This is the **only** supported entry point. It runs the full pipeline in order:
`stop` -> `report` -> `diagrams` -> `serve` -> `open`

Do not call `sandbox_inspect.sh`, `generate_diagrams.py`, or `screenshot_report.py` directly.

## Environment Detection

After `make inspect` completes, check whether you are in a sandbox:

```bash
echo "${IS_SANDBOX:-no}"
```

- **`IS_SANDBOX=yes`** (web UI, mobile): no browser is available -- build the downloadable zip bundle (see SKILL.md §3a-3e)
- **`IS_SANDBOX` unset or `no`** (local CLI): `make inspect` opens `inspector.html` directly in the browser -- no further action needed

## Output

All generated files land in `output/sandbox/`:

```
output/sandbox/
├-- report_<YYYYMMDD_HHMMSS>.txt   timestamped raw inspection report
├-- latest -> report_<...>.txt     symlink to most recent report
├-- diagram_network.md             Mermaid source -- network topology
├-- diagram_mounts.md              Mermaid source -- filesystem topology
├-- diagram_security.md            Mermaid source -- security context
├-- diagram_runtime.md             Mermaid source -- runtime availability
├-- diagram_*-1.svg                pre-rendered SVG diagrams (mmdc output)
├-- diagrams.json                  manifest consumed by inspector.html
├-- sandbox-report.pdf             multi-page A4 landscape PDF (Playwright)
├-- serve.sh                       local server launcher (promoted to zip root)
└-- README.md                      user instructions (promoted to zip root)
```

## Sandbox Bundle (IS_SANDBOX=yes only)

See `SKILL.md` for the full step-by-step. Summary:

1. **Render SVGs**: run `mmdc` on each `output/sandbox/diagram_*.md` using the sandbox Chromium (`/opt/pw-browsers/chromium-1194/chrome-linux/chrome`)
2. **Render PDF**: `python3 scripts/screenshot_report.py --out-dir output/sandbox`
3. **Write `serve.sh`** and **`README.md`** into `output/sandbox/`
4. **Security check**: scan `output/sandbox/report.txt` for unredacted secrets before zipping
5. **Assemble zip**: stage files into a temp directory; zip to `/mnt/user-data/outputs/sandbox-inspection.zip`
6. **Present**: show the PDF inline via `pdftoppm` + `view`; provide download links for both PDF and zip

## Key Constraints

- **Auto-redaction**: `sandbox_inspect.sh` redacts known secret patterns automatically. The pre-zip security scan (step 4 above) is a safety net for operator-injected variables with unusual names -- do not skip it.
- **Port**: HTTP server runs on `8008` by default (`PORT=8008` in the Makefile). Override with `PORT=9090 make serve`.
- **PDF rendering**: always use `file://` + inline-data approach (`screenshot_report.py`). Do NOT use a localhost HTTP server for PDF rendering -- Playwright's Chromium blocks loopback connections.
- **`inspector.html` as `file://`**: will fail silently -- `fetch()` is blocked on `file://` origins. Must be served over HTTP.
- **Mermaid stub**: `screenshot_report.py` replaces `mermaid.min.js` with a no-op stub before PDF rendering. Do not inline the full `mermaid.min.js` -- at ~3 MB it renders as visible body text in the PDF.
- **SVG naming**: `mmdc` produces `diagram_<key>-1.svg`. `generate_diagrams.py` auto-detects both `mmdc` and Docker wrapper naming.
- **Diagrams tab excluded from PDF**: intentional -- Mermaid SVGs paginate badly. They are fully available in the zip and interactive viewer.

## Setup (first run)

```bash
make install    # requires uv (https://docs.astral.sh/uv/)
make inspect
```

## Development Targets

| Target           | Action                                      |
| :--------------- | :------------------------------------------ |
| `make format`    | ruff format + ruff isort                    |
| `make lint`      | ruff check + mypy                           |
| `make typecheck` | mypy                                        |
| `make test`      | pytest with coverage                        |
| `make ci`        | lint + test                                 |
| `make clean`     | remove output, build artefacts              |
| `make distclean` | clean + remove .venv                        |
| `make zip-prep`  | stage distributable files for zipping       |

## Evals

Trigger and behavioural evals live in `evals/evals.json`. 18 evals across six categories: `trigger_positive`, `trigger_negative`, `pipeline_execution`, `security`, `output_completeness`, `error_handling`. Compatible with the skill-creator grader and benchmark runner; includes RAGAS-style `ragas_aspect` and `rubric_weight` fields for use with RAG pipeline evaluators.
