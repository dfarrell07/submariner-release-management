.PHONY: help test test-remote validate-yaml validate-fields validate-data validate-references validate-bundle-images validate-cve-fixes validate-markdown gitlint shellcheck apply watch configure-downstream add-fbc-ocp-version create-fbc-releases create-component-release update-version-labels rpm-lockfile-update setup-entitlements check-entitlements seal-entitlements test-setup-entitlements tekton-task-refs-update cve-fixes-update add-release-notes review-release-notes verify-cve-fixes konflux-component-setup konflux-bundle-setup bundle-image-update get-fbc-urls create-release-tracker test-tracker test-autorelease test-conductor test-component test-tekton test-cve test-bundle test-drift test-prod-bundle test-fbc-scope test-fbc-snapshot test-parallel test-parse-ec-log test-deny-rules test-version-bump test-skills test-release-root test-add-team-member test-release-note-review

.DEFAULT_GOAL := help

# Shellcheck configuration
SHELLCHECK_ARGS += $(shell [ ! -d scripts ] || find scripts -type f -exec awk 'FNR == 1 && /sh$$/ { print FILENAME }' {} +)
export SHELLCHECK_ARGS

help:
	@echo "Available targets:"
	@echo ""
	@echo "Release Creation:"
	@echo "  make configure-downstream VERSION=..."
	@echo "                         - Configure Konflux for new Submariner Y-stream version"
	@echo "                           Creates overlays, tenant config, and RPAs in konflux-release-data repo"
	@echo "                           Example: make configure-downstream VERSION=0.24"
	@echo "  make add-fbc-ocp-version OCP_VERSION=... [MIN_SUPPORTED_SUB=...] [PHASE=plan]"
	@echo "                         - Add FBC support for new OCP version in Konflux release data"
	@echo "                           Creates overlays, tenant config, and RPA entries"
	@echo "                           Example: make add-fbc-ocp-version OCP_VERSION=5.0 MIN_SUPPORTED_SUB=0.24"
	@echo "                           PHASE=verify-live also takes EXPECTED_COMMIT=<40-char merged SHA> and,"
	@echo "                           for OCP 5+, EXPECTED_LIFECYCLE=<path to reviewed lifecycle.json>"
	@echo "  make create-fbc-releases VERSION=... [TYPE=stage|prod]"
	@echo "                         - Create FBC releases for applicable OCP versions (requires oc login)"
	@echo "                           Default TYPE is stage if not specified"
	@echo "                           Example: make create-fbc-releases VERSION=0.22.1"
	@echo "                           Example: make create-fbc-releases VERSION=0.22.1 TYPE=prod"
	@echo "  make create-component-release VERSION=... [TYPE=stage|prod]"
	@echo "                         - Create component release (requires oc login)"
	@echo "                           Default TYPE is stage if not specified"
	@echo "                           Example: make create-component-release VERSION=0.22.1"
	@echo "                           Example: make create-component-release VERSION=0.22.1 TYPE=prod"
	@echo "  make update-version-labels VERSION=... [REPO=...]"
	@echo "                         - Update component version labels for a Z-stream release"
	@echo "                           REPO optional (defaults to all component repos)"
	@echo "                           Example: make update-version-labels VERSION=0.23.1"
	@echo "                           Example: make update-version-labels VERSION=0.23.1 REPO=subctl"
	@echo "  make rpm-lockfile-update [BRANCH=...] [REPO=...|COMPONENT=...]"
	@echo "                         - Update RPM lockfiles across Submariner repos"
	@echo "                           Example: make rpm-lockfile-update"
	@echo "                           Example: make rpm-lockfile-update COMPONENT=gateway"
	@echo "                           Example: make rpm-lockfile-update BRANCH=0.21 COMPONENT=gateway"
	@echo "  make setup-entitlements - Guided one-time setup for RPM entitlements + registry login (FORCE=1 to re-register)"
	@echo "  make check-entitlements - Check that setup is done (no changes made)"
	@echo "  make seal-entitlements  - (key holder) Seal the shared credentials into secrets/entitlements.asc"
	@echo "  make tekton-task-refs-update VERSION=... [REPO=...]"
	@echo "                         - Bump .tekton task references across component + FBC repos"
	@echo "                           REPO optional (defaults to all: 5 components + fbc)"
	@echo "                           Example: make tekton-task-refs-update VERSION=0.23.1"
	@echo "                           Example: make tekton-task-refs-update VERSION=0.23.1 REPO=fbc"
	@echo "  make cve-fixes-update VERSION=... [REPO=...]"
	@echo "                         - Fix Go-dependency CVEs across the 7 Go repos (shipyard cve-fix skill)"
	@echo "                           REPO optional (defaults to all 7); never pushes — prints PR commands"
	@echo "                           Example: make cve-fixes-update VERSION=0.23.1"
	@echo "                           Example: make cve-fixes-update VERSION=0.23.1 REPO=submariner"
	@echo "  make add-release-notes VERSION=... [STAGE_YAML=...]"
	@echo "                         - Auto-apply ALL filtered release notes to stage YAML and commit"
	@echo "                           Then run the add-release-notes skill for active-agent review"
	@echo "                           Example: make add-release-notes VERSION=0.22.1"
	@echo "                           Example: make add-release-notes VERSION=0.22.1 STAGE_YAML=releases/0.22/stage/submariner-0-22-1-stage-20260316-01.yaml"
	@echo "  make review-release-notes VERSION=... [STAGE_YAML=...]"
	@echo "                         - Prepare evidence bundles for active-agent review"
	@echo "                           Prints the run directory and deterministic apply command"
	@echo "                           Example: make review-release-notes VERSION=0.22.1"
	@echo "  make verify-cve-fixes STAGE_YAML=..."
	@echo "                         - Verify CVE fixes in snapshot images via Clair reports (requires oc login)"
	@echo "                           Reports which CVEs are actually fixed (absent in Clair) vs still present"
	@echo "                           Run automatically by 'make add-release-notes' - manual use for re-verification"
	@echo "                           Example: make verify-cve-fixes STAGE_YAML=releases/0.22/stage/submariner-0-22-1-stage-20260316-01.yaml"
	@echo "  make konflux-component-setup [REPO=...] [COMPONENT=...] [VERSION=...]"
	@echo "                         - Setup Konflux CI/CD for component on new release branch"
	@echo "                           Configures Tekton pipelines, Dockerfiles, hermetic builds, multi-platform"
	@echo "                           All parameters optional (auto-detected from current branch)"
	@echo "                           Example: make konflux-component-setup REPO=operator VERSION=0.23"
	@echo "                           Example: make konflux-component-setup REPO=submariner COMPONENT=submariner-gateway VERSION=0.23"
	@echo "  make konflux-bundle-setup VERSION=..."
	@echo "                         - Setup Konflux CI/CD for bundle on new release branch"
	@echo "                           Configures Tekton pipelines, OLM annotations, hermetic builds, multi-platform"
	@echo "                           Example: make konflux-bundle-setup VERSION=0.23"
	@echo "  make bundle-image-update [VERSION=...] [SNAPSHOT=...]"
	@echo "                         - Update bundle component image SHAs from Konflux snapshots"
	@echo "                           VERSION auto-detected from branch if not specified"
	@echo "                           Example: make bundle-image-update"
	@echo "                           Example: make bundle-image-update VERSION=0.21.2"
	@echo "                           Example: make bundle-image-update VERSION=0.21.2 SNAPSHOT=submariner-0-21-xxxxx"
	@echo ""
	@echo "Validation:"
	@echo "  make test              - Run local validations (no cluster access needed)"
	@echo "  make test-remote       - Run all validations including cluster checks, bundle images, and CVE verification (requires oc login)"
	@echo "  make validate-yaml     - YAML syntax only"
	@echo "  make validate-fields   - Release CRD fields only"
	@echo "  make validate-data     - Data formats only"
	@echo "  make validate-markdown - Markdown linting (docs)"
	@echo "  make gitlint           - Commit message linting"
	@echo "  make shellcheck        - Shell script linting"
	@echo "  make test-tracker      - Jira tracker library tests"
	@echo "  make test-drift        - Tracker-vs-reality drift detection tests"
	@echo "  make test-prod-bundle  - Prod-bundle shipped-check (tag-scheme) tests"
	@echo "  make test-fbc-scope    - FBC per-release OCP-scope derivation tests"
	@echo "  make test-skills       - Shared Claude/Codex skill compatibility contract"
	@echo "  make test-release-root - Delegate working-directory independence"
	@echo "  make test-add-team-member - Team RBAC update tests"
	@echo "  make test-release-note-review - Host-neutral issue review tests"
	@echo ""
	@echo "Release Operations:"
	@echo "  make apply FILE=...    - Validate and apply release YAML to cluster (requires oc login)"
	@echo "  make watch NAME=...    - Watch release status (requires oc login)"
	@echo "  make create-release-tracker VERSION=... [QE_ASSIGNEE=...]"
	@echo "                         - Create Jira release tracker with subtasks per workflow step"
	@echo "                           Creates parent Task + 15-18 Sub-tasks in ACM project"
	@echo "                           Example: make create-release-tracker VERSION=0.24.0"
	@echo "                           Example: make create-release-tracker VERSION=0.24.0 QE_ASSIGNEE=qe@redhat.com"
	@echo "  make get-fbc-urls VERSION=... [OCP=4.XX] [RAW_URL=true] [PROD_INDEX=true]"
	@echo "                         - Get FBC catalog URLs for QE sharing"
	@echo "                           Default: quay.io catalog URLs (Release CRs + snapshot fallback)"
	@echo "                           PROD_INDEX=true: prod operator index URLs at registry.redhat.io"
	@echo "                           Example: make get-fbc-urls VERSION=0.24.0"
	@echo "                           Example: make get-fbc-urls VERSION=0.24.0 OCP=4.21 RAW_URL=true"
	@echo "                           Example: make get-fbc-urls VERSION=0.24.0 PROD_INDEX=true"

