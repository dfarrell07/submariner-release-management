.PHONY: help test test-remote validate-yaml validate-fields validate-data validate-references validate-bundle-images apply watch

.DEFAULT_GOAL := help

help:
	@echo "Available targets:"
	@echo "  make test            - Run local validations (no cluster access needed)"
	@echo "  make test-remote     - Run all validations including cluster checks and bundle images (requires oc login)"
	@echo "  make apply FILE=...  - Validate and apply release YAML to cluster (requires oc login)"
	@echo "  make watch NAME=...  - Watch release status (requires oc login)"
	@echo "  make validate-yaml   - YAML syntax only"
	@echo "  make validate-fields - Release CRD fields only"
	@echo "  make validate-data   - Data formats only"

test: validate-yaml validate-fields validate-data

test-remote: test validate-references validate-bundle-images

validate-references:
	./scripts/validate-release-references.sh

validate-bundle-images:
	./scripts/validate-bundle-images.sh

validate-yaml:
	yamllint .

validate-fields:
	./scripts/validate-release-fields.sh

validate-data:
	./scripts/validate-release-data.sh

apply: test-remote
	@test -n "$(FILE)" || (echo "ERROR: FILE parameter required. Usage: make apply FILE=releases/0.20/stage/..." && exit 1)
	@test -f "$(FILE)" || (echo "ERROR: File '$(FILE)' not found" && exit 1)
	oc apply -n submariner-tenant -f "$(FILE)"

watch:
	@test -n "$(NAME)" || (echo "ERROR: NAME parameter required. Usage: make watch NAME=submariner-0-20-2-stage-..." && exit 1)
	@echo "Watching Release '$(NAME)' in submariner-tenant namespace..."
	@echo "Press Ctrl+C to exit"
	@echo ""
	@while true; do \
		clear; \
		echo "=== Release Status ==="; \
		oc get release "$(NAME)" -n submariner-tenant -o yaml | yq '.status' 2>/dev/null || echo "No status yet"; \
		echo ""; \
		echo "=== Latest Conditions ==="; \
		oc get release "$(NAME)" -n submariner-tenant -o json 2>/dev/null | jq -r '.status.conditions[]? | "\(.lastTransitionTime) \(.type): \(.status) - \(.reason): \(.message)"' | tail -5 || echo "No conditions yet"; \
		echo ""; \
		echo "=== Release Pipeline ==="; \
		PIPELINE_RUN_FULL=$$(oc get release "$(NAME)" -n submariner-tenant -o jsonpath='{.status.managedProcessing.pipelineRun}' 2>/dev/null); \
		if [ -n "$$PIPELINE_RUN_FULL" ]; then \
			echo "PipelineRun: $$PIPELINE_RUN_FULL"; \
			START_TIME=$$(oc get release "$(NAME)" -n submariner-tenant -o jsonpath='{.status.managedProcessing.startTime}' 2>/dev/null); \
			echo "Started: $$START_TIME"; \
			RELEASE_STATUS=$$(oc get release "$(NAME)" -n submariner-tenant -o json 2>/dev/null | jq -r '.status.conditions[] | select(.type == "Released") | .reason' 2>/dev/null); \
			if [ "$$RELEASE_STATUS" = "Succeeded" ]; then \
				echo "Status: Succeeded"; \
			elif [ "$$RELEASE_STATUS" = "Failed" ]; then \
				echo "Status: Failed"; \
				FAILURE_MSG=$$(oc get release "$(NAME)" -n submariner-tenant -o json 2>/dev/null | jq -r '.status.conditions[] | select(.type == "Released") | .message' 2>/dev/null); \
				echo "Message: $$FAILURE_MSG"; \
			else \
				echo "Status: Running"; \
			fi; \
		else \
			echo "No pipeline run yet"; \
		fi; \
		echo ""; \
		echo "Last updated: $$(date)"; \
		sleep 5; \
	done
