# Checks and publishing for the Digin install repository. Nothing here runs on GitHub Actions.

CHART         := charts/digin
CHART_REPO    := oci://ghcr.io/arlintdev/charts
DIST          := dist
TEST_VALUES   := $(wildcard $(CHART)/ci/*-values.yaml)
CHART_VERSION := $(shell sed -n 's/^version: *//p' $(CHART)/Chart.yaml)

.PHONY: help lint compose-check package publish clean

help: ## This list
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

lint: ## helm lint and helm template the chart with each set of test values in charts/digin/ci, then check the compose file
	@set -e; for v in $(TEST_VALUES); do \
	  echo "== $$v"; \
	  helm lint --strict $(CHART) -f $$v; \
	  helm template digin $(CHART) -f $$v >/dev/null; \
	done
	@echo "== defaults: must refuse, since publicUrl and a sign-in are required"; \
	if helm template digin $(CHART) >/dev/null 2>&1; then echo "the chart rendered with no publicUrl" >&2; exit 1; fi
	@$(MAKE) --no-print-directory compose-check

compose-check: ## docker compose config on compose/, with .env.example for its settings
	cd compose && docker compose --env-file .env.example config -q
	cd compose && docker compose --env-file .env.example --profile scan config -q

package: lint ## The chart as dist/digin-<version>.tgz
	@mkdir -p $(DIST)
	helm package $(CHART) -d $(DIST)

publish: ## helm package, then helm push to oci://ghcr.io/arlintdev/charts: make publish VERSION=x.y.z (after helm registry login ghcr.io)
	@test -n "$(VERSION)" || { echo "usage: make publish VERSION=x.y.z (the chart's version; Chart.yaml says $(CHART_VERSION))" >&2; exit 1; }
	@test "$(VERSION)" = "$(CHART_VERSION)" || { echo "VERSION=$(VERSION) but Chart.yaml says version: $(CHART_VERSION); move Chart.yaml first" >&2; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "the working tree has changes; commit them first" >&2; exit 1; }
	@$(MAKE) --no-print-directory package
	helm push $(DIST)/digin-$(VERSION).tgz $(CHART_REPO)

clean: ## Remove the packaged charts
	rm -f $(DIST)/digin-*.tgz