configure-downstream:
	@test -n "$(VERSION)" || (echo "ERROR: VERSION parameter required. Usage: make configure-downstream VERSION=0.24" && exit 1)
	./scripts/configure-downstream.sh $(VERSION)

add-fbc-ocp-version:
	@test -n "$(OCP_VERSION)" || (echo "OCP_VERSION required (example: 5.0)"; exit 1)
	./scripts/add-fbc-ocp-version.sh "$(OCP_VERSION)" $(if $(MIN_SUB),"$(MIN_SUB)") $(if $(MIN_SUPPORTED_SUB),--min-supported-sub "$(MIN_SUPPORTED_SUB)") --phase "$(if $(PHASE),$(PHASE),plan)" $(if $(WORKSPACE),--workspace "$(WORKSPACE)") $(if $(RELEASE_DATA_REPO),--release-data-repo "$(RELEASE_DATA_REPO)") $(if $(FBC_REPO),--fbc-repo "$(FBC_REPO)") $(if $(RELEASE_DATA_REF),--release-data-ref "$(RELEASE_DATA_REF)") $(if $(FBC_REF),--fbc-ref "$(FBC_REF)") $(if $(BASE_REF),--base "$(BASE_REF)") $(if $(OVERLAY_PREVIOUS),--overlay-previous "$(OVERLAY_PREVIOUS)") $(if $(PIPELINE_PREVIOUS),--pipeline-previous "$(PIPELINE_PREVIOUS)") $(if $(BASE_IMAGE),--base-image "$(BASE_IMAGE)") $(if $(KUSTOMIZE),--kustomize "$(KUSTOMIZE)") $(if $(EXPECTED_COMMIT),--expected-commit "$(EXPECTED_COMMIT)") $(if $(EXPECTED_LIFECYCLE),--expected-lifecycle "$(EXPECTED_LIFECYCLE)")

