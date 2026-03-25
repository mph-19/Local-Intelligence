# Local Intelligence — common operations
#
# Run `make` or `make help` to see available targets.

.DEFAULT_GOAL := help
COMPOSE := docker compose

# ── Core ─────────────────────────────────────────────────────────────

.PHONY: up
up: init ## Start all services (uses profile from .env)
	$(COMPOSE) up -d

.PHONY: down
down: ## Stop all services
	$(COMPOSE) down

.PHONY: restart
restart: ## Restart all services
	$(COMPOSE) restart

.PHONY: build
build: ## Build/rebuild all images (sequentially to avoid OOM)
	$(COMPOSE) build falcon3
	$(COMPOSE) build qwen
	$(COMPOSE) build orchestrator

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

# ── Monitoring ───────────────────────────────────────────────────────

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
	@curl -s http://localhost:$${ORCHESTRATOR_PORT:-8081}/v1/chat/completions \
		-H "Content-Type: application/json" \
		-d "{\"model\":\"local-intelligence\",\"messages\":[{\"role\":\"user\",\"content\":\"$${Q:-Hello, what can you help me with?}\"}],\"max_tokens\":200}" \
		| python3 -m json.tool 2>/dev/null \
		|| echo "Orchestrator not responding. Run: make up"

# ── Maintenance ─────────────────────────────────────────────────────

.PHONY: check-updates
check-updates: ## Check all pinned dependencies for available updates
	@bash scripts/check-updates.sh

.PHONY: test
test: ## Build and run a quick smoke test (health checks all services)
	$(COMPOSE) build
	$(COMPOSE) up -d
	@echo "Waiting for services to start..."
	@sleep 10
	@$(MAKE) health
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
