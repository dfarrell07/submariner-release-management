<!-- markdownlint-disable MD013 -->

# Pipeline-patcher deny rules: delivered behavior

Checked October 7, 2026. A trusted task SHA can still be denied by EC policy.
[deny-rules.sh](../scripts/lib/deny-rules.sh) implements the additional policy check in both
[task-reference updates](../scripts/tekton-task-refs-update.sh) and [task-version remediation](../scripts/tekton-task-version-bump.sh).

* Read all supplied deny groups, including deprecated catalogs. Handle wildcard patterns, minimum versions and whole-catalog denials.
* Warn for future denials; a remaining active denial fails the update run.
* Repoint a moved catalog only when its own policy message identifies a replacement under `quay.io/konflux-ci/`; keep the version and let the patcher re-pin its digest.
* Treat unavailable/invalid policy data as unchecked. A successful trusted-list refresh alone is insufficient.
* Surface deny reasons in [EC log diagnosis](../scripts/lib/parse-ec-log.sh); a qualifying bump can fix a minimum-version denial, but the parser must not promise that every refresh fixes a deny rule.

Focused tests: `make test-deny-rules test-version-bump test-tekton test-parse-ec-log`.
The current [Jira payload](agentic-sdlc-jira-updates-payloads/submariner-sustenance/new-stories.md#story-2-detect-enterprise-contract-deny-rules-during-tekton-task-updates)
records the delivered scope. Current task trust and release readiness still require the selected immutable inputs and hosted results.

The [original incident/design](https://github.com/stolostron/submariner-release-management/blob/96e1d91bdb4e3082e21036d60ba0805f38d1f931/plans/pipeline-patcher-deny-rule-gap.md) remains in Git.
Its single-group scan, warn-only failure policy and proposed automatic rewrites are superseded by the implementation above;
its old PR closure suggestions are historical observations, not current actions.