.PHONY: test-fbc-onboarding
test-fbc-onboarding:
	python3 -m unittest discover -s scripts/tests -p 'test_fbc_*.py'

create-fbc-releases:
	@test -n "$(VERSION)" || (echo "ERROR: VERSION parameter required. Usage: make create-fbc-releases VERSION=0.22.1 [TYPE=stage|prod]" && exit 1)
	./scripts/create-fbc-releases.sh "$(VERSION)" "$(if $(TYPE),$(TYPE),stage)" $(if $(OCP),--ocp "$(OCP)")

create-component-release:
	@test -n "$(VERSION)" || (echo "ERROR: VERSION parameter required. Usage: make create-component-release VERSION=0.22.1 [TYPE=stage|prod]" && exit 1)
	./scripts/create-component-release.sh $(VERSION) $(if $(TYPE),$(TYPE),stage)

update-version-labels:
	@test -n "$(VERSION)" || (echo "ERROR: VERSION required. Usage: make update-version-labels VERSION=0.23.1 [REPO=subctl]" && exit 1)
	./scripts/update-version-labels.sh $(VERSION) $(if $(REPO),$(REPO),)

rpm-lockfile-update:
	./scripts/rpm-lockfile-update.sh $(BRANCH) $(if $(REPO),$(REPO),$(COMPONENT))

