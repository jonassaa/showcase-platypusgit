# A thin wrapper over the pnpm scripts, for the muscle memory of everyone who
# types `make` before they think. Every target delegates; none of them owns any
# logic, so there is nothing here that can drift out of step with package.json.

PNPM ?= pnpm

.DEFAULT_GOAL := help
.PHONY: help install dev build test fmt clean docker

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

install: ## Install dependencies exactly as the lockfile says
	$(PNPM) install --frozen-lockfile

dev: ## Start the dev server on http://localhost:5173
	$(PNPM) dev

build: ## Typecheck, then produce dist/
	$(PNPM) build

test: ## Run the suite once
	$(PNPM) test

fmt: ## Rewrite every file Prettier owns
	$(PNPM) format

clean: ## Remove build output and caches, keep node_modules
	rm -rf dist coverage .vite

docker: ## Build and run the dev server in a container
	docker compose up --build
