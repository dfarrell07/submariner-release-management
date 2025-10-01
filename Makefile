.PHONY: help test test-remote validate-yaml validate-fields validate-data validate-references apply

.DEFAULT_GOAL := help

help:
	@echo "Available targets:"
	@echo "  make test            - Run local validations (no cluster access needed)"
	@echo "  make test-remote     - Run all validations including cluster checks (requires oc login)"
	@echo "  make apply FILE=...  - Apply release YAML to cluster (requires oc login)"
	@echo "  make validate-yaml   - YAML syntax only"
	@echo "  make validate-fields - Release CRD fields only"
	@echo "  make validate-data   - Data formats only"

test: validate-yaml validate-fields validate-data

test-remote: test validate-references

validate-references:
	./scripts/validate-release-references.sh

validate-yaml:
	yamllint .

validate-fields:
	./scripts/validate-release-fields.sh

validate-data:
	./scripts/validate-release-data.sh

apply:
	@test -n "$(FILE)" || (echo "ERROR: FILE parameter required. Usage: make apply FILE=releases/0.20/stage/..." && exit 1)
	@test -f "$(FILE)" || (echo "ERROR: File '$(FILE)' not found" && exit 1)
	oc apply -n submariner-tenant -f $(FILE)
