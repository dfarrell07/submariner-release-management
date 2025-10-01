.PHONY: help validate validate-remote validate-yaml validate-fields validate-data validate-references

help:
	@echo "Available targets:"
	@echo "  make validate        - Run local validations (no cluster access needed)"
	@echo "  make validate-remote - Run all validations including cluster checks (requires oc login)"
	@echo "  make validate-yaml   - YAML syntax only"
	@echo "  make validate-fields - Release CRD fields only"
	@echo "  make validate-data   - Data formats only"

validate: validate-yaml validate-fields validate-data

validate-remote: validate validate-references

validate-references:
	./scripts/validate-release-references.sh

validate-yaml:
	yamllint .

validate-fields:
	./scripts/validate-release-fields.sh

validate-data:
	./scripts/validate-release-data.sh
