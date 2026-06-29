# inspect-sandbox

Performs automated linux container or sandbox environment inspection that parses system state into a self-contained HTML viewer with collapsible sections, category filters, and rendered Mermaid diagrams. When running inside an AI sandbox (like Claude Web UI etc), the full output is packaged into a downloadable zip that the user can run locally with a single command. A multi page landscape A4 PDF of all text sections is also rendered via Playwright and presented inline in the chat client as well as in the download bundle.

---

> **Try it now** -- just say one of these to your agent:
> - *Inspect this sandbox and show me what's available*
> - *What tools, runtimes, and network access do I have in here?*
> - *Run /inspect-sandbox and give me a full environment report*

---

## Why inspect the sandbox?

When you build skills or agents that run inside an AI sandbox -- whether Claude's web UI, a CI runner, or a cloud container -- you are working inside an environment you did not configure and cannot easily observe. That gap causes real problems:

**The slow-burn discover-as-you-fail loop.** Skills break at runtime because a tool isn't installed, a capability is blocked, the network is restricted, or a write path doesn't exist. You fix one thing, redeploy, and hit the next wall. Each round-trip costs minutes or hours. `inspect-sandbox` collapses that loop into a single upfront read.

**Things you didn't know you needed to know.** You only discover that `mmdc` needs a real display server, that `pip` is replaced by `uv`, that `/tmp` is a `tmpfs` with a 512 MB cap, or that outbound DNS is filtered -- when your skill fails silently at 2am. The inspection surfaces all of it before you write a line of code.

**Concrete constraints, not guesses.** How much disk can I write? Which Linux capabilities do I have? Is `ptrace` blocked? Is there a proxy? Does `sudo` work? Is seccomp enabled? These answers are not in any documentation -- they depend on how the specific sandbox was configured. The report gives you the ground truth.

**What the report covers:**

| Section | What you learn |
|---|---|
| Filesystem & mounts | Where you can write, overlay/rclone mounts, tmpfs limits, symlink layout |
| Security context | uid/gid, Linux capabilities (decoded), seccomp mode, AppArmor/SELinux, namespace isolation |
| Network | Interfaces, routing, DNS, iptables rules, proxy variables, custom CA certs |
| Processes | Process tree, CPU/RAM, open file descriptors, listening ports |
| Runtime environment | Installed languages and versions, package managers, OS/kernel/CPU info |
| Skill tool availability | Presence of runtimes, PDF tools, OCR, media tools, browsers, shell utilities |



**Sensitive values are automatically redacted.** Environment variables whose names match patterns like `KEY`, `TOKEN`, `SECRET`, `PASSWORD`, `AUTH`, or `API_*` are replaced with `***REDACTED***` before the report is written. Credentials embedded in proxy URLs (`http://user:pass@host`) are stripped too. You can share the report with teammates without leaking secrets.

**The output is designed to travel.** Because you can't open a browser tab inside the sandbox, the skill packages a self-contained HTML viewer and a multi-page PDF together in a zip you download from the chat. The HTML viewer works offline -- no CDN, no internet -- and renders interactive Mermaid topology diagrams alongside the full text report.

> **See [`sandbox-report.pdf`](examples/sandbox-report.pdf) for a real report generated inside the Claude sandbox.**  
> It shows a concrete example of capabilities, mounts, network topology, and redacted environment -- the kind of detail you'd otherwise spend hours piecing together.

| Report overview | Network & mounts diagrams |
|:---:|:---:|
| ![Report overview](examples/report.1.webp) | ![Network and mounts diagrams](examples/report.2.webp) |


---

## Quick Start

```bash
make install    # install Python deps (once)
make inspect    # run the full pipeline (creates and displays report)
```

`make inspect` is the only command you need for day-to-day use.

---

## Make Targets

### `make inspect` -- the full pipeline atomatically

The primary entry point. Runs everything in order:

1. `stop` -- kills any stale visualisation standalone http server
2. `report` -- executes `sandbox_inspect.sh`, writes a timestamped report to `output/sandbox/` and updates the `latest` symlink point to it
3. `diagrams` -- parses the report, generates Mermaid `.md` files and `diagrams.json`
4. `serve` -- starts a background HTTP server on `http://localhost:8008`
5. `open` -- opens `http://localhost:8008/inspector.html` in your default browser

Never call the underlying scripts directly. `make inspect` is the way.

### `make install`

Installs all dependencies via `uv sync`. Run once before first use. Safe to re-run.

```bash
make install
```

