# Local Intelligence — common operations
#
# Run `make` or `make help` to see available targets.

.DEFAULT_GOAL := help
COMPOSE := docker compose

# ── Core ─────────────────────────────────────────────────────────────

.PHONY: up
up: init check-ports ## Start all services (uses profile from .env)
	$(COMPOSE) up -d

.PHONY: down
down: ## Stop all services
	$(COMPOSE) down

.PHONY: restart
restart: ## Restart all services
	$(COMPOSE) restart

.PHONY: build
build: ## Build images for the active profile (sequentially to avoid OOM)
	@. ./.env 2>/dev/null; \
	export COMPOSE_BAKE=false; \
	profile="$${COMPOSE_PROFILES:-cpu}"; \
	echo "Building for profile: $$profile"; \
	case "$$profile" in \
		cpu) \
			echo "  -> falcon3 (10B)"; $(COMPOSE) build falcon3; \
			;; \
		minimal) \
			echo "  -> falcon3-mini (3B)"; $(COMPOSE) build falcon3-mini; \
			;; \
		gpu) \
			echo "  -> qwen"; $(COMPOSE) build qwen; \
			;; \
		dual) \
			echo "  -> falcon3 (10B)"; $(COMPOSE) build falcon3; \
			echo "  -> qwen"; $(COMPOSE) build qwen; \
			;; \
		*) \
			echo "Unknown profile: $$profile"; exit 1; \
			;; \
	esac; \
	echo "  -> orchestrator"; $(COMPOSE) build orchestrator

.PHONY: pull
pull: ## Pull latest pre-built images (kiwix, open-webui)
	$(COMPOSE) pull kiwix open-webui

.PHONY: logs
logs: ## Follow logs for all services
	$(COMPOSE) logs -f

.PHONY: status
status: ## Show service status and active profile
	@. ./.env 2>/dev/null; \
	echo "Profile: $${COMPOSE_PROFILES:-cpu}  Pipeline: $${PIPELINE_MODE:-single}"; \
	echo ""
	$(COMPOSE) ps

# ── Setup ────────────────────────────────────────────────────────────

.PHONY: init
init: ## Create data directories and .env if missing
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "Created .env from .env.example — run 'make setup' to configure"; \
	fi
	@. ./.env 2>/dev/null; \
	dir=$${KNOWLEDGE_DIR:-./data/knowledge}; \
	mkdir -p "$$dir"/{zim,vectors/qdrant,docs/custom,logs}; \
	echo "Data directories ready at $$dir"

.PHONY: setup
setup: init ## Interactive setup wizard (detects hardware, picks profile)
	@bash scripts/configure.sh

# ── Ingestion ────────────────────────────────────────────────────────

.PHONY: ingest-docs
ingest-docs: ## Index local documents from KNOWLEDGE_DIR/docs/custom
	$(COMPOSE) run --rm ingest python ingest_docs.py /knowledge/docs/custom custom_docs

.PHONY: ingest-kiwix
ingest-kiwix: ## Index Kiwix articles (usage: make ingest-kiwix QUERY="python" BOOK="wikipedia")
	$(COMPOSE) run --rm ingest python ingest_kiwix.py \
		$${BOOK:-wikipedia} "$${QUERY:-python programming}" $${COLLECTION:-wikipedia}

# ── Kiwix ────────────────────────────────────────────────────────────

.PHONY: kiwix-add
kiwix-add: ## Download a ZIM and refresh Kiwix (usage: make kiwix-add URL=https://...)
	@if [ -z "$(URL)" ]; then \
		echo "Usage: make kiwix-add URL=https://download.kiwix.org/zim/.../file.zim"; \
		echo "Browse available ZIMs at https://library.kiwix.org"; \
		exit 1; \
	fi
	@. ./.env 2>/dev/null; \
	dir=$${KNOWLEDGE_DIR:-./data/knowledge}/zim; \
	mkdir -p "$$dir"; \
	echo "Downloading to $$dir ..."; \
	wget -c -P "$$dir" "$(URL)"
	@$(MAKE) kiwix-refresh

.PHONY: kiwix-refresh
kiwix-refresh: ## Rebuild Kiwix library from ZIMs on disk and restart
	$(COMPOSE) restart kiwix