setup-entitlements:
	./scripts/setup-entitlements.sh $(if $(FORCE),--force,)

check-entitlements:
	./scripts/setup-entitlements.sh --check

seal-entitlements:
	./scripts/seal-entitlements.sh $(if $(NEW_PASSWORD),--new-password,)

tekton-task-refs-update:
	@test -n "$(VERSION)" || (echo "ERROR: VERSION required. Usage: make tekton-task-refs-update VERSION=0.23.1 [REPO=fbc]" && exit 1)
	./scripts/tekton-task-refs-update.sh $(VERSION) $(if $(REPO),$(REPO),)

cve-fixes-update:
	@test -n "$(VERSION)" || (echo "ERROR: VERSION required. Usage: make cve-fixes-update VERSION=0.23.1 [REPO=submariner]" && exit 1)
	./scripts/cve-fixes-update.sh $(VERSION) $(if $(REPO),$(REPO),)

add-release-notes:
	@test -n "$(VERSION)" || (echo "ERROR: VERSION parameter required. Usage: make add-release-notes VERSION=0.22.1 [STAGE_YAML=...]" && exit 1)
	@./scripts/add-release-notes.sh $(VERSION) $(if $(STAGE_YAML),--stage-yaml $(STAGE_YAML),)

review-release-notes:
	@test -n "$(VERSION)" || (echo "ERROR: VERSION parameter required. Usage: make review-release-notes VERSION=0.22.1 [STAGE_YAML=...]" && exit 1)
	@./scripts/release-notes/review.sh $(VERSION) $(if $(STAGE_YAML),--stage-yaml $(STAGE_YAML),)

verify-cve-fixes:
	@test -n "$(STAGE_YAML)" || (echo "ERROR: STAGE_YAML parameter required. Usage: make verify-cve-fixes STAGE_YAML=releases/0.22/stage/..." && exit 1)
	@test -f "$(STAGE_YAML)" || (echo "ERROR: File '$(STAGE_YAML)' not found" && exit 1)
	@./scripts/release-notes/verify-cve-fixes.sh $(STAGE_YAML)

konflux-component-setup:
	./scripts/konflux-component-setup.sh $(REPO) $(COMPONENT) $(VERSION)

konflux-bundle-setup:
	@test -n "$(VERSION)" || (echo "ERROR: VERSION parameter required. Usage: make konflux-bundle-setup VERSION=0.23" && exit 1)
	./scripts/konflux-bundle-setup.sh $(VERSION)

bundle-image-update:
	./scripts/bundle-image-update.sh $(VERSION) $(if $(SNAPSHOT),--snapshot $(SNAPSHOT),)

