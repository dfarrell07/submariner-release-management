.PHONY: help test test-remote validate-yaml validate-fields validate-data validate-references

.DEFAULT_GOAL := help

help:
	@echo "Available targets:"
	@echo "  make test            - Run local validations (no cluster access needed)"
	@echo "  make test-remote     - Run all validations including cluster checks (requires oc login)"
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
