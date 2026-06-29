# =======================================================
# inspect-sandbox -- Root Makefile
# =======================================================

BOLD   := \033[1m
RED    := \033[31m
GREEN  := \033[32m
CYAN   := \033[36m
YELLOW := \033[33m
RESET  := \033[0m

MAKEFLAGS += --no-print-directory

SKILL_DIR := skills/inspect-sandbox

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

# =======================================================
# Skill Delegation - delagate to the skills Makefile
# =======================================================

.PHONY: skill
skill: ## Run a target in a specific skill (Usage: make skill name=inspect-sandbox target=help)
	@if [ -z "$(name)" ]; then echo "Error: name=... is required"; exit 1; fi
	@if [ ! -f "skills/$(name)/Makefile" ]; then echo "Error: skills/$(name)/Makefile not found"; exit 1; fi
	$(MAKE) -C skills/$(name) $(target)


.PHONY: skill-zip
skill-zip: ## Zip a skill into skills/<name>/<name>.zip, using zipped/<name>/ staging dir if zip-prep exists (Usage: make skill-zip name=inspect-sandbox)
	@if [ -z "$(name)" ]; then echo "Error: name=... is required"; exit 1; fi
	@if [ ! -d "skills/$(name)" ]; then echo "Error: skills/$(name) not found"; exit 1; fi
	@if grep -q '^zip-prep:' skills/$(name)/Makefile 2>/dev/null; then \
			printf "$(CYAN)Running zip-prep$(RESET) for $(name)...\n"; \
			$(MAKE) -C skills/$(name) zip-prep; \
			printf "$(CYAN)Zipping$(RESET) skills/zipped/$(name) -> skills/$(name)/$(name).zip\n"; \
			cd skills/zipped && zip -yr ../$(name)/$(name).zip $(name)/ --exclude "$(name)/*.zip"; \
	else \
			printf "$(CYAN)Zipping$(RESET) skills/$(name) -> skills/$(name).zip\n"; \
			cd skills && zip -yr $(name).zip $(name)/ --exclude "$(name)/*.zip"; \
	fi
	@printf "$(GREEN)Written$(RESET) skills/$(name)/$(name).zip\n"

.PHONY: skill-install
skill-install: ## Copy a skill to $HOME/.claude/skills/ (Usage: make skill-install name=inspect-sandbox)
	@if [ -z "$(name)" ]; then echo "Error: name=... is required"; exit 1; fi
	@mkdir -p $(HOME)/.claude/skills/$(name)
	@cp -R skills/$(name)/* $(HOME)/.claude/skills/$(name)/
	@printf "$(GREEN)Installed skills/$(name) -> $(HOME)/.claude/skills/$(name)$(RESET)\n"

.PHONY: skill-install-local
skill-install-local: ## Copy a skill to .claude/skills/ (Usage: make skill-install-local name=inspect-sandbox)
	@if [ -z "$(name)" ]; then echo "Error: name=... is required"; exit 1; fi
	@mkdir -p .claude/skills/$(name)
	@cp -R skills/$(name)/* .claude/skills/$(name)/
	@printf "$(GREEN)Installed skills/$(name) -> .claude/skills/$(name)$(RESET)\n"

##@ Pipeline

.PHONY: inspect
inspect: ## Full inspection pipeline: stop server, run report + diagrams, serve, open
	@$(MAKE) -C $(SKILL_DIR) inspect

##@ Reports

.PHONY: report
report: ## Run sandbox_inspect.sh and write timestamped report
	@$(MAKE) -C $(SKILL_DIR) report

.PHONY: diagrams
diagrams: ## Generate Mermaid diagrams from the latest report
	@$(MAKE) -C $(SKILL_DIR) diagrams

##@ Server

.PHONY: serve
serve: ## Start HTTP server in background (PORT=8008)
	@$(MAKE) -C $(SKILL_DIR) serve

.PHONY: stop
stop: ## Stop the background HTTP server
	@$(MAKE) -C $(SKILL_DIR) stop

.PHONY: open
open: ## Open the report viewer in the default browser
	@$(MAKE) -C $(SKILL_DIR) open

##@ Skill

.PHONY: usage
usage: ## Show inspect-sandbox skill usage
	@$(MAKE) -C $(SKILL_DIR) help
