.PHONY: validate validate-yaml validate-fields validate-data validate-references

validate: validate-yaml validate-fields validate-data

validate-references:
	./scripts/validate-release-references.sh

validate-yaml:
	yamllint .

validate-fields:
	./scripts/validate-release-fields.sh

validate-data:
	./scripts/validate-release-data.sh
