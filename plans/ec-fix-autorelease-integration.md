<!-- markdownlint-disable MD013 -->

# EC remediation: delivered integration and remaining scope

Checked October 7, 2026. Task-version remediation, log parsing and conductor `ecFixes` wiring are implemented.
The [original integration design](https://github.com/stolostron/submariner-release-management/blob/96e1d91bdb4e3082e21036d60ba0805f38d1f931/plans/ec-fix-autorelease-integration.md) is retained in Git; its proposed components and example commands are historical.
Current source and tests define behavior.

| Contract | Source |
| --- | --- |
| Task-version/SHA updates, per-repository branches, downloaded-log diagnosis and review handoff | [tekton-task-version-bump.sh](../scripts/tekton-task-version-bump.sh) |
| EC violations, affected tasks/components, deny reasons and truncated-report limits | [parse-ec-log.sh](../scripts/lib/parse-ec-log.sh) |
| Active/future deny checks and constrained catalog replacements | [deny-rules.sh](../scripts/lib/deny-rules.sh) |
| Step script, review level and external verification | [jira-tracker.sh](../scripts/lib/jira-tracker.sh), [autorelease.sh](../scripts/autorelease.sh) |

The task-bump script exits 0 when commits were made, 1 on a hard failure or remaining active denial, and 2 when no update is possible and a manual handoff is needed.
Parser output is diagnosis, not proof of a passing EC result. A truncated report cannot establish clean coverage;
a minimum-version denial may be repaired by a qualifying bump, while a whole-catalog denial needs its specified replacement or manual disposition.
An unavailable policy read remains unchecked. Review-stop push/PR attempts require explicit authorization for normal conductor execution.

Focused verification: `make test-version-bump test-parse-ec-log test-deny-rules test-tekton test-conductor`.
Offline assertions cover implementation contracts; they do not establish the selected release snapshot's hosted EC result.

Remaining work is [konflux-ci-fix execution portability](claude-codex-skill-compatibility.md#phase-5-make-konflux-ci-fix-host-neutral-without-narrowing-it),
[current FBC recovery](fbc-failure-recovery.md) and the [conductor's source risks](autorelease-step-automation.md#source-risks-requiring-a-focused-follow-up).
The broader CI skill supports PR/branch/repository diagnosis; replacing it with the task-bump helper would narrow its existing scope.
Do not create another EC implementation story or revive the delivered design as an active backlog.
