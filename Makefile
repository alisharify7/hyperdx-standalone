SHELL := /bin/bash
.DEFAULT_GOAL := help

DC := docker compose --env-file .env -f compose.yaml

.PHONY: help setup up down restart pull logs ps config check status ttl manage

help: ## Show available commands
	@awk 'BEGIN {FS = ":.*## "; printf "\nUsage:\n  make <target>\n\nTargets:\n"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf "\n"

setup: ## Create config, pull image, start HyperDX, and verify it
	@./scripts/setup.sh

up: ## Start HyperDX
	@$(DC) up -d

pull: ## Pull the configured ClickStack image
	@$(DC) pull hyperdx

down: ## Stop HyperDX (persistent data is preserved)
	@$(DC) down

restart: ## Restart HyperDX
	@$(DC) restart hyperdx

logs: ## Follow HyperDX logs
	@$(DC) logs -f --tail=200 hyperdx

ps: ## Show container state
	@$(DC) ps

config: ## Validate/render Compose configuration
	@$(DC) config

check: ## Verify HyperDX and ClickHouse are responding
	@./scripts/check.sh

status: ## Show health, runtime resources, storage, tables, and TTL summary
	@./scripts/status.sh

ttl: ## Open the interactive ClickHouse TTL/retention manager
	@./scripts/ttl.sh

manage: ## Open the interactive HyperDX operations menu
	@./scripts/manage.sh
