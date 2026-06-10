# =============================================================================
# Makefile — one-command helpers for the whole stack.
#
# Conventions:
#   - All targets read config from .env (gitignored). Copy .env.example first.
#   - Local commands use `docker compose` (v2). Same compose file as prod.
#   - `make deploy` runs over SSH against the VPS (Tailscale) defined in .env.
#
# Quick start:
#   make up                                  # bring the stack up locally
#   make import-workflow WORKFLOW=chief-of-staff.json
#   make deploy                              # ship to the VPS
#   make backup                              # dump the Postgres DB
# =============================================================================

# Load .env so VPS_SSH / VPS_PATH / POSTGRES_* are available to recipes.
# (-include => no error if .env is missing yet; targets that need it will say so.)
-include .env
export

COMPOSE := docker compose

.DEFAULT_GOAL := help

# -----------------------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# --- Lifecycle ---------------------------------------------------------------
.PHONY: up
up: ## Start the stack in the background (build/pull as needed)
	$(COMPOSE) up -d

.PHONY: down
down: ## Stop the stack (keeps volumes/data)
	$(COMPOSE) down

.PHONY: restart
restart: ## Restart all services
	$(COMPOSE) restart

.PHONY: pull
pull: ## Pull pinned images
	$(COMPOSE) pull

.PHONY: logs
logs: ## Tail logs (Ctrl-C to stop)
	$(COMPOSE) logs -f --tail=100

.PHONY: ps
ps: ## Show service status
	$(COMPOSE) ps

# --- Workflows (Git is the source of truth) ----------------------------------
# Import a workflow JSON from ./workflows into n8n. Defaults to all of them.
# Single file:  make import-workflow WORKFLOW=chief-of-staff.json
WORKFLOW ?=
.PHONY: import-workflow
import-workflow: ## Import workflow JSON into n8n (WORKFLOW=file.json, or all)
ifeq ($(strip $(WORKFLOW)),)
	@echo "==> Importing ALL workflows from ./workflows"
	$(COMPOSE) exec -T n8n n8n import:workflow --separate --input=/workflows
else
	@echo "==> Importing /workflows/$(WORKFLOW)"
	$(COMPOSE) exec -T n8n n8n import:workflow --input=/workflows/$(WORKFLOW)
endif
	@echo "    Done. Open n8n and verify, then re-attach credentials if prompted."

# Export all workflows from n8n back into ./workflows so Git stays authoritative.
# n8n strips secrets on export — exported JSON is safe to commit.
.PHONY: export-workflows
export-workflows: ## Export all workflows from n8n into ./workflows (secret-free)
	$(COMPOSE) exec -T n8n n8n export:workflow --backup --output=/workflows
	@echo "    Exported. Review the diff, then commit ./workflows/*.json"

# --- Backup ------------------------------------------------------------------
# Timestamped pg_dump into ./backups (gitignored). Restore manually with psql.
.PHONY: backup
backup: ## Dump the Postgres DB to ./backups/<timestamp>.sql.gz
	@mkdir -p backups
	@ts=$$(date +%Y%m%d-%H%M%S); \
	echo "==> Dumping database '$(POSTGRES_DB)' to backups/$$ts.sql.gz"; \
	$(COMPOSE) exec -T postgres pg_dump -U "$(POSTGRES_USER)" "$(POSTGRES_DB)" \
		| gzip > "backups/$$ts.sql.gz"; \
	echo "    Wrote backups/$$ts.sql.gz"

# --- Deploy ------------------------------------------------------------------
# Ship to the VPS over SSH (Tailscale). Pulls latest Git + pinned images and
# restarts the stack. Assumes the repo is already cloned at $(VPS_PATH) and
# the VPS has its OWN .env (with prod secrets) — secrets are never sent here.
.PHONY: deploy
deploy: ## Deploy to the VPS: git pull + compose pull + up -d (over SSH)
	@test -n "$(VPS_SSH)"  || { echo "Set VPS_SSH in .env"; exit 1; }
	@test -n "$(VPS_PATH)" || { echo "Set VPS_PATH in .env"; exit 1; }
	@echo "==> Deploying to $(VPS_SSH):$(VPS_PATH)"
	ssh $(VPS_SSH) 'cd $(VPS_PATH) && git pull --ff-only && docker compose pull && docker compose up -d'
	@echo "    Deployed. Check: ssh $(VPS_SSH) 'cd $(VPS_PATH) && docker compose ps'"

# --- Local TLS convenience ---------------------------------------------------
# Trust Caddy's internal CA so https://n8n.localhost has no browser warning.
.PHONY: trust-local-cert
trust-local-cert: ## (macOS) Trust Caddy's local CA for n8n.localhost
	$(COMPOSE) cp caddy:/data/caddy/pki/authorities/local/root.crt /tmp/caddy-local-ca.crt
	sudo security add-trusted-cert -d -r trustRoot \
		-k /Library/Keychains/System.keychain /tmp/caddy-local-ca.crt
	@echo "    Trusted. Restart your browser."