Requires [`uv`](https://docs.astral.sh/uv/) to be installed and should do it for you.

### `make report`

Runs `scripts/sandbox_inspect.sh` and writes a timestamped plain-text report to `output/sandbox/report_<YYYYMMDD_HHMMSS>.txt`. Also updates the `output/sandbox/latest` symlink to point to the new report and prunes old reports beyond the most recent 10 last reports.

```bash
make report
```

### `make diagrams`

Runs `make report` first, then parses the report and generates:

- `output/sandbox/diagram_network.md` -- network interface topology
- `output/sandbox/diagram_mounts.md` -- filesystem mount topology
- `output/sandbox/diagram_security.md` -- security context and capabilities
- `output/sandbox/diagram_runtime.md` -- runtime and tool availability
- `output/sandbox/diagrams.json` -- manifest consumed by `inspector.html`

```bash
make diagrams
```

### `make serve`

Starts a background HTTP server at `http://localhost:8008` using Python's built-in `http.server`. Uses `watchmedo` to auto-restart when diagram files change. Stores the PID in `$TMPDIR/inspect-sandbox.pid`. Opening this url should give you the report.

```bash
make serve
make stop    # stop the server
```

Override the port:

```bash
PORT=9090 make serve
```

### `make zip-prep`

Copies distributable files (`inspector.html`, `index.html`, `SKILL.md`, `AGENT.md`, `Makefile`, `vendor/`, `scripts/`, `favicon.ico`, `pyproject.toml`, `examples/`) into a staging directory `../zipped/inspect-sandbox/`. 

```bash
make zip-prep name=inspect-sandbox
```

---

## Installing the Skill

The skill directory (`.`) can be copied to either a global or project-local skills location so the agent picks it up automatically.

**Global** (available in any project):

```bash
cp -R  ~/.claude/skills/inspect-sandbox
```

**Project-local** (only in the current repo):

```bash
cp -R . .claude/skills/inspect-sandbox 
```

---

## How It Works in Each Environment

### Agent sandbox (web UI or mobile)

The agent runs inside an isolated Linux sandbox with filesystem and network access. The skill runs the full pipeline:

1. `make inspect` -> `report.txt`, diagrams, `diagrams.json`
2. Mermaid diagrams are rendered to SVG using `mmdc` with the sandbox Chromium
3. `screenshot_report.py` renders a multi-page landscape A4 PDF via Playwright
4. A `serve.sh` launcher and `README.md` are written into `output/sandbox/`
5. Everything is staged and zipped to `/mnt/user-data/outputs/sandbox-inspection.zip`
6. The PDF is presented inline in the chat; download links are provided for both the PDF and the zip

The HTML viewer cannot be served directly from within the sandbox (no browser), so the user downloads the zip and runs it locally.

### Local terminal (CLI)

When run locally via a CLI, the environment is detected as non-sandbox (`IS_SANDBOX` is unset or `no`). The skill runs `make inspect`, which starts the HTTP server and opens `http://localhost:8008/inspector.html` directly in your default browser. No zip or PDF packaging step is needed.

---

## The PDF Report

`scripts/screenshot_report.py` renders `inspector.html` as a multi-page landscape A4 PDF using Playwright + Chromium:

- Covers all five text sections: filesystem, security, network, processes, runtime
- Intentionally excludes the diagrams tab (Mermaid SVGs are interactive and don't paginate well in print)
- Uses a `file://` URL with inlined data rather than an HTTP server -- Playwright's Chromium sandbox blocks loopback connections
- Output: `output/sandbox/sandbox-report.pdf`

---

## The `inspector.html` Viewer

`inspector.html` is a self-contained single-page app that requires only a browser and a local HTTP server. It:

- Loads `output/sandbox/report.txt` (via the `latest` symlink) and `output/sandbox/diagrams.json` via `fetch()`
- Parses the report into collapsible sections with category filters
- **Real-time search** -- type to instantly filter all report entries across every section
- Renders pre-built Mermaid SVGs inline in the Diagrams tab
- Includes a dark/light mode toggle
- Bundles `vendor/js/mermaid.min.js` so no CDN is needed

**Important:** `inspector.html` must be served over HTTP -- it uses `fetch()` which is blocked on `file://` origins in most browsers. Use `make serve`, `./serve.sh`, `python3 -m http.server`, or `npx serve`.

---

## The Mermaid Diagrams

Four diagrams are generated from the inspection report:

- **Network diagram** -- network interface topology and connectivity
- **Mounts diagram** -- filesystem topology showing block devices and mount points
- **Security diagram** -- Linux capabilities, uid/gid, namespaces, seccomp status
- **Runtime diagram** -- available tools and language runtimes

Each diagram is written as a fenced Mermaid code block in a `.md` file. The `.md` files are:
- Rendered independently in VS Code with the Mermaid Preview extension
- Renderable on GitHub (GitHub natively renders Mermaid in Markdown)
- Pre-rendered to `.svg` by `mmdc` for inline display in `inspector.html`

---

## Output Tree

```
output/sandbox/
├-- report_<YYYYMMDD_HHMMSS>.txt   timestamped raw inspection output
├-- latest -> report_<...>.txt     symlink to most recent report
├-- diagram_network.md             Mermaid source -- network topology
├-- diagram_mounts.md              Mermaid source -- filesystem topology
├-- diagram_security.md            Mermaid source -- security context
├-- diagram_runtime.md             Mermaid source -- runtime summary
├-- diagram_*-1.svg                rendered SVG diagrams
├-- diagrams.json                  manifest: key -> {title, md file, svg file}
├-- sandbox-report.pdf             multi-page A4 landscape PDF (Playwright)
├-- serve.sh                       staged launcher (promoted to zip root)
└-- README.md                      staged instructions (promoted to zip root)
```

The downloaded zip has a flat root layout so `inspector.html` and `serve.sh` are at the same level and relative paths resolve correctly.

---

## Development

```bash
make format      # ruff format + ruff isort
make lint        # ruff check + mypy
make typecheck   # mypy
make test        # pytest with coverage
make ci          # lint + test
make clean       # remove Python caches and build artifacts
make distclean   # clean + remove .venv
```