get-fbc-urls:
	@test -n "$(VERSION)" || (echo "ERROR: VERSION parameter required. Usage: make get-fbc-urls VERSION=0.24.0 [OCP=4.21] [RAW_URL=true] [PROD_INDEX=true]" && exit 1)
	./scripts/get-fbc-urls.sh $(VERSION) $(if $(OCP),--ocp $(OCP),) $(if $(filter true,$(RAW_URL)),--raw-url,) $(if $(filter true,$(PROD_INDEX)),--prod-index,)

create-release-tracker:
	@test -n "$(VERSION)" || (echo "ERROR: VERSION parameter required. Usage: make create-release-tracker VERSION=0.24.0 [QE_ASSIGNEE=...]" && exit 1)
	./scripts/create-release-tracker.sh $(VERSION) $(if $(QE_ASSIGNEE),--qe-assignee $(QE_ASSIGNEE),)

test-tracker:
	./scripts/lib/test-jira-tracker.sh

test-autorelease:
	./scripts/lib/test-autorelease.sh
	./scripts/lib/test-auto-push.sh

test-conductor:
	./scripts/lib/test-conductor-integration.sh

test-component:
	./scripts/lib/test-component-release.sh

test-tekton:
	./scripts/lib/test-tekton-task-refs.sh

test-cve:
	./scripts/lib/test-cve-fixes.sh

test-bundle:
	./scripts/lib/test-bundle-image-update.sh

.PHONY: test-version-labels
test-version-labels:
	./scripts/lib/test-version-labels.sh

.PHONY: test-worktree-safety
test-worktree-safety:
	./scripts/lib/test-worktree-safety.sh

test-drift:
	./scripts/lib/test-tracker-drift.sh

test-prod-bundle:
	./scripts/lib/test-prod-bundle.sh

test-fbc-scope:
	./scripts/lib/test-fbc-scope.sh

test-fbc-snapshot:
	./scripts/lib/test-fbc-snapshot.sh

test-parallel:
	./scripts/lib/test-parallel-jobs.sh

test-setup-entitlements:
	./scripts/lib/test-setup-entitlements.sh

test-parse-ec-log:
	./scripts/lib/test-parse-ec-log.sh

test-deny-rules:
	./scripts/lib/test-deny-rules.sh

test-version-bump:
	./scripts/lib/test-tekton-version-bump.sh

test-skills:
	./scripts/lib/test-skills-compatibility.sh

test-add-team-member:
	./scripts/lib/test-add-team-member.sh

test-release-note-review:
	./scripts/release-notes/test-workflow.sh --review-contract

test-release-root:
	./scripts/lib/test-release-root.sh

test: test-fbc-onboarding validate-yaml validate-fields validate-data validate-markdown gitlint shellcheck test-skills test-release-root test-add-team-member test-release-note-review test-autorelease test-conductor test-component test-tekton test-cve test-bundle test-version-labels test-worktree-safety test-drift test-prod-bundle test-fbc-scope test-fbc-snapshot test-tracker test-parallel test-parse-ec-log test-deny-rules test-version-bump test-setup-entitlements

test-remote:
	@test -n "$(FILE)" || (echo "ERROR: FILE parameter required. Usage: make test-remote FILE=releases/..." && exit 1)
	@$(MAKE) test
	@$(MAKE) validate-references validate-bundle-images validate-cve-fixes

validate-references:
	./scripts/validate-release-references.sh $(FILE)

validate-bundle-images:
	./scripts/validate-bundle-images.sh $(FILE)

validate-cve-fixes:
	./scripts/validate-cve-fixes.sh $(FILE)

validate-yaml:
	yamllint .

validate-fields:
	./scripts/validate-release-fields.sh $(FILE)

validate-data:
	./scripts/validate-release-data.sh $(FILE)

validate-file: validate-yaml validate-fields validate-data
	@echo "File validation passed"

validate-markdown:
	npx markdownlint-cli2 "**/*.md"

gitlint:
	gitlint --commits origin/main..HEAD

shellcheck:
ifneq (,$(SHELLCHECK_ARGS))
	shellcheck -S warning $(SHELLCHECK_ARGS)
else
	@echo 'No shell scripts found to check.'
endif

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
