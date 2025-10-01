.PHONY: validate validate-yaml validate-fields validate-data

validate: validate-yaml validate-fields validate-data

validate-yaml:
	yamllint .

validate-fields:
	./scripts/validate-release-fields.sh

validate-data:
	./scripts/validate-release-data.sh
