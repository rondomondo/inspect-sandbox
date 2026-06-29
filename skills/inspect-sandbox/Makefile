# ============================================================
# inspect-sandbox -- Makefile
# ============================================================
.DEFAULT_GOAL := help
MAKEFLAGS     += --no-print-directory
SHELL         := /bin/bash

# -- Colors ---------------------------------------------------
BOLD   := \033[1m
RED    := \033[31m
GREEN  := \033[32m
BLUE   := \033[34m
CYAN   := \033[36m
YELLOW := \033[33m
RESET  := \033[0m

# -- Project --------------------------------------------------
PROJECT    := inspect-sandbox
SKILL_DIR  := .

# -- Directories ----------------------------------------------
SKILL_SCRIPTS_DIR := $(SKILL_DIR)/scripts
TEST_DIR          := tests
OUTPUT_DIR        := output/sandbox
VENV			:= .venv

# -- Output & Distribution ------------------------------------
INSPECTOR_HTML := inspector.html
ZIP_DIR        := ../zipped/inspect-sandbox
ZIP_FILES      := inspector.html index.html Makefile vendor scripts favicon.ico SKILL.md pyproject.toml evals examples AGENT.md

# -- Report History -------------------------------------------
MAX_REPORTS := 10

# -- Server ---------------------------------------------------
PORT             := 8008
INSPECTOR_DOMAIN := http://localhost
INSPECTOR_URL    := $(INSPECTOR_DOMAIN):$(PORT)
SERVER_PID_FILE  := $(or $(TMPDIR),/tmp)/inspect-sandbox.pid

# -- Tooling --------------------------------------------------
UV        := uv
WATCHMEDO := $(UV) run watchmedo

# Ensure output directory exists
$(shell mkdir -p $(OUTPUT_DIR))

# -- Help -----------------------------------------------------
.PHONY: help
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n"} \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0,5) } \
	  /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)



##@ Setup

.PHONY: check-uv
check-uv: ## Verify uv is available
	@command -v $(UV) >/dev/null 2>&1 || \
	  (printf "$(RED)ERROR:$(RESET) uv not found. Install: https://docs.astral.sh/uv/\n"; exit 1)

.PHONY: install
install: check-uv ## Install Python dependencies
	$(UV) sync --all-extras
	@printf "$(GREEN)Dependencies installed.$(RESET)\n"

##@ Development

.PHONY: format
format: ## Format Python code (ruff)
	$(UV) run --extra dev ruff format $(SKILL_SCRIPTS_DIR)/
	$(UV) run --extra dev ruff check --fix --select I $(SKILL_SCRIPTS_DIR)/

.PHONY: lint
lint: ## Lint Python code (ruff + mypy)
	$(UV) run --extra dev ruff check --fix $(SKILL_SCRIPTS_DIR)/
	$(UV) run --extra dev mypy $(SKILL_SCRIPTS_DIR)/

.PHONY: typecheck
typecheck: ## Run mypy type checks
	$(UV) run --extra dev mypy $(SKILL_SCRIPTS_DIR)/

.PHONY: test
test: ## Run Python tests with coverage
	$(UV) run --extra dev pytest $(TEST_DIR) -v --tb=short --cov=$(SKILL_SCRIPTS_DIR) --cov-report=term-missing

.PHONY: ci
ci: lint test ## Run lint + test (CI pipeline)
	@echo "CI passed"


##@ Inspection

.PHONY: report
report: ## Run sandbox_inspect.sh and write timestamped report; prune old; update 'latest' symlink
	@printf "$(CYAN)[report]$(RESET) Running sandbox_inspect.sh...\n"
	@mkdir -p $(OUTPUT_DIR)
	@TS=$$(date -u '+%Y%m%d_%H%M%S'); \
	 REPORT="$(OUTPUT_DIR)/report_$$TS.txt"; \
	 bash $(SKILL_SCRIPTS_DIR)/sandbox_inspect.sh --out "$$REPORT" || \
	   (ec=$$?; [ $$ec -eq 141 ] || exit $$ec); \
	 ln -sf "report_$$TS.txt" "$(OUTPUT_DIR)/latest"; \
	 printf "$(GREEN)[report]$(RESET) $(BOLD)+$(RESET) $$REPORT\n"; \
	 printf "$(GREEN)[report]$(RESET) $(BOLD)+$(RESET) $(OUTPUT_DIR)/latest -> report_$$TS.txt\n"; \
	 COUNT=$$(ls -1 $(OUTPUT_DIR)/report_*.txt 2>/dev/null | wc -l | tr -d ' '); \
	 if [ "$$COUNT" -gt "$(MAX_REPORTS)" ]; then \
	   EXCESS=$$((COUNT - $(MAX_REPORTS))); \
	   ls -1 $(OUTPUT_DIR)/report_*.txt | head -n "$$EXCESS" | while read f; do \
	     rm -f "$$f"; \
	     printf "$(YELLOW)[report]$(RESET) pruned $$f\n"; \
	   done; \
	 fi

.PHONY: diagrams
diagrams: report ## Generate Mermaid diagrams from the latest report
	@printf "$(CYAN)[diagrams]$(RESET) Generating diagram files...\n"
	$(UV) run python $(SKILL_SCRIPTS_DIR)/generate_diagrams.py --report "$(OUTPUT_DIR)/latest" --out-dir $(OUTPUT_DIR)
	@printf "$(GREEN)[diagrams]$(RESET) $(BOLD)+$(RESET) Done -> $(OUTPUT_DIR)/diagram_*.md\n"

.PHONY: inspect
inspect: stop diagrams ## Full inspection pipeline: stop server, run report + diagrams, serve, open
	@printf "$(CYAN)[inspect]$(RESET) Running inspection pipeline...\n"
	@$(MAKE) serve
	@$(MAKE) open


##@ Local Server

.PHONY: serve
serve: ## Start HTTP server in background (PORT=8008)
	@if [ -f "$(SERVER_PID_FILE)" ] && kill -0 $$(cat $(SERVER_PID_FILE)) 2>/dev/null; then \
		printf "$(YELLOW)[serve]$(RESET) Server already running (pid $$(cat $(SERVER_PID_FILE)))\n"; \
	else \
		$(WATCHMEDO) auto-restart \
			--patterns="$(OUTPUT_DIR)/*.md" \
			--recursive \
			--debounce-interval=0.5 \
			-- python3 -c "import http.server, os; os.chdir('$(SKILL_DIR)'); \
			httpd = http.server.HTTPServer(('0.0.0.0', $(PORT)), http.server.SimpleHTTPRequestHandler); \
			print('Serving HTTP on $(INSPECTOR_URL)'); httpd.serve_forever()" \
			>/dev/null 2>&1 & \
		echo $$! > $(SERVER_PID_FILE); \
		printf "$(GREEN)[serve]$(RESET) Server started on $(INSPECTOR_URL) (pid $$(cat $(SERVER_PID_FILE)))\n"; \
	fi

.PHONY: stop
stop: ## Stop the background HTTP server
	@if [ -f "$(SERVER_PID_FILE)" ] && kill -0 $$(cat $(SERVER_PID_FILE)) 2>/dev/null; then \
		kill $$(cat $(SERVER_PID_FILE)) && rm -f $(SERVER_PID_FILE); \
		kill $$(lsof -ti :$(PORT)) 2>/dev/null || true; \
		printf "$(GREEN)[stop]$(RESET) Server stopped\n"; \
	else \
		rm -f $(SERVER_PID_FILE); \
		printf "$(YELLOW)[stop]$(RESET) No server running\n"; \
	fi

.PHONY: open
open: serve ## Open the report viewer in the default browser (cache-busted URL)
	@if [ ! -f "$(INSPECTOR_HTML)" ]; then printf "$(RED)Error:$(RESET) $(INSPECTOR_HTML) not found\n"; exit 1; fi
	@/bin/cp $(INSPECTOR_HTML) index.html
	@CB=$$(date +%s); \
	 REPORT_TS=$$(readlink "$(OUTPUT_DIR)/latest" 2>/dev/null | sed 's/report_//;s/\.txt//'); \
	 URL="$(INSPECTOR_URL)/$(INSPECTOR_HTML)?v=$$CB&r=$$REPORT_TS"; \
	 printf "$(CYAN)[open]$(RESET) Opening $$URL...\n"; \
	 if command -v open &>/dev/null; then open "$$URL"; \
	 elif command -v xdg-open &>/dev/null; then xdg-open "$$URL"; \
	 else printf "$(YELLOW)Open manually:$(RESET) $$URL\n"; fi


##@ Deploy

.PHONY: zip-prep
zip-prep: ## Copy distributable files to ZIP_DIR (../zipped/inspect-sandbox) ready for zipping
	@printf "$(CYAN)Preparing zip staging dir:$(RESET) $(ZIP_DIR)\n"
	@/bin/rm -rf $(ZIP_DIR)
	@mkdir -p $(ZIP_DIR)
	@/bin/cp $(INSPECTOR_HTML) index.html
	@ok=0; fail=0; \
	for f in $(ZIP_FILES); do \
		if /bin/cp -R $$f $(ZIP_DIR)/ 2>/dev/null; then \
			printf "  $(GREEN)ok$(RESET)  $$f\n"; ok=$$((ok+1)); \
		else \
			printf "  $(RED)FAIL$(RESET)  $$f\n"; fail=$$((fail+1)); \
		fi \
	done; \
	/bin/rm -f index.html; \
	printf "\n  $(BOLD)$$ok copied, $$fail failed$(RESET)\n"; \
	[ $$fail -eq 0 ]


##@ Cleanup

.PHONY: clean-pyc
clean-pyc: ## Remove Python bytecode and tool caches
	@printf "$(CYAN)cleaning$(RESET) Python caches...\n"
	@find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name .mypy_cache  -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name .ruff_cache  -exec rm -rf {} + 2>/dev/null || true
	@find . -name "*.pyc" -delete 2>/dev/null || true
	@printf "  $(GREEN)ok$(RESET)\n"

.PHONY: clean-build
clean-build: ## Remove build artifacts and coverage reports
	@printf "$(CYAN)cleaning$(RESET) build artifacts...\n"
	@rm -rf uv.lock
	@rm -rf output/ *.zip .coverage inspect_sandbox.egg-info 2>/dev/null || true
	@find . -name "*.egg-info" -exec rm -rf {} + 2>/dev/null || true
	@printf "  $(GREEN)ok$(RESET)\n"

.PHONY: clean-venv
clean-venv: ## Remove Python virtual environment
	@printf "$(CYAN)cleaning$(RESET) venv...\n"
	@rm -rf $(VENV)/ 2>/dev/null || true
	@printf "  $(GREEN)ok$(RESET)\n"

.PHONY: clean
clean: clean-pyc clean-build ## Remove common artifacts (pyc, build, output)

.PHONY: distclean
distclean: clean clean-venv ## Full reset -- removes venv and all build artifacts
