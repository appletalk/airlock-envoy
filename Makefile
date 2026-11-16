# airlock-envoy: make install for this host; make check before a commit. See README.md.
.DEFAULT_GOAL := help

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}'

install: ## everything for this host, step by step (asks before each; YES=1: no questions): Envoy at ENVOY_VERSION, the service
	@YES="$(YES)" bash install/install-all.sh

check: ## shellcheck + the site-file parser tests (no Envoy, no root); test/run-all.sh runs everything (podman)
	@bash test/lint.sh
	@bash test/apply-parse.sh
	@bash test/install-all.sh

.PHONY: help install check