.PHONY: kiwix-list
kiwix-list: ## List ZIM files currently installed
	@. ./.env 2>/dev/null; \
	dir=$${KNOWLEDGE_DIR:-./data/knowledge}/zim; \
	if ls "$$dir"/*.zim >/dev/null 2>&1; then \
		ls -lh "$$dir"/*.zim; \
	else \
		echo "No ZIM files in $$dir"; \
		echo "Add one with: make kiwix-add URL=<zim-url>"; \
	fi

# ── Monitoring ───────────────────────────────────────────────────────

.PHONY: check-ports
check-ports: ## Verify configured ports are free on the host
	@. ./.env 2>/dev/null; \
	_free() { \
		if command -v ss >/dev/null 2>&1; then \
			! ss -tlnH "sport = :$$1" 2>/dev/null | grep -q . ; \
		elif command -v lsof >/dev/null 2>&1; then \
			! lsof -iTCP:$$1 -sTCP:LISTEN >/dev/null 2>&1; \
		else return 0; fi; \
	}; \
	_chk() { \
		if _free "$$1"; then \
			echo "  [free]  $$2 = $$1"; \
		else \
			echo "  [BUSY]  $$2 = $$1  <- run 'make setup' to reassign"; \
			BUSY=1; \
		fi; \
	}; \
	BUSY=0; \
	echo "=== Port Check (profile: $${COMPOSE_PROFILES:-cpu}) ==="; \
	case "$${COMPOSE_PROFILES:-cpu}" in \
		cpu|dual|minimal) _chk "$${LLM_PORT:-8080}"          LLM_PORT ;; \
	esac; \
	case "$${COMPOSE_PROFILES:-cpu}" in \
		gpu|dual)         _chk "$${SYNTH_PORT:-8082}"         SYNTH_PORT ;; \
	esac; \
	_chk "$${ORCHESTRATOR_PORT:-8081}" ORCHESTRATOR_PORT; \
	_chk "$${KIWIX_PORT:-8888}"        KIWIX_PORT; \
	_chk "$${WEBUI_PORT:-3000}"        WEBUI_PORT; \
	if [ "$$BUSY" != 0 ]; then echo "Tip: run 'make setup' to auto-assign free ports."; fi

.PHONY: health
health: ## Check if all services are responding
	@. ./.env 2>/dev/null; \
	echo "=== Local Intelligence Health Check ==="; \
	echo "Profile: $${COMPOSE_PROFILES:-cpu}  Pipeline: $${PIPELINE_MODE:-single}"; \
	echo ""; \
	case "$${COMPOSE_PROFILES:-cpu}" in \
		cpu|dual|minimal) \
			curl -sf http://localhost:$${LLM_PORT:-8080}/v1/models >/dev/null 2>&1 \
				&& echo "  [OK]   Falcon3  :$${LLM_PORT:-8080}" \
				|| echo "  [FAIL] Falcon3  :$${LLM_PORT:-8080}" ;; \
	esac; \
	case "$${COMPOSE_PROFILES:-cpu}" in \
		gpu|dual) \
			curl -sf http://localhost:$${SYNTH_PORT:-8082}/v1/models >/dev/null 2>&1 \
				&& echo "  [OK]   Qwen     :$${SYNTH_PORT:-8082}" \
				|| echo "  [FAIL] Qwen     :$${SYNTH_PORT:-8082}" ;; \
	esac; \
	curl -sf http://localhost:$${ORCHESTRATOR_PORT:-8081}/v1/models >/dev/null 2>&1 \
		&& echo "  [OK]   Orchestr :$${ORCHESTRATOR_PORT:-8081}" \
		|| echo "  [FAIL] Orchestr :$${ORCHESTRATOR_PORT:-8081}"; \
	curl -sf http://localhost:$${KIWIX_PORT:-8888}/ >/dev/null 2>&1 \
		&& echo "  [OK]   Kiwix    :$${KIWIX_PORT:-8888}" \
		|| echo "  [FAIL] Kiwix    :$${KIWIX_PORT:-8888}"; \
	curl -sf http://localhost:$${WEBUI_PORT:-3000}/ >/dev/null 2>&1 \
		&& echo "  [OK]   WebUI    :$${WEBUI_PORT:-3000}" \
		|| echo "  [FAIL] WebUI    :$${WEBUI_PORT:-3000}"

.PHONY: chat
chat: ## Quick test chat (usage: make chat Q="What is Linux?")
	@jq -n --arg q "$${Q:-Hello, what can you help me with?}" \
		'{"model":"local-intelligence","messages":[{"role":"user","content":$$q}],"max_tokens":200}' \
		| curl -s http://localhost:$${ORCHESTRATOR_PORT:-8081}/v1/chat/completions \
			-H "Content-Type: application/json" -d @- \
		| python3 -m json.tool 2>/dev/null \
		|| echo "Orchestrator not responding. Run: make up"

# ── Maintenance ─────────────────────────────────────────────────────

.PHONY: check-updates
check-updates: ## Check all pinned dependencies for available updates
	@bash scripts/check-updates.sh

.PHONY: wait-healthy
wait-healthy: ## Poll services until all respond (timeout: WAIT_TIMEOUT, default 120s)
	@. ./.env 2>/dev/null; \
	timeout=$${WAIT_TIMEOUT:-120}; elapsed=0; interval=5; \
	_up() { curl -sf "$$1" >/dev/null 2>&1; }; \
	_all() { \
		case "$${COMPOSE_PROFILES:-cpu}" in \
			cpu|dual|minimal) _up "http://localhost:$${LLM_PORT:-8080}/v1/models" || return 1;; \
		esac; \
		case "$${COMPOSE_PROFILES:-cpu}" in \
			gpu|dual) _up "http://localhost:$${SYNTH_PORT:-8082}/v1/models" || return 1;; \
		esac; \
		_up "http://localhost:$${ORCHESTRATOR_PORT:-8081}/v1/models" || return 1; \
		_up "http://localhost:$${KIWIX_PORT:-8888}/" || return 1; \
		_up "http://localhost:$${WEBUI_PORT:-3000}/" || return 1; \
	}; \
	_show() { if _up "$$1"; then echo "  [OK]   $$2"; else echo "  [FAIL] $$2"; fi; }; \
	echo "Waiting for services (timeout: $${timeout}s)..."; \
	while [ $$elapsed -lt $$timeout ]; do \
		if _all; then echo "All services healthy ($${elapsed}s)"; exit 0; fi; \
		sleep $$interval; elapsed=$$((elapsed + interval)); \
		echo "  $${elapsed}s / $${timeout}s ..."; \
	done; \
	echo "Timeout after $${timeout}s — status:"; \
	case "$${COMPOSE_PROFILES:-cpu}" in \
		cpu|dual|minimal) _show "http://localhost:$${LLM_PORT:-8080}/v1/models" "Falcon3  :$${LLM_PORT:-8080}";; \
	esac; \
	case "$${COMPOSE_PROFILES:-cpu}" in \
		gpu|dual) _show "http://localhost:$${SYNTH_PORT:-8082}/v1/models" "Qwen     :$${SYNTH_PORT:-8082}";; \
	esac; \
	_show "http://localhost:$${ORCHESTRATOR_PORT:-8081}/v1/models" "Orchestr :$${ORCHESTRATOR_PORT:-8081}"; \
	_show "http://localhost:$${KIWIX_PORT:-8888}/" "Kiwix    :$${KIWIX_PORT:-8888}"; \
	_show "http://localhost:$${WEBUI_PORT:-3000}/" "WebUI    :$${WEBUI_PORT:-3000}"; \
	exit 1

.PHONY: test
test: ## Build and run a quick smoke test (health checks all services)
	$(COMPOSE) build
	$(COMPOSE) up -d
	@$(MAKE) wait-healthy
	@echo ""
	@echo "Smoke test: sending test query..."
	@$(MAKE) chat Q="What is 2+2?" || true
	@echo ""
	@echo "Test complete. Run 'make down' to stop services."

# ── Cleanup ──────────────────────────────────────────────────────────

.PHONY: clean
clean: ## Stop services and remove images (keeps data)
	$(COMPOSE) down --rmi local

.PHONY: clean-all
clean-all: ## Stop services, remove images AND data volumes
	$(COMPOSE) down --rmi local -v
	@echo "WARNING: webui-data volume removed. Knowledge dir untouched."

# ── Help ─────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "Local Intelligence — available commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Profiles (set in .env or via make setup):"
	@echo "  cpu       Falcon3 10B, CPU only (default)"
	@echo "  gpu       Qwen 3.5 9B, NVIDIA GPU"
	@echo "  dual      Falcon3 triage + Qwen synthesis"
	@echo "  minimal   Falcon3 3B, low RAM (<8 GB)"
	@echo ""
