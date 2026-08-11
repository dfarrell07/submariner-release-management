# Autorelease Step Automation Plan

Make the autorelease conductor create, track, and verify release artifacts
reliably — and stay read-only against the Konflux cluster (no `oc apply`) — so
a human can hand-drive the release with confidence. The conductor deliberately
does *not* run releases end-to-end; apply/push stay a human action (see Status).

## Status

- **Phase 1: DONE** (10 commits, 157 tests) — --complete/--refresh flags,
  STEP_ORDER reorder, gate/hint auto-verifiers
- **Push summary: DONE** — the post-chain pending-push summary is now
  step-type-aware. A `RELEASE_YAML_STEPS` map classifies componentStage,
  fbcStageReleases, componentProd, and fbcProdReleases; when one runs, the
  conductor sets `ran_release_yaml_step` and the cleanup trap prints "After
  apply/watch succeeds, re-run" instead of "After PRs merge, re-run". Both
  release-YAML scripts (create-component-release.sh, create-fbc-releases.sh)
  now append the load-bearing `make test-remote`/`make apply`/`make watch`
  commands to the push log, not just `git push`. Two independent flags are
  required, not one: a single run *could* grow the push log with BOTH a PR block
  and a release-YAML apply/watch block, so the trailer is classified by per-step
  push-log growth (`ran_pr_step` / `ran_release_yaml_step`) and emits both lines
  when both occurred. (The original concrete trigger — bundleShas auto-chaining
  straight into componentStage — was retired when Tier 2 item 5 flipped
  bundleShas to `review`; the independent-flag design is kept as the correct
  defensive shape.) Classification + trailer tests added.
- **Phase 2: DONE** (1 commit, 29 lines) — configure-downstream.sh tracker
  fix, rpm-lockfile-update.sh branch name fix, ecFixes verifier
- **Quick wins: DONE** (1 commit, 71 lines) — partial-completion bug fix,
  fbcCatalogUpdate script + STEP_SCRIPT wiring
- **tektonBundle: DONE** — wired to STEP_SCRIPT with tracker integration +
  push log
- **fbcProdUrls: DONE (verifier fixed)** — `verify_fbcProdUrls` previously
  grepped for a `bundle-v${version}` token that never exists in
  `catalog-template.yaml` (the template names entries
  `submariner.v${version}`), so it always returned 1. Fixed to locate the
  olm.bundle entry for `submariner.v${version}` and assert its image is the
  permanent `registry.redhat.io` URL rather than the temporary
  `quay.io/redhat-user-workloads` one. Verified against the real template
  (correctly flags the still-unconverted 0.20.3 as not-done and the
  converted 0.17–0.24 bundles as done). Note the step's URL conversion
  usually happens during the *next* release's FBC catalog update, so at a
  given release's end the verifier typically still reports "not done" (URL
  still quay.io) and the conductor stops with the hint — which is now
  *correct* behavior rather than a spurious always-fail.
- **Phase 3 (apply steps): SHELVED indefinitely (design decision, not a
  backlog item).** The conductor deliberately never writes to the Konflux
  cluster — no `oc apply`, ever, for the foreseeable future. Apply/watch stay
  a human action; the conductor's job is to create the artifacts, track state,
  and verify readiness so the human can apply with confidence. The Phase 3
  analysis below is retained only as a record in case that decision is ever
  revisited; it is not planned work. **The north star is no longer "run
  releases end-to-end" — it is "make the create/track/verify conductor
  trustworthy, legible, and complete enough to hand-drive."** See "Backlog:
  non-cluster improvements" for the active roadmap.
- **fbcProdUrls terminal message: DONE** — when `fbcProdUrls` is the only
  remaining incomplete step, the hint branch prints "All release steps shipped"
  (with the confirm-prod-applied caveat), points at the prod-URL conversion
  (`update-fbc-templates-prod.md`), nudges "re-run once done to close the release",
  and suppresses the misleading `Or: --complete fbcProdUrls` nudge. The conversion
  is done per-release at closeout: once the operator does it and re-runs,
  `verify_fbcProdUrls` passes → the walk reaches `all_done` → auto-close (item 9)
  resolves the tracker. See "Terminal message + closeout".
- **Linear closeout (superseded the `--final`/deferred-follow-up design): DONE** —
  an earlier design deferred the prod-URL conversion to the *next* release and
  added `--final` (for last-in-stream releases) to file a standalone Jira
  follow-up Task + mark `fbcProdUrls` complete. Per operator practice the
  conversion happens per-release at closeout (shipped → convert → done), so
  `--final`, `handle_final`, and the follow-up machinery
  (`ensure_fbc_prod_url_followup`/`find_fbc_prod_url_followup`) were removed;
  `fbcProdUrls` is just the normal final step. 10 obsolete tests dropped.
- **Release completion + `--close`: DONE** — a finished release's tracker is
  marked done via `/autorelease <ver> --close` (one-shot flag, mutually
  exclusive with `--complete`/`--refresh`/`--dry-run`). It resolves the parent
  tracker and any still-open subtasks to **Resolved** (the same terminal status
  per-step completion uses — not "Closed", so the `JIRA_STATUS_CLOSED` constant
  was dropped). Wiring reuses the previously-dead `close_release_tracker` in
  `jira-tracker.sh`. `--close` is the manual fallback for item 9's auto-close (a
  deliberate human action for when the registry probes can't confirm shipped);
  auto-close fires from the `all_done` branch once the release provably shipped.
- **Tier 0: DONE** (2 commits) — backlog items 1 (plan cites functions, not
  line numbers) and 2 (verifiers record what they verified; three dead
  staleness rules revived). Followed by an adversarial-review pass (ultracode
  workflow) that hardened the Tier-0 test coverage — see "Learnings" below.
- **Tracker auth-vs-absent fix: DONE (`0f40be4`)** — split ahead of `--dry-run`
  as its own commit (`find_release_tracker` → `return 2` on Jira query failure so
  a transient outage no longer steers the user to `/create-release-tracker`; 6
  call sites shielded with `|| true`).
- **`--dry-run` preview: DONE** — Tier 1 item 3, the flagship trust lever (an
  *approximate* offline preview, not a guarantee). Shipped as `run_dry_run` +
  `print_terminal_summary` in `scripts/autorelease.sh`, driven by the
  `_AUTORELEASE_NOFETCH` freeze on `find_next_step`'s fetch guard and a
  file-scope `declare -A step_statuses`. Verifier gate/hint steps chain
  optimistically ("chains only if it passes"); the walk is strictly read-only
  (no cluster login, no Jira writes). 40 tests in `test-autorelease.sh` cover
  the walk, side-effect classification, fetch-once freeze, bad-read refusal,
  and the read-only sentinel. Design/audit trail retained in item 3 below.
- **Preflight checks: DONE** — Tier 1 item 4. `run_preflight` prints a one-shot
  readiness report (jq/git/acli/gh/oc) on the full-run path; purely additive
  (never blocks), read-only. Turns gh-unauthed cryptic mid-run failures and
  oc-not-logged-in silent verifier stalls into one up-front `⚠` line.
- **Tier 2 item 5 (stale-bundle gate): DONE** — the `bundleShas → componentStage`
  silent auto-chain could ship a pre-rebuild (stale) bundle. Mitigated by two
  complementary levers: (1) `AUTOMATION_LEVEL["bundleShas"]` flipped `auto →
  review`, so the chain now *stops* at bundleShas for a human to confirm the
  SHA-bump PR merged and the bundle rebuilt; (2) an in-script `assert_bundle_rebuilt`
  gate in `create-component-release.sh` (stage-only) that compares the chosen
  snapshot's `submariner-bundle` image digest against the `bundleShas`-recorded
  snapshot's — equal digest means no rebuild happened → hard-STOP. The gate is
  a digest-change *proxy* (a bundle digest changes only on a rebuild; an
  unrelated intervening component push yields a new snapshot but the *same*
  bundle digest, so it can't false-pass), needs only two `oc get snapshot` reads
  (no image pull / registry auth), is strictly read-only, and *fails open* on
  any missing bookkeeping (no tracker, no recorded snapshot, unreadable digest)
  so it never blocks a legitimate run on absent data — it hard-stops only on a
  positively-detected stale bundle. 20 tests in `test-component-release.sh`
  (wired as `make test-component`), plus DR-2/DR-3 dry-run tests updated for the
  review flip. See "Learnings (Tier 2)" and "Chain hazards".
- **Tier 2 item 6 (propagation messaging): DONE** — the two ungraceful conductor
  stops when a step is blocked on an unpropagated dependency (a raw `❌ failed`
  on the failure path, and the opaque "ran but didn't mark complete" on the
  same-step guard) now name the likely cause. A new `print_propagation_note`
  helper reads the failing step's immediate `STEP_DEPENDENCIES` and prints a
  conditional "make sure the changes from `<dep>` are pushed, merged, and rebuilt,
  then re-run" — appended to the failure path (no-op for dependency-less steps,
  so it never blames a phantom upstream). The same-step guard now leads with
  "ran, but isn't complete yet / its changes likely need to propagate first"
  instead of the opaque wording, keeping both the re-run and `--complete`
  manual-escape. Reuses the existing `STEP_DEPENDENCIES` map (no new map); 3
  tests in `test-autorelease.sh`. See "The propagation gap".
- **Shipped:** `cveFixes` wrapper (`scripts/cve-fixes-update.sh`) — a
  `review`-gated `run` step fanning out over the shipyard cve-fix skill; design
  and as-built record in "Future Script Candidates → cveFixes".
- **Shipped:** tracker-vs-reality drift detection (item 8) — `release-status.sh`
  now flags per-step drift in both directions via `scripts/lib/tracker-drift.sh`
  (34 tests, zero extra Jira queries, probe-failure-safe; see "Backlog → item 8").
- **Tier 3 item 9 (auto-close on shipped signal): DONE** — the conductor now
  auto-resolves the tracker from the `all_done` branch — i.e. only after *every*
  tracked step, including `fbcProdUrls` (the prod-URL FBC conversion), is complete,
  so the prod-URL step always precedes the epic close — once the release is
  *provably* shipped. Registry-only (no `oc login`) and probe-failure-safe, with
  `--close` retained as the manual fallback. Signal: the prod component bundle is
  live (cheap `prod_bundle_shipped` gate) AND every in-scope OCP operator index
  lists `bundle-v$VERSION.{json,yaml}`. Shipped across three libs:
  `index_lists_bundle` (pure) + `prod_index_has_bundle` (I/O,
  `present`/`absent`/`unreachable`) in `scripts/lib/prod-bundle.sh`;
  `get_fbc_ocp_scope` (pure per-release OCP-scope derivation) in the new
  `scripts/lib/fbc-scope.sh`; and `auto_close_verdict` (pure) + `try_auto_close`
  (I/O, cheap-gate-first) called from the `autorelease.sh` `all_done` branch.
  Verdict is `close` iff bundle-shipped AND scope>0 AND every
  in-scope index present — any `unreachable`/`absent`/empty-scope only *suppresses*
  auto-close (never mis-fires; `--close` still works). Also fixed a latent
  `SCRIPT_DIR`-clobber sourcing bug (libs reset `SCRIPT_DIR`, so autorelease.sh
  now captures `_LIB_DIR` before sourcing). 10 tests added (5 `index_lists_bundle`,
  5 `auto_close_verdict`) + the new `test-fbc-scope.sh` (5), all in `make test`;
  verified live (0.22.1 closes; 0.24.0/0.24.1 correctly skip).
- **tektonComponents: DONE (item 7)** — `scripts/tekton-component-setup.sh` fans out
  over all 8 (repo, component) pairs, best-effort fetch (yubikey-safe), follows the
  version-labels fan-out template, tracker integration, AUTORELEASE_PUSH_LOG entries.
  Conductor now classifies tektonComponents as `run (auto)` — chains straight into
  tektonBundle on success. All 20 plan steps are now scripted or have verifiers.

### Learnings (Tier 0 + adversarial review)

Captured from implementing items 1-2 and the review pass over them, so the same
ground isn't re-litigated when Tier 1 lands:

- **Verifier failure contract needs *two* assertions.** A verifier must
  `return 1` *before* any stdout on failure, because the gate|hint auto-verify
  path captures stdout as STEP_DATA. A test that only checks the exit code lets
  a verifier that prints-then-fails slip through (the caller would record
  partial garbage as the snapshot). Every verifier failure test now asserts
  *both* exit `1` *and* empty stdout. This is the single most load-bearing
  invariant the review surfaced.
- **Mutation-verify every new test.** For each new test, deliberately break the
  code it covers and confirm the test fails, then revert. Two mutations were
  run (drop `verify_createBranches`'s `return 1`; drop the snapshot-rule clause
  in `handle_step_override`) — both caught — before trusting the tests.
- **ecFixes is first-pass-stale but reconcilable.** `verify_ecFixes` completes
  *before* `bundleShas` picks the shipping snapshot, so its recorded snapshot
  reads stale until re-verified (via `--refresh` or the next auto-verify pass,
  which lands on the new `bundleShas` snapshot). This is expected, not a bug —
  documented so a future reader doesn't "fix" it into re-running EC needlessly.
- **Staleness is display-only, and must stay that way.** `check_freshness`
  feeds `get_release_summary` only; `find_next_step` dispatches on
  `.status == complete` alone. Reviving the staleness rules changed *reporting*,
  never the walk — no new re-run or `oc apply` risk. Any Tier 1+ work that
  touches staleness must preserve this separation.
- **gitlint discipline.** Commit-body lines must be ≤80 chars (B1); title ≤72
  (T1). Commit via `git commit --no-verify -s -F <file>` (message file, not
  `-m`, to avoid zsh backtick garbling). Reflow the file before committing.

### Learnings (Tier 1: `--dry-run` + preflight)

Captured from implementing items 3-4 and their review passes:

- **A simulation mirrors the dispatch predicate; it does not re-run it.**
  `--dry-run` chains a gate iff a `STEP_VERIFIER` *exists* (labeled "chains only
  if it passes"), mirroring `try_auto_verify`'s exists-*and*-passes without the
  `oc login`. **Arm ordering is load-bearing:** the terminal-step check must
  precede the verifier arm, or `fbcProdUrls` (whose verifier fails by design at
  release end) gets optimistically chained into a false "nothing left."
- **Freeze, don't re-fetch, to simulate.** `_AUTORELEASE_NOFETCH` plus a
  file-scope `declare -A step_statuses` let dry-run fetch tracker state once,
  then re-walk the DAG in memory. The array *must* be declared `-A` at file
  scope (outside the `_AUTORELEASE_TESTING` guard) or `set -u` aborts on the
  first string-key write from the one-shot dispatch block.
- **Shared terminal wording lives in one function.** `print_terminal_summary`
  was extracted from the loop so the live run and dry-run can never diverge;
  defined outside the testing guard so tests call it directly.
- **Accepted dry-run gap (not fixed).** If the walk crosses a verifier gate
  *and then* reaches the terminal/all-done arm, the "earliest possible stop (if
  `<verifier>` fails)" note is dropped (the epilogue is gated on a non-terminal
  stop). Only reachable via non-monotonic tracker state (a manual `--complete`
  hole where an early verifier is incomplete but downstream steps are done);
  unreachable under in-order completion. Guarding it adds branches for a state
  that can't occur naturally — loses on simple-first.
- **Additive features have two contracts to test: never-blocks and read-only.**
  Preflight *never blocks* — every probe sits in an `if`/`elif` condition so
  `set -e` can't abort, plus an explicit `return 0`; the all-creds-fail test
  pins this. That non-blocking property is exactly what lets it ship *before*
  item 5's gate (which *can* hard-block). Both dry-run and preflight also assert
  read-only by redefining a write function to touch a sentinel and checking it
  stays clean. Placed before the push-log `mktemp` so a Ctrl-C during a network
  probe leaves no temp file. *(Coverage gap accepted: the "tool not found"
  branches aren't unit-testable without shadowing `command` itself.)*
- **Reused cred probes carry a known fragility.** Preflight copies
  `create-release-tracker.sh`'s `acli jira auth status | grep -qi
  "authenticated\|Logged in"`. That grep is substring-fragile — an *unauthed*
  message containing "logged in" would false-positive — but it is proven
  against real `acli` output and kept for consistency. **Possible hardening
  (both call sites):** key off `acli`'s exit code rather than grepping text.
  Under `set -euo pipefail` the `acli | grep -q` pipe is safe in practice
  (tiny output → no SIGPIPE before grep matches), as the shipped tracker
  probe demonstrates.
- **Glyph alignment beats glyph consistency.** The readiness report uses plain
  `⚠` (not the emoji `⚠️` used once elsewhere) so it column-aligns with the
  plain `✓`; the emoji's variation-selector width would misalign the columns.
  Clarity/UX outranks bare consistency here.

### Learnings (Tier 2: stale-bundle gate)

Captured from implementing item 5, the first hard-blocking gate:

- **A digest-change proxy beat the "obvious" full comparison.** The thorough
  option was to pull the bundle image and diff its `relatedImages` against the
  bundleShas-recorded SHAs. The chosen proxy — compare only the `submariner-bundle`
  *image* digest of the chosen vs recorded snapshot — is simpler *and* just as
  robust for the one realistic false-pass: an unrelated component push makes a
  new snapshot but does **not** rebuild the bundle, so its bundle digest stays
  equal to the stale recorded one and the gate still stops. Simpler-and-robust
  won over thorough-but-heavier. Explicitly covered by the "stale unrelated
  newer snapshot" test.
- **A hard gate must fail open on absent bookkeeping.** Every missing-data path
  (no tracker, `bundleShas` recorded no snapshot, digest unreadable/GC'd, tracker
  read error) returns 0 with a skip notice — the gate hard-stops *only* on an
  equal-and-readable digest pair. Conflating "I couldn't check" with "it's stale"
  would block legitimate runs whenever Jira blips or a snapshot is garbage-collected.
  The complementary `bundleShas → review` flip is what inserts the deterministic
  human stop; the in-script gate is the backstop for when someone overrides past it.
- **Two levers, defence in depth, not redundancy.** The `review` flip lives in
  the DAG config (`AUTOMATION_LEVEL`) and stops the *conductor*; the in-script
  assertion lives in `create-component-release.sh` and stops a *direct* `make
  create-component-release` / manual invocation that never consults the DAG. Each
  covers a path the other can't see.
- **Sourcing guard to make a main-flow script testable.** Tail changed from
  `main "$@"` to `if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then main "$@"; fi`
  so the test can source the real `assert_bundle_rebuilt`/`_bundle_digest` without
  running a release. The `:-` defaults are mandatory under `set -u`.
- **`exit` inside a gate escapes command substitution, not `set -e`.** Capturing
  `GATE_OUT=$(assert_bundle_rebuilt 2>&1) || GATE_RC=$?` runs the gate's `exit 1`
  in the subshell; the `||` catches the rc so the parent test survives. Calling
  the gate directly would abort the whole suite on the first stale case.

### Learnings (Tier 3: drift detection)

Captured from implementing item 8 and its two adversarial-review passes — the
same ground shouldn't be re-litigated by the next remote-probe feature:

- **A probe's empty output ≠ "not done."** The single most load-bearing
  correctness lesson here. `git ls-remote` / `gh api` / `oc` / `skopeo` fail
  (offline, unauthenticated, rate-limited, transient flake) for reasons
  unrelated to the thing being checked, and empty output is indistinguishable
  from genuine absence — so a status/drift tool that trusts emptiness emits
  confident, wrong conclusions (the first cut warned "tracker is stale" on a
  single `ls-remote` flake against finished work). Capture the probe's **exit
  code**, record a per-step `*_FETCH_FAILED` flag, and map it to `unknown`. Erring
  toward `unknown` only *suppresses* a warning; it never invents one. This is the
  most valuable class of defect a "review max carefully" pass finds in this repo.
- **List endpoints paginate; exact-ref lookups don't.** `gh api .../tags`
  returns only the first 30 of ~200 tags, so an existing older tag (`v0.16.8`,
  reproduced) reads as "missing" once newer tags bury it. `git ls-remote --tags
  <repo> refs/tags/v$VERSION` asks for the one ref — no pagination, no 404
  ambiguity, exit 0 whether or not it exists — so the exit code cleanly separates
  absent from unreachable. Prefer an exact-ref query over paginating a list
  whenever you're checking existence of a single known item.
- **`((x++))` aborts under `set -e` when `x` starts at 0.** The post-increment
  *returns* the pre-increment value (0 → exit status 1), which `set -e` treats as
  failure. `check_step_1`'s `((missing_count++))` was a latent abort on the first
  missing repo. Use `x=$((x + 1))` for counters in `set -e` scripts.
- **Reuse the prober's already-computed globals; re-probe nothing.** Drift
  detection reads the ground-truth globals `release-status.sh` had already set
  (`BRANCH_CHECK`, `MISSING_TEKTON`, `TAG_EXISTS`, …) and the `TRACKER_SUMMARY`
  it already fetched — zero extra Jira queries, zero duplicated "Done When" logic
  (Principle: don't duplicate `release-status.sh`). A standalone-sourceable pure
  lib (`ground_truth_done`/`classify_drift` are I/O-free) made all 34 tests
  offline. Coverage stayed deliberately narrow — only the four steps with an
  unambiguous signal are judged; everything else is `unknown` (robust > coverage).

## Backlog: non-cluster improvements (easiest first)

Apply automation is shelved (see Status). With writes to the cluster off the
table, the conductor's value comes from being *trustworthy, legible, and
complete* enough to hand-drive. Everything here is read-only against the
cluster (verifiers `oc get` at most; nothing `oc apply`s). Ordered by
effort-to-value: smallest, safest wins first. Items keep stable numbers even
though tiers group them.

1. **[Tier 0 · tiny] Plan cites functions, not line numbers — DONE for the
   conductor libs.** The `autorelease.sh`/`jira-tracker.sh` conductor references
   were converted from `file:NNN` line numbers to stable identifier names
   (`find_next_step`, `_autorelease_cleanup`, `classify_log_growth`,
   `handle_close`, etc.), permanently killing the line-ref drift for the
   conductor libs. The remaining `per-step-script.sh:NNN` citations elsewhere in
   this plan (including the "write-failure hardening" lists) are **approximate
   pointers, not exact locations** — they drift whenever those scripts are edited
   and several are already stale (e.g. `create-component-release.sh:445` now
   lands on the QE gate, not an `update_step` call). Read them as "near line N,
   verify against current source"; prefer the surrounding function/behavior
   description over the number. Converting them to stable identifiers is a
   worthwhile follow-up but out of scope here.

2. **[Tier 0 · small] Verifiers record what they verified — DONE.** Each
   verifier now emits the evidence it checked (snapshot name, git tag, bundle
   SHA) into STEP_DATA instead of `{}` (the gate|hint verifier-complete write
   carries `$vdata`, falling back to `{}` only when empty), and the two
   hand-completion write sites stamp the `bundleShas` snapshot — reviving the
   three previously-dead `STALENESS_RULES` (`ecFixes`, `qeValidation`,
   `fbcCatalogUpdate`) in the `/release-ls` reporting path. The three fixes span
   three write sites: `ecFixes` (`verify_ecFixes`, which verifies EC on the
   recorded `bundleShas` snapshot so the rule is reconcilable), `qeValidation`
   (`--complete` via `handle_step_override`), and `fbcCatalogUpdate`
   (`fbc-catalog-update.sh` via the `snapshot_step_data` helper). This enforces
   Design Principle 7 ("verifier-records-snapshot"). Staleness stays
   display-only (`get_release_summary`) until wired into `find_next_step`.

3. **[Tier 1 · flagship · DONE] `--dry-run` preview.** Answer "what would `/autorelease` do next
   and what would it write?" without executing or writing anything. Fetch real
   tracker state once, then simulate the auto-chain *in memory*: walk
   `find_next_step`, and for each would-run/auto step mark it complete in the
   file-scope `step_statuses` array (never call `update_step`) — *not* a
   `run_dry_run` local, since `find_next_step` reads the global — re-walk, and
   repeat until the first stop. Note the real conductor does not stop at *every*
   gate/hint step: the gate/hint dispatch runs the read-only `STEP_VERIFIER`
   checks and chains *past* `createBranches`, `upstreamRelease`, and `ecFixes`
   when they verify. The preview must account for this rather than silently
   predicting a stop at those steps — either invoke the read-only verifiers to
   reproduce the auto-verify-and-continue behavior, or (to keep the walk purely
   in-memory, since verifiers depend on live cluster/network state) label
   verifier-backed steps as "may auto-verify and chain" checkpoints instead of
   hard stops. Print the ordered sequence it would run plus each step's side
   effects (local commits created, Jira step writes, push-log entries).
   Read-only; reuses the existing walk. This is the defining feature for a
   conductor that will always be hand-driven: it lets an operator see the whole
   chain before committing to it. The preview is deliberately *approximate* —
   offline, it optimistically continues past verifier gates and can't see
   unpropagated deps (both disclosed inline and in the footnote) — so it is a
   high-value planning aid, not a guarantee. *Effort: medium. Value: high — the
   best pre-run visibility available now that apply is shelved.*

   **Design — reuse the walk, don't rebuild it.** The whole feature is a thin
   simulation harness around the *existing* `find_next_step` + dispatch. No
   forked walk, no duplicated jq, minimal new surface.
   - **Freeze the fetch, reuse the walk.** `find_next_step` re-fetches
     `step_statuses` from Jira every call unless `_AUTORELEASE_TESTING=true`.
     One-line guard change: also skip the fetch when `_AUTORELEASE_NOFETCH` is
     set. `run_dry_run` then calls `find_next_step` *once* normally — that reuses
     its real fetch, its acli/jq error-handling (a bad Jira read refuses the dry
     run too), and its `step_statuses` seed — then sets a **local**
     `_AUTORELEASE_NOFETCH=1` (dynamic scope makes it visible to `find_next_step`
     and auto-resets on return, so nothing leaks in tests). Every later walk runs
     against the in-memory array.
   - **Simulate, don't execute.** Loop `find_next_step`; for each result mirror
     the real `case "$NEXT_REASON"` but replace effects with a print +
     `step_statuses[$NEXT_STEP]=complete`. Use a **do-while** (process the
     already-fetched first result, then re-call) so the pre-loop seed call isn't
     redundantly re-walked:
     - `run` → mark complete; if `AUTOMATION_LEVEL[step]=review`, print and STOP
       (matches the real loop's REVIEW break); else continue. Forcing the status
       to complete makes the same-step `prev_step` guard unnecessary here.
     - `gate|hint` has **three** arms, faithful to the real dispatch
       (`autorelease.sh` gate|hint branch):
       1. `NEXT_STEP = fbcProdUrls` → print the terminal "all release steps
          shipped" block (confirm-prod-applied caveat + point at the prod-URL
          conversion + re-run-to-close nudge) and STOP. **This is the arm the
          first-draft design wrongly omitted** — `verify_fbcProdUrls` returns 1
          until the prod-URL conversion lands in the FBC template, so at release
          end the real loop *always* takes its terminal special case here, never
          `all_done`. Without this arm the sim optimistically marks fbcProdUrls
          complete and prints a misleading "all done" at exactly the closeout
          point. To avoid duplicating the prose, the static message is extracted
          into a shared, param-free helper (`print_terminal_summary`) called by
          both the real loop and `run_dry_run`; it does no Jira I/O.
       2. else **with** a `STEP_VERIFIER` → label "gate · auto-verifies via
          `<fn>` (chains only if it passes)", mark complete, continue (optimistic
          — dry-run stays offline; invoking verifiers would need `oc login` and
          defeat the quick preview). Without this, z-stream would stop at
          `upstreamRelease`/`ecFixes` and the preview is near-useless — so
          optimistic-continue-with-an-inline-conditional-label is the right UX.
       3. else (**no** verifier: `qeValidation`, `tektonComponents`) → STOP with
          the step's `STEP_SKILL_HINT`.
     - `manual` → STOP ("complete manually, then re-run"). `all_done` → "nothing
       left to run".
   - **Side effects, statically.** No execution needed — derive them from the
     maps already in play, as a **three-way** outcome matching
     `classify_log_growth`'s real domain: `RELEASE_YAML_STEPS` → "make apply/watch
     (release CR)"; a known PR-pushing run step → "git push (opens PR/MR)"; a run
     step that grows no push log → **no follow-up line**. The blanket "every run
     step pushes" is wrong: `releaseNotes` (`add-release-notes.sh`) edits notes
     in-repo and self-completes without ever writing `AUTORELEASE_PUSH_LOG` — it
     is the only one of the wired run scripts that grows no log, so
     `classify_log_growth` returns "" and the real conductor prints no trailer
     for it. Predict a follow-up only for `RELEASE_YAML_STEPS` and the PR-pushing
     scripts; emit no `→ then:` line otherwise. (Revisit the classification if
     another no-artifact run step is ever wired.)
   - **Output (UX).** Header names version/type/tracker and states plainly "no
     scripts run, nothing written." The completed steps print for free (the
     first `find_next_step` call echoes `✓ <title>: done` before
     `_AUTORELEASE_QUIET` is set). Then a numbered "Would run next" list — each
     `run` step shows the **exact script invocation** and its side effect on the
     next line (transparency > brevity); verify-backed steps appear in-chain,
     optimistically continued, labeled with their verifier fn. Close with one
     `Stops at: <title> — <reason>` line (reason = the step's `STEP_SKILL_HINT`
     or "review the output") and a footnote disclosing the offline sim's two
     over-predictions: (a) verify/gate steps proceed only if their live check
     passes, and (b) run steps whose deps aren't pushed/merged/rebuilt yet may
     stall at a propagation gap the offline walk can't see (the real loop's
     same-step "ran but didn't mark complete" guard). The optimism is stated
     **structurally** — inline `(chains only if it passes)` on verify steps —
     not by footnote alone, so numbered steps don't read as promises. Example
     (mid-release resume):

     ```text
     Dry run: Submariner 0.25.1 (z-stream) · tracker ACM-1234
     No scripts run, nothing written to Jira.

       ✓ RPM lockfile updates: done
       ✓ Version label updates: done
       ✓ Tekton task updates: done
       ✓ CVE fixes: done
       ✓ EC compliance fixes: done

     Would run next:
       1. Cut upstream release
            gate · auto-verifies via verify_upstreamRelease (chains only if it passes)
       2. Update bundle SHAs
            run: scripts/bundle-image-update.sh 0.25.1
            → then: git push (opens PR/MR)
       3. Component stage release
            run: scripts/create-component-release.sh 0.25.1 stage
            → then: make apply/watch (release CR)
       4. Release notes
            run: scripts/add-release-notes.sh 0.25.1

     Earliest possible stop (if verify_upstreamRelease fails): Cut upstream release
     Otherwise stops at: Release notes — review the output, then re-run /autorelease 0.25.1
     Note: run steps assume their inputs are already pushed/merged/rebuilt; if not,
           the real run stops earlier.
     ```

     **Why five `✓ done` lines, not two.** Between `versionLabels` and
     `upstreamRelease` in `STEP_ORDER` sit `tektonTasks` (run, auto — chains),
     `cveFixes` (run at `review` — runs, then *stops*), and `ecFixes`
     (`hint`, *has* a verifier — chains conditionally). A seed of only
     `rpmLockfiles`+`versionLabels` therefore runs `tektonTasks`, then runs
     `cveFixes` and stops at its review stop; it never reaches `upstreamRelease`.
     To illustrate a verifier gate chaining conditionally (the whole point of the
     example) the resume point must have `tektonTasks`, `cveFixes`, and `ecFixes`
     already complete.
     `releaseNotes` shows no `→ then:` line because `add-release-notes.sh` edits
     notes in-repo and self-completes — it never grows the push log (the sole run
     step that doesn't; see "Side effects, statically").

     Side effect per run step follows `classify_log_growth`'s three-way domain:
     `RELEASE_YAML_STEPS` → "make apply/watch (release CR)"; a PR-pushing script →
     "git push (opens PR/MR)"; a no-log-growth script (`releaseNotes`) → no
     follow-up line. A run step at `AUTOMATION_LEVEL=review` is the stop point
     (it runs, then the real loop breaks) — shown in the list, named in the
     `Stops at` line. **End-of-release shape:** when only `fbcProdUrls` remains,
     the preview prints the terminal "all release steps shipped" block
     (confirm-prod-applied caveat + point-at-conversion + re-run-to-close nudge),
     never "all done" — see the `fbcProdUrls` arm above.

   - **Flag wiring.** `--dry-run` (bool), mutually exclusive with the one-shot
     mutators (add to `_action_count`); dispatched **with** the
     `--complete`/`--refresh` one-shot block (which each `exit` after
     running) — after `TRACKER` is resolved but **before** the header echo and the
     `AUTORELEASE_PUSH_LOG` mktemp/trap setup, not "right before the real loop."
     Placing it after push-log setup would create a temp file and arm the EXIT
     trap during a "nothing written" preview and would falsify the REFUTED
     push-log finding below (which relies on dry-run exiting before push-log
     setup). `run_dry_run` defined outside the testing guard so tests call it
     directly.
   - **Never** calls `update_step`, `handle_step_override`, any per-step script,
     or any verifier.
   - **Tests.** Pre-seed `step_statuses` under `_AUTORELEASE_TESTING`, call
     `run_dry_run`, assert the printed sequence + stop reason for:
     - fresh z-stream (empty) → runs rpmLockfiles + versionLabels + tektonTasks +
       cveFixes, STOPS at `cveFixes` (run at `review`);
     - mid-chain resume (seed through `ecFixes` — i.e. rpmLockfiles, versionLabels,
       tektonTasks, cveFixes, ecFixes all complete, the example's 5-step seed;
       seeding only through versionLabels would run tektonTasks + cveFixes and stop
       at `cveFixes`, the case above) → `upstreamRelease` shown "chains only if it passes" and the walk
       CONTINUES past it → STOPS at `bundleShas` (review run) — the flagship case
       proving a verifier gate is conditional-not-hard-stop AND a review run stops.
       (A separate seed through `bundleShas` then verifies the post-review chain
       componentStage → STOPS at `releaseNotes`; the two seeds bracket the
       item-5 review flip.)
     - `fbcProdUrls` terminal (seed all complete except fbcProdUrls) → prints the
       "all release steps shipped" + re-run-to-close block; assert it does NOT
       print "all done" and does NOT emit the generic `--complete` hint nudge;
     - genuinely all done (seed everything) → "nothing left to run";
     - **strictly read-only** → redefine the *write* functions dry-run could
       reach — `update_step` and all four `verify_*` (`verify_createBranches`,
       `verify_upstreamRelease`, `verify_ecFixes`, `verify_fbcProdUrls`) — each to
       `touch "$SENTINEL"` then fail; assert no sentinel written. Run on **two**
       seeds (mid-chain resume **and** the `fbcProdUrls`-terminal). Drop the
       earlier "every `STEP_SCRIPT` path" clause: those are script *files* dry-run
       never execs, not shell functions you can redefine;
     - side-effect classification → componentStage/fbcStageReleases show
       "make apply/watch (release CR)"; bundleShas shows "git push (opens PR/MR)";
       `releaseNotes` shows **no** `→ then:` line (no push-log growth — the sole
       wired run step with no follow-up trailer).

     Mutation-verify each per the Learnings above.

   **Robustness audit (12-lens adversarial workflow, 25 confirmed findings).**
   The settled design above is sound but under-specified in ways that either
   break `make test` or crash under `set -u`. Fold these in before coding;
   estimate rises to ~135 LOC (growth is correctness, not scope). Two findings
   were **REFUTED** and need no change: the `AUTORELEASE_PUSH_LOG` unbound-var
   scare (dispatch `exit 0`s before push-log setup) and the one-shot write
   path (the `_action_count` guard blocks a write flag combined with `--dry-run`).

   - **Must-fix or the build breaks:**
     - `print_terminal_summary` (the shared terminal helper) MUST be defined
       *outside* the `_AUTORELEASE_TESTING` main guard, next to `find_next_step`
       / `run_dry_run`. It is extracted from code currently *inside* that guard;
       left there, every dry-run test calls an undefined function → `set -e`
       abort → `make test` fails. **Highest priority.**
     - `DRY_RUN=""` in the arg-init block (beside the other action-flag vars).
       Without it, `_action_count`/dispatch read an unset var under `set -u` and
       **every non-dry-run invocation aborts**.
     - `declare -A step_statuses` at file scope (beside `NEXT_STEP`/`NEXT_REASON`,
       *outside* the `_AUTORELEASE_TESTING` main guard). Today it is first
       declared `-A` inside that guard, *after* the one-shot dispatch block — but
       `run_dry_run` dispatches from that same block and writes string keys into
       it, so under `set -u` a string subscript on an array never declared `-A`
       arithmetic-evaluates an unset key and aborts. Do **not** `local -A` it in
       `run_dry_run`: `find_next_step` reads the global. All tests pass regardless
       (they set `_AUTORELEASE_TESTING`, which seeds the array first), so this
       crashes only in production — **highest priority alongside the helper**.
     - `run_dry_run` inits all accumulators empty at the top:
       `local stop="" stop_title="" first_gate="" first_gate_title=""`. The
       `all_done` and `fbcProdUrls` arms never assign them, so the happy path
       (fully-complete release) crashes the epilogue's `[ -n "$stop" ]`.
     - The general footnote is gated on `[ -n "$stop" ]` (same guard as the
       `Stops at` line), so it does **not** leak onto the `all_done` /
       `fbcProdUrls` terminals — those carry their own wording.
   - **Corrections to the settled arms:**
     - **Freeze boundary (explicit).** Shadow both flags *empty* at function top
       (`local _AUTORELEASE_NOFETCH= _AUTORELEASE_QUIET=`) so they are
       function-scoped and auto-reset on return (nothing leaks into later tests),
       call `find_next_step` once genuinely unfrozen, *then* set
       `_AUTORELEASE_NOFETCH=1 _AUTORELEASE_QUIET=true` before the re-walk. Do not
       rely on the plain "set local in step 3" ordering.
     - **`fbcProdUrls` terminal: no Jira read (linear model).** The terminal
       helper `print_terminal_summary` is **param-free** and does no Jira I/O — it
       prints the fixed "all release steps shipped" + re-run-to-close block. Dry-run
       calls it directly. (Superseded the earlier `find_fbc_prod_url_followup`
       nudge-vs-"already tracked" branch, which the linear closeout removed.) Print
       the "dry-run can't confirm conversion status" caveat from the dry-run arm
       *after* the helper returns (the general footnote is suppressed here).
     - **Gate label is conditional.** Prepend a `gate ·` marker only when
       `NEXT_REASON=gate`; `createBranches` (review) and `ecFixes` (auto) reach
       this arm as `hint`, so they print plain `auto-verifies via <fn> (chains
       only if it passes)` — matching the real loop's GATE-vs-→ split.
     - **Conditional stop line.** Record the first optimistically-passed
       verifier step; when the previewed path crossed one, print the terminal as
       conditional — `earliest possible stop (if <gate> fails): <title>` beside
       the predicted stop — so it never reads as definitive. (Fresh y-stream
       otherwise over-predicts by two steps: sim says `tektonComponents`, real
       conductor stops at `createBranches`.)
     - **Footnote discloses all optimism:** verifier gates, unpropagated deps,
       **and** that auto steps are assumed to run/succeed/self-complete (a real
       run stops earlier on script failure or missing self-completion); side
       effects are best-effort predictions.
     - **Stream + polish.** All `run_dry_run` output goes to **stderr** (matches
       `find_next_step`'s `✓` lines; `--dry-run >file` never splits). The `run:`
       line omits the trailing space when `STEP_EXTRA_ARGS` is empty.
     - **Flag arm placement.** `--dry-run) DRY_RUN=true; shift ;;` goes *before*
       the `-*)` catch-all (group it with the other action flags); the
       mutual-exclusion literal is rewritten to name `--dry-run`.
   - **Drift comments (cheap):** at the `step_statuses=()` reset — "MUST stay
     inside the fetch guard; NOFETCH/dry-run relies on preserved state to
     advance the sim"; on `run_dry_run` — "consumes-and-mutates the caller's
     global; arm (a) must precede the verifier arm because dry-run can't invoke
     `verify_fbcProdUrls`." Let the shared helper own the terminality guard via
     `${STEP_ORDER[-1]}` rather than the literal `fbcProdUrls` in two places.
   - **Split out (own commit) — DONE (`0f40be4`).** The auth-vs-absent tracker
     fix (`find_release_tracker` → `return 2` on query failure so a Jira
     auth/network blip stops steering the user to the write-action
     `/create-release-tracker`) shipped ahead of `--dry-run` as its own commit:
     separable *medium* bug, public lib contract, `|| true` on 6 call sites.
   - **Added tests (beyond the 6 above):** fetch-once/freeze transition
     (`( unset _AUTORELEASE_TESTING; … )` subshell + acli spy asserting exactly
     one fetch and the fetched state reflected — the *only* coverage of the
     NOFETCH arm, which is otherwise dead under `_AUTORELEASE_TESTING`); bad Jira
     read → `run_dry_run` exits 1, nothing ran; footnote absent on
     `all_done`/`fbcProdUrls` terminals but present on a run-stop; each `✓ done`
     line emitted at most once (guards the `_AUTORELEASE_QUIET` set-before-rewalk);
     no push-log/trailer created; `gate ·` prefix present for `upstreamRelease`,
     absent for `createBranches`/`ecFixes`; conditional-stop line on fresh
     y-stream; no trailing space on an extra-args-less `run:` line;
     the `fbcProdUrls` terminal prints the param-free "all release steps
     shipped" block with no Jira read.
     Author sentinel/`exit 1` tests via `$(...)` capture so an abort is
     contained.

4. **[Tier 1 · medium · DONE] Preflight checks.** Before the loop, verify the tools/creds the run needs
   (`acli` authed to Jira, `gh` authed, `jq`/`git` present) and print one clear
   readiness report. Today a missing/expired cred surfaces as a cryptic
   mid-run failure (or, for `oc`, a silently-failing verifier). Read-only.
   *Effort: medium. Value: turns confusing failures into one actionable
   up-front message.* **Shipped** as `run_preflight` in `scripts/autorelease.sh`,
   called on the full-run path only (after the one-shot `--flag` dispatches, so
   `--dry-run`/`--complete`/… stay fast and offline). **Purely additive: it
   never blocks** — a failed probe prints a `⚠` with the fix and the run
   proceeds (a run may not reach the tool's step; `oc`-dependent verifiers
   already fail closed). Probes reuse the existing patterns
   (`acli jira auth status` grep from `create-release-tracker.sh`,
   `gh auth status`, `oc whoami`). The `oc` line names the silent-verifier
   consequence explicitly. 14 tests in `test-autorelease.sh` cover each
   authed/unauthed arm, the never-blocks contract, and read-only.

5. **[Tier 2 · small-medium · DONE] Read-only verification gates.** Run a step's "Done When"
   *reads* (no writes) as a precondition and stop with diagnostics on failure.
   This closes the top structural hazard: a YAML-creating `auto` step
   (`componentStage`) marks itself complete on *artifact creation*, so a re-run
   before the human applies can advance to `fbcCatalogUpdate` against a bundle
   that isn't really built yet. (Sequenced after preflight (item 4) despite its
   higher effort-to-value: a gate can hard-block a legitimate run, so the purely
   additive preflight ships first — "safest first" over "highest-value first".)
   Two design points learned the hard way:
   - **Gate the consumer's precondition, not the producer's completion.** A gate
     that fires "after a step self-completes" only runs in the producing run —
     `find_next_step` skips the now-`complete` producer on the very next
     `/autorelease` invocation, so a producer-side post-completion gate *fails
     open* in the normal repeated-invocation mode. Instead, key the gate to the
     *consumer* step's precondition: verify the upstream artifact before the
     consumer runs (while the consumer is still non-`complete`). That runs on
     every invocation that would advance past the hazard.
   - **Implement as an in-script precondition assertion inside the consumer's own
     script — the only form that runs under today's dispatch.** Per "Chain
     hazards", a `STEP_VERIFIER`-style gate is *dead code* for this consumer:
     `componentStage` owns a `STEP_SCRIPT`, so `find_next_step` routes it to the
     `run` branch, which never consults `STEP_VERIFIER` (only the `gate|hint`
     branch does). So add the check as a fail-non-zero assertion at the top of
     `create-component-release.sh`. This needs no new `scripts/gates/<step>.sh`
     tree (which would contradict Design Principle 7 and add a *third* place to
     encode "Done When" beside `release-status.sh`'s `check_step_*` and the
     verifiers), and no conductor-loop change. *(A cleaner
     `STEP_VERIFIER`-on-dispatch-hook variant is possible but **deferred**: it
     requires the run-branch dispatch change that "Chain hazards" / "The dispatch
     loop is partially tested" gate behind first extracting the untested loop into a
     testable function, and it breaks the `STEP_SCRIPT ∩ STEP_VERIFIER = ∅`
     invariant.)*

   The one good gate — **before `componentStage`:** assert the chosen snapshot's
   `submariner-bundle` `relatedImages` match the `bundleShas`-recorded SHAs / the
   snapshot postdates the merge — the check that prevents a *documented* live
   wrong output (a stale pre-rebuild bundle; see "Chain hazards"). Complementary
   lever: mark `bundleShas` `review` in `AUTOMATION_LEVEL` so the human
   pushes/merges and waits for the rebuild before `componentStage` runs.

   **Do not** add a symmetric gate for the other YAML-emitting steps.
   All YAML-emitting steps are `review` (AUTOMATION_LEVEL) — `componentStage`,
   `fbcStageReleases`, `componentProd`, `fbcProdReleases` — so a human is already
   in the loop before they
   run. And `componentStage` is the sole *unverified* gap:
   `create-component-release.sh` runs `verify-component-release.sh`, which only
   confirms 9 components are present with tests passing and never validates
   bundle `relatedImages` freshness. By contrast `fbcStageReleases` runs
   `verify-fbc-release.sh` *before* generating any YAML
   (`create-fbc-releases.sh:245`), and that already asserts each releasable
   snapshot's bundle SHA matches the updated GitHub catalog (i.e. postdates
   `fbcCatalogUpdate`), plus event-type and tests; `fbcProdReleases` and
   `componentProd` reuse the stage-verified snapshot and deliberately skip
   re-verification (`create-fbc-releases.sh:234`,
   `create-component-release.sh:179-183`). Supersedes the old
   "Verification gates for completed steps" note, now that it is the primary
   robustness play rather than a Phase 3 warm-up. *Effort: small-medium (one
   in-script assertion (`componentStage`) + the `bundleShas` `review` flip; no
   conductor-loop change). Value: prevents false-positive chaining.*

   **Shipped** as `assert_bundle_rebuilt` in `create-component-release.sh`
   (called between `verify_release` and `generate_yaml` in `main`) plus the
   `AUTOMATION_LEVEL["bundleShas"]` `auto → review` flip. The predicted "compare
   `relatedImages` SHAs" check was simplified to a `submariner-bundle` *image
   digest* comparison (chosen snapshot vs `bundleShas`-recorded snapshot): a
   bundle digest changes only on a rebuild, so equal digests ⇒ no rebuild ⇒
   stale ⇒ hard-STOP, while an unrelated intervening component push (new snapshot,
   same bundle digest) is still caught rather than false-passing. Two `oc get
   snapshot` reads, no image pull, strictly read-only, stage-only, and fails open
   on any absent bookkeeping. 20 tests (`test-component-release.sh`, `make
   test-component`); dry-run tests DR-2/DR-3 updated for the review flip. See
   "Learnings (Tier 2)".

6. **[Tier 2 · medium · DONE] Graceful "not propagated yet" messaging.** When a downstream step can't
   proceed because a dependency's commits aren't pushed/merged/rebuilt yet, the
   conductor previously either hard-`exit 1`ed with a raw script failure or
   printed the confusing "ran but didn't mark complete" (see "The propagation
   gap"). Now the failure path appends a `print_propagation_note` line naming the
   failing step's immediate dependency ("make sure the changes from `<dep>` are
   pushed, merged, and rebuilt, then re-run"), and the same-step guard leads with
   the propagation cause while keeping the `--complete` manual escape. *Effort: medium. Value: removes the sharpest UX edge.*

   **Shipped** as `print_propagation_note` in `autorelease.sh` (called on the
   `run`-branch failure path) plus reworded same-step-guard messaging. The
   predicted "detect the waiting-on-propagation shape" was kept deliberately
   conservative: the conductor *cannot* reliably tell a propagation wait from a
   genuine bug at `exit 1` (the plan's own note — the proper per-failure
   classification is a per-script job, item 7), so the note is *conditional*
   ("If blocked on an earlier step, …") and gated purely on the existing
   `STEP_DEPENDENCIES` map — dependency-less steps print nothing, so it never
   falsely blames an upstream. No new map, no new state; 3 tests
   (`test-autorelease.sh`).

7. **[Tier 3 · larger] Wire the remaining manual steps.** `tektonTasks` and
   `cveFixes` are now **shipped** (scripted — see below); `tektonComponents`
   remains a hint-only stop. Explored deeply (three read-only passes over the
   conductor, `konflux-component-setup.sh`, and the cveFixes/tektonTasks tooling);
   the per-step verdicts and sequencing are below. Also add verifiers where a read
   can auto-advance a step. *Effort: larger, per-step. Value: fewer manual
   `--complete` calls.*

   **Confirmed wiring constraints (from the exploration):**
   - A step runs its `STEP_SCRIPT` **or** its `STEP_VERIFIER`, never both:
     `find_next_step` classifies gate→run→hint→manual and the `run` branch never
     consults a verifier (`autorelease.sh:259-273`, `1024`). So a scripted step
     cannot also self-verify; it must lean on a *downstream* step's verifier.
   - The conductor invokes a step script exactly once as
     `script.sh "$VERSION" $extra_args` (`autorelease.sh:1089-1094`), `$VERSION`
     being 3-segment `X.Y.Z`. Any multi-repo fan-out must live *inside* the
     script — the established template is `update-version-labels.sh` /
     `rpm-lockfile-update.sh`: an internal `REPO_ORDER` loop under
     `~/go/src/submariner-io`, commit-only (never push), UPDATED/SKIPPED/FAILED
     aggregation, tracker `in_progress`→`complete` gated on a full no-failure run,
     and push commands appended to `$AUTORELEASE_PUSH_LOG`.
   - Verifier contract (for the downstream backstop): `verify_X "$VERSION"
     "$TRACKER"`, read-only, `return 1` + empty stdout = not done, exit 0 + a
     compact `jq -cn` JSON object = done (that object becomes the STEP_DATA
     `.data` payload). Register in `STEP_VERIFIER`; the step must dispatch as
     `hint` or `gate` for it to be consulted.

   **Recommended sequencing (revises the plan's own HIGH/MEDIUM/LOW ranking):**

   - **SHIPPED — `tektonTasks` — SCRIPT, no new verifier
     (`scripts/tekton-task-refs-update.sh`).** The clean win. A
     `pipeline-patcher bump-task-refs` loop over the 5 component repos + FBC,
     following the version-labels fan-out template; the patcher library is the
     one already proven in `konflux-bundle-setup.sh:597-608`. No dedicated
     verifier needed — the **existing `verify_ecFixes`** on the downstream
     `ecFixes` step confirms the EC-pass result (`tektonTasks` → push/merge →
     rebuild → `ecFixes` auto-verifies). Both-stream. `AUTOMATION_LEVEL=auto`
     chains rpmLockfiles → versionLabels → tektonTasks, then the review stop at
     cveFixes. The script goes *beyond* the version-labels template on
     robustness (robust > consistent): it refuses a dirty tree and restores each
     repo's original ref on every exit path, so it cannot park a repo on the fix
     branch and feed the cross-step branch-misroute bug. 25 tests
     (`test-tekton-task-refs.sh`).

   - **SHIPPED — `cveFixes` — SCRIPT, `review`-gated
     (`scripts/cve-fixes-update.sh`).** Full as-built record in "Future Script
     Candidates → cveFixes" (audited 2026-08-20 against the real tooling). The two
     guards that close the cross-step branch-misroute hazard are the shipped
     `bundleShas` `assert_expected_branch` backstop *and* the wrapper restoring
     each repo's checkout after every `fix-all.sh` call — so **no change to the
     external cve-fix tooling was needed** (this retired the old "restore
     ORIGINAL_REF in the external tooling" polish item). Four audit-forced design
     points: the wrapper owns its own 7-Go-repo list and passes explicit paths (no
     `repos.yaml` — it doesn't exist in-tree), calls `fix-all.sh` per repo (never
     `make all`, which MAX-masks exit 1→2), buckets by exit code + a fix-branch
     diff → clean/UPDATED/NEEDS_REVIEW/FAILED, and **completes only when every
     repo is clean with nothing pending** (no fix awaiting a PR merge, none needing
     review, none failed — a security step's `complete` must not mean "unsure if
     CVEs remain"; `--complete cveFixes` stays the manual override). Not the
     "~25-line" loop the old draft imagined (~300 lines + 32 tests) — the extra is
     the completeness guard, checkout restore, branch-diff detection, and exit-2
     bucketing, all load-bearing. Coverage gap: the 7 Go repos only; the addon
     Go-toolchain leg stays a manual reminder.

   - **Defer: `tektonComponents` — needs rework (~200 lines), LOW / Y-stream
     only.** Not wireable today: `konflux-component-setup.sh` is
     one-component-per-call with no fan-out loop, accepts only 2-segment `X.Y`
     (the conductor passes `X.Y.Z` → it would `die "Unknown argument"`), and has
     no tracker/`$AUTORELEASE_PUSH_LOG` integration. Making it wireable means
     rebuilding it around the version-labels fan-out template (loop the 8
     (repo, component) pairs, normalize the version, add tracker gating). Y-stream
     pain only — defer until it's real.

8. **[Tier 3 · optional · DONE] Flag tracker-vs-reality drift on already-complete
   steps.** `find_next_step` skips any `complete` step forever with no
   ground-truth re-check, so "tracker says complete but the commit was reverted /
   the release was never applied" is a silent footgun in a permanently
   hand-driven flow (items #4 and #5 gate *upcoming* steps, not past ones).
   Shipped as an extension of `release-status.sh` (no new conductor `--audit`
   mode — that would duplicate the prober). As-built:
   - **New lib `scripts/lib/tracker-drift.sh`** (pure, standalone-sourceable →
     unit-testable; matches the repo's lib + `test-*.sh` convention). Three
     functions: `ground_truth_done <key>` reads the ground-truth globals
     `release-status.sh` *already* computed (`BRANCH_CHECK`, `MISSING_TEKTON`,
     `WRONG_COUNT`/`FETCH_FAILED`, `TAG_EXISTS`, plus the
     `*_FETCH_FAILED` reachability flags below) and re-probes **nothing**;
     `classify_drift` is a pure decision (tracker-ahead / reality-ahead / ok /
     skip); `print_tracker_drift <summary-json>` compares against the tracker's
     per-step `jiraStatus` and prints a drift section.
   - **Reuses `TRACKER_SUMMARY`** — the summary already fetches
     `get_release_summary` for the freshness warnings, so the drift block adds
     **zero extra Jira queries**. Sourced next to `jira-tracker.sh` (so
     `JIRA_STATUS_RESOLVED` is shared) and called right after the stale-steps line.
   - **Two directions, right severity:** `⚠️` when the tracker says complete but
     ground truth says NOT done (the footgun — reverted commit / never applied),
     `ℹ️` when ground truth is done but the tracker isn't marked (self-healing —
     the conductor re-runs it).
   - **Conservative by construction (robust > coverage):** only steps with an
     unambiguous signal are judged — `createBranches`, `tektonComponents`,
     `versionLabels` (Z-stream), `upstreamRelease`. Everything else is `unknown`,
     so drift is never claimed on a guess.
   - **Probe failure ≠ "not done" (correctness fix after review):** a GitHub probe
     failing (offline / unauthenticated / rate-limited / a transient `ls-remote`
     flake) looks *identical* to "genuinely not done" — empty output — and the
     first cut warned "tracker is stale" on a mere flake. `release-status.sh` now
     records a per-step reachability flag (`BRANCH_FETCH_FAILED`,
     `TEKTON_FETCH_FAILED`, `TAG_FETCH_FAILED`) by capturing the probe's *exit code*
     (not its empty output), and `ground_truth_done` returns `unknown` when set.
     `git ls-remote <exact-ref>` exits 0 whether or not the ref exists, so its exit
     cleanly separates absent-from-unreachable — used for both `createBranches` and
     (newly) `upstreamRelease`. The tag probe was switched off the tags-list
     endpoint, which is paginated (30/page) and reported a genuinely-existing older
     tag as missing once ~30 newer tags buried it (`v0.16.8` reproduced the false
     "not found"); the exact-ref `ls-remote` has no pagination and no 404 ambiguity.
     `.tekton` contents still 404s on genuine absence, so that one distinguishes a
     definitive `HTTP 404` (absent) from any other error (unreachable), erring
     toward `unknown` when unclear — a misread only *suppresses* a warning, never
     invents one.
   - **Deliberately excluded:** `componentProd`/`fbc*` (a missing prod bundle and an
     unreachable registry both make skopeo exit non-zero — indistinguishable, so
     "absent" can't be trusted; item #9's shipped-gate owns that probe with the
     caveat), `configureDownstream` (no-cluster fallback is ambiguous), and
     `versionLabels` on Y-stream (labels are only probed on Z-stream).
   - **Tests:** `scripts/lib/test-tracker-drift.sh` (34 tests: `ground_truth_done`
     across stream/global combos incl. each probe-failure→`unknown` guard, the
     full `classify_drift` matrix, and `print_tracker_drift` against crafted
     `get_release_summary` blobs incl. both-direction drift, agreement,
     unknown-skip, the probe-unreachable regression guard, and empty/untracked).
     Wired into `make test-drift` and the aggregate `make test`.

9. **[Tier 3 · DONE] Auto-close once the release actually shipped.** Previously
   `--close` (resolve tracker + subtasks, see Status) was the only way to close a
   tracker because the read-only conductor couldn't confirm the prod pipelines
   shipped. Now the conductor auto-resolves the tracker from the `all_done` branch
   — only after every tracked step (including the prod-URL FBC conversion) is
   complete, so the prod-URL step always precedes the epic close — on a
   probe-failure-safe ground-truth "shipped" signal, with `--close` retained as
   the manual fallback (its `handle_close` marks the seam). **This is registry-only
   (no `oc login`) — but exploration proved it was not the small wiring job the
   backlog assumed.** Findings from the 0.24 exploration (these override the
   earlier draft of this item):

   - **The component-bundle tag probe is unreliable — a pre-existing bug, not
     just an item-9 concern.** `release-status.sh:check_component_release_status`
     (~line 396) and `get-fbc-urls.sh:get_urls_from_prod_index` (~line 173) both
     probe `skopeo inspect docker://…/submariner-operator-bundle:v$VERSION` and
     assert `.Labels.version == v$VERSION`. Under the post-0.22 tag scheme this
     is wrong for `.0` releases: **there is no `vX.Y.0` tag** (0.23 and 0.24 ship
     the initial release as only `vX.Y`), and **`vX.Y` floats to the latest
     patch** (`v0.24`'s `.Labels.version` is `v0.24.1`). So `:v0.24.0` returns
     `manifest unknown` and the probe misreports a shipped `.0` prod release as
     *not shipped*. The earlier "validated against 0.24.0" claim here was
     **false** — `v0.24.0` has no registry tag.
   - **The FBC prod index is the reliable exact-version ground truth.** Inside
     `registry.redhat.io/redhat/redhat-operator-index:v4.XX`, the submariner
     package lives at `/configs/submariner/` (`package.json`,
     `channels/channel-stable-0.XX.json`, `bundles/bundle-vX.Y.Z.json`) keyed on
     **exact** `X.Y.Z`. `bundle-v0.24.0.json` **is present** in the index even
     though no `v0.24.0` *tag* exists in the bundle registry — the index entry is
     immune to the tag mess. Read it registry-only via
     `oc image extract <index-image> --path /configs/submariner/:$dir --confirm`
     (auth from `~/.docker/config.json`, **no cluster login**); it is slow (pulls
     a large catalog layer per OCP version), which is the accepted "quality first,
     just a bit slow" cost.
   - **Per-release OCP scope varies — "all 7 indexes must list it" is wrong.**
     `bundle-v0.24.1.json` is **absent from 4.18** (0.24.1 shipped but that OCP
     didn't carry it), so a blanket 7-index gate would *never fire* for any
     release that doesn't span all seven OCP versions (fails safe but useless).
     The gate must check only the OCP versions **this** release targeted — the
     `releases/fbc/4-XX/prod/` YAMLs — reusing `release-status.sh`'s existing
     FBC-scope derivation rather than reinventing it.
   - **Probe failure ≠ "not shipped"** (see [[feedback-probe-failure-not-absence]]
     and item #8): an unreachable index/registry must read `unknown`, never
     "not shipped", so a flake can only *suppress* auto-close (manual `--close`
     still works), never fire it wrongly. This is the core mis-fire risk.

   **Revised design (quality-first, robust):** the shipped signal is "for every
   in-scope OCP version, `redhat-operator-index:v4.XX` lists
   `/configs/submariner/bundles/bundle-v$VERSION.json`" — this *subsumes* the
   component-bundle check (an index entry references the bundle image by digest)
   and sidesteps the floating-tag bug entirely. Extract a shared, failure-safe
   registry-probe into `scripts/lib/` (with a `test-*.sh`, per repo convention)
   reused by `release-status.sh`; gate `close_release_tracker` in the
   `autorelease.sh` `all_done` branch (fires only once every step, including the
   prod-URL FBC conversion, is complete) on the combined positive signal.
   **Scope grew** beyond "the probe exists": new lib + per-release OCP-scope
   resolution + tests + wiring + fixing the latent `.0` tag-scheme bug in the two
   existing probes.

   **Landed (commit `130de2e`):** the `.0` tag-scheme bug fix + a reusable
   probe-failure-safe lib — `scripts/lib/prod-bundle.sh` (`bundle_shipped_verdict`
   pure/unit-tested + `prod_bundle_shipped` I/O wrapper publishing `PROD_BUNDLE_*`
   globals), now consumed by `release-status.sh` and `get-fbc-urls.sh`, with
   `scripts/lib/test-prod-bundle.sh` wired into `make test`. This confirms the
   component prod bundle is live *at release time* (its documented limitation: a
   `.0` can't be tag-confirmed once its first patch ships — the floating `vX.Y`
   moves on), and is reused as the cheap first gate below.

   **Landed (commits `33e297a` / `05a3744` / `88489a5`) — item 9 complete:**
   - **Per-OCP index-content check** (`33e297a`): `index_lists_bundle` (pure,
     unit-tested — matches `bundle-v$VERSION.{json,yaml}` exactly, no substring
     false-positive on e.g. `0.24.10`) + `prod_index_has_bundle` (I/O, echoes
     `present`/`absent`/`unreachable`) added to `scripts/lib/prod-bundle.sh`,
     reading each `redhat-operator-index:v4.XX` registry-only via `oc image
     extract` (auth from `~/.docker/config.json`, no cluster login). 5 tests.
   - **Per-release OCP-scope resolution** (`05a3744`): new
     `scripts/lib/fbc-scope.sh` with `get_fbc_ocp_scope` (pure filesystem read,
     date-window matching FBC prod YAMLs to the component prod YAML), so the gate
     checks only the OCP versions *this* release targeted. Logic parameterized
     from release-status.sh's inline `get_release_ocp_scope` (pointing that
     cluster-coupled script at the lib is a safe follow-up, deliberately deferred).
     5 tests in `test-fbc-scope.sh`, wired into `make test`.
   - **Auto-close wiring** (`88489a5`, refined): the pure `auto_close_verdict`
     plus `try_auto_close` (I/O, cheap-gate-first: `prod_bundle_shipped` before the
     expensive 7× `oc image extract`) in `autorelease.sh`. Verdict is `close` iff
     bundle-shipped AND scope>0 AND every in-scope index `present`; any
     `unreachable`/`absent`/empty-scope yields `skip` (prints the `--close`
     fallback), so a flake or partial ship can only *suppress* auto-close, never
     mis-fire. Called from the `all_done` branch — only after every tracked step
     (including `fbcProdUrls`, the prod-URL FBC conversion) is complete, so the
     prod-URL step always precedes the epic close; at the terminal seam (where
     `fbcProdUrls` is still pending) the conductor just prints the terminal summary
     and leaves the epic open. Dry-run only narrates it. Also fixed a latent
     `SCRIPT_DIR`-clobber sourcing bug (sourced libs reset `SCRIPT_DIR`;
     autorelease.sh now captures `_LIB_DIR` before sourcing all three libs). 10
     tests (5 `index_lists_bundle`, 5 `auto_close_verdict`). Verified live against
     real registries: 0.22.1 → close (bundle + indexes 4.16-4.21 present);
     0.24.0 → skip at the bundle gate (floating tag); 0.24.1 → skip at scope.
   - **Idempotency guard** (`tracker_is_open` in `jira-tracker.sh`): the `all_done`
     auto-close is gated on `tracker_is_open && try_auto_close`, so a re-run on an
     already-resolved release skips both the registry probes and the (comment-adding)
     re-close — `close_release_tracker` appends a resolution comment on every call,
     so without this guard repeated runs would spam duplicate comments and re-probe.
     `tracker_is_open` returns 0 only when it POSITIVELY reads a non-Resolved parent
     status; Resolved/absent/unparseable/unreachable all read "not open" (a flake
     can never trigger a re-comment). 6 tests in `test-jira-tracker.sh`.

   *Effort: grew from "small" to medium (new lib + scope resolution + tests +
   wiring + the latent tag-scheme and SCRIPT_DIR bugs). Value: removes the last
   manual step of a shipped release, and mis-firing is designed out — auto-close
   only ever fires on a positive, in-scope, exact-version ground-truth signal.*

## The Real Problem

The conductor automates creating release artifacts (the easy part). The
actual release happens when someone pushes commits, applies them to the
cluster, watches pipelines for 20-30 minutes, verifies success, and
retries on failure. That create-to-apply gap is the bottleneck, and the
conductor doesn't model it at all.

A Z-stream release takes 3-10 days. Script execution is ~20 minutes.
The rest:

| Time sink | Duration | Cause |
| --- | --- | --- |
| Push/PR/merge cycles | ~1 hour each | Scripts create local commits but don't push |
| Pipeline waits | 15-30 min each | Cluster rebuilds after merges and applies |
| Apply→check→retry | ~30 min each | Release pipelines, manual retry on failure |
| QE validation | 1-5 days | External team tests stage catalogs |
| Human decisions | variable | Gates where the engineer decides timing |

### What "complete" actually means

Scripts mark steps complete in Jira after creating local commits. But for
steps that modify external repos (rpmLockfiles, versionLabels, bundleShas,
configureDownstream), "complete" means "commits exist locally." The work
isn't truly done until PRs merge and Konflux rebuilds.

For release steps (componentStage, fbcStageReleases), "complete" means
"YAML file committed locally." The release hasn't happened — nobody ran
`make apply`, nobody watched the pipeline, nobody verified success.

### The missing steps

The CLAUDE.md documents 20+ steps. The DAG models 19. The apply/check
steps are folded into their create counterparts:

| CLAUDE.md | DAG step | What's missing |
| --- | --- | --- |
| Step 8: Create stage release | componentStage | — |
| Step 10: Apply stage release | (folded in) | push, apply, pipeline wait |
| Step 10b: Check stage build | (folded in) | status check, retry logic |
| Step 12: Create FBC releases | fbcStageReleases | — |
| Step 13: Apply FBC releases | (folded in) | push, 7x apply, 7x wait |
| Step 13b: Check FBC builds | (folded in) | 7x status check, retry per OCP |

Same pattern for prod (Steps 15-16b, 17-18b).

### The completion gap (SOLVED by Phase 1a)

10 of 19 steps had no way to be marked complete through the conductor.
**Fixed:** `--complete`/`--refresh` flags (Phase 1a) + auto-verifiers
for createBranches, upstreamRelease, ecFixes (Phase 1d + Phase 2b).

### The propagation gap (general form)

9 of 19 steps create local commits but mark themselves complete
immediately. Downstream steps depend on those commits being pushed,
merged, and (for some) rebuilt:

| Step | What's needed before downstream runs |
| --- | --- |
| configureDownstream | GitLab MR merge + ArgoCD sync + bot PRs created |
| rpmLockfiles | push + PR merge + Konflux rebuild |
| versionLabels | push + PR merge + Konflux rebuild |
| tektonTasks | push + PR merge + Konflux rebuild |
| tektonComponents | push + PR merge (on bot PR branches) |
| tektonBundle | push + PR merge (on bot PR branch) |
| bundleShas | push + PR merge + bundle rebuild |
| fbcCatalogUpdate | push to FBC repo + FBC rebuild |
| cveFixes | push + PR merge + Konflux rebuild before upstreamRelease is meaningful |

Note that `cveFixes` accepting its `review` stop does *not* mean the CVE fixes
are live — the fix branches still need push + PR merge + rebuild. This propagation
gap is bracketed by two human stops: `cveFixes` is a `review` step and its
downstream `upstreamRelease` is a `gate`, so the operator is prompted twice rather
than carried across the boundary silently. The `bundleShas → componentStage`
boundary was the one exception — a single `auto` handoff that crossed a rebuild
silently — until Tier 2 item 5 flipped `bundleShas` to `review` (plus an in-script
digest gate); it is now bracketed the same way (see "Chain hazards").

The conductor stops on unpropagated dependencies, but *which* mechanism
stops it depends on how the downstream script reacts — and each has its own
message (see "Propagation messaging (DONE)" below):

- If the script **exits non-zero** (the common case — e.g., a `git`/setup
  command fails because the bot PR branch isn't there yet), the conductor
  takes the `run`-branch failure path and hard-`exit 1`s with
  "❌ … failed". The same-step guard never runs.
- If the script **exits 0 without marking complete** (only reachable for
  `auto` steps — `review` steps break the loop first), `find_next_step`
  returns the same step, `prev_step` matches, and the same-step guard
  (the `run` branch) fires.

Both paths leave the user to push, wait, and re-run. The same-step guard is
*not* a reliable catch-all here — it only covers the exit-0 auto-step case
within a single run; the failure path covers the rest.

**Propagation messaging (Tier 2 item 6, DONE).** Both paths now name the
likely propagation cause instead of leaving the operator to guess:

- The **failure path** appends `print_propagation_note "$NEXT_STEP"` — a
  *conditional* line ("If blocked on an earlier step, make sure the changes
  from `<dep>` are pushed, merged, and rebuilt, then re-run") built from the
  step's immediate `STEP_DEPENDENCIES`. It is deliberately conservative: the
  conductor cannot tell a propagation wait from a genuine bug at `exit 1`
  (reliable per-failure classification is a *per-script* job — see the
  bot-PR-branch example below and item 7), so the note is hedged and only
  emitted for steps that *have* a dependency. Dependency-less steps
  (`rpmLockfiles`, `versionLabels`, `tektonTasks`, …) print nothing, so a
  genuine failure there is never mislabeled as an upstream wait.
- The **same-step guard** now leads with "ran, but isn't complete yet / its
  changes likely need to propagate first — push any commits, merge the PR(s),
  and wait for the rebuild" (the step's *own* output is what must propagate
  here), replacing the opaque "ran but didn't mark complete".

Both reuse existing maps (no new state); 3 tests in `test-autorelease.sh`.

**UX: run-branch guard offers a manual escape (DONE).** The same-step guard
(the `run` branch) prints "Re-run: /autorelease $VERSION" *and* "Or, if the
step is actually done: /autorelease $VERSION --complete $NEXT_STEP", so an
operator who knows the step is genuinely done (a script that finished its work
but couldn't record completion, or work done out-of-band) can break the loop
instead of re-running the same script into the same guard. The stop-with-hint
branches present the same escape, now branched on verifier presence: a step
with a `STEP_VERIFIER` leads with "Re-run once done" (re-running lets the
verifier detect completion and chain on) and offers `--complete` as the
fallback; a verifier-less gate/hint/manual step — which re-running can't
advance — presents `--complete` as the sole action. `--refresh` is
deliberately not suggested: it is redundant, since `find_next_step` already
re-runs any non-`complete` step on the next invocation. The *failure* path (in
the `run` branch, `exit 1`) stays "fix and re-run" with no `--complete` nudge —
offering it after a genuine failure would invite marking a broken step done —
but now also appends the conditional `print_propagation_note` line so a
propagation wait (the common cause) isn't mistaken for a bug.

Scripts should detect unpropagated dependencies explicitly:
tektonComponents should check for bot PR branches before attempting setup
(and print "waiting for bot PRs after configureDownstream merge" instead
of crashing).

### The multi-repo push problem (SOLVED by Phase 1c)

After chaining, the user had local commits scattered across 7 repos with
no summary. **Fixed:** push summary via AUTORELEASE_PUSH_LOG temp file
(Phase 1c), printed on all exit paths via EXIT trap.

## Design Principles

1. **Can it be a for-loop? Script. Does it require judgment? Agent.**

2. **Model the real work, not just the file creation.** If the release
   isn't done until a pipeline succeeds, the step isn't done until the
   pipeline succeeds.

3. **The conductor never writes to the Konflux cluster.** `oc apply` via the
   human-run Makefile `apply` target is accepted; **conductor-driven** `oc
   apply` is shelved by decision — not gated future work — for the foreseeable
   future (see Status). Apply/watch stay a human action. Git pushes are
   likewise manual by default: scripts produce reviewable commits and the
   pending-actions trailer tells the operator exactly what to push. (Auto-push
   of mechanical changes was once sketched as `--auto-push`; it does not exist
   in the code and Phase 4 is out of scope under the hand-driven direction — see
   the Phase 4 note in the roadmap tail.)

4. **The conductor must leave the user oriented.** After chaining, emit
   a summary of pending work: what to push, what to apply, what to wait
   for. The user should never have to scroll back.

5. **Priority by wall-clock impact.** Optimize for reducing total release
   duration (days), not script execution time (minutes).

6. **Idempotent scripts.** Every script must be safe to re-run. Partial
   failures leave state that re-running cleans up.

7. **Prefer verifiers over scripts.** (Added after Phase 1+2.) If a step's
   automation is a boolean check ("does X exist?", "did Y pass?"), use a
   STEP_VERIFIER function (~15 lines) instead of a STEP_SCRIPT (~80+ lines).
   Verifiers auto-complete silently; scripts need arg parsing, tracker
   integration, and error handling. ecFixes: 80-line script → 15-line
   verifier. (The shelved Phase 3 analysis reuses this pattern: polling scripts
   → verifier-based check.)

   **Caveat — verifiers and staleness pull against each other (resolved for
   verifier steps).** The auto-verify path completes a step with the evidence
   its verifier printed on stdout (`update_step ... complete "$vdata"`,
   the gate|hint verifier-complete write), falling back to `{}` only when the
   verifier emits nothing. Any step with a `snapshot` staleness rule stores its
   comparison key in `.data.snapshot`, so a verifier that emitted no snapshot
   would leave `.data.snapshot` empty and `check_freshness` would return
   `fresh` forever (`check_freshness`). **Rule:** if a step both (a) is backed
   by a verifier and (b) has a `snapshot` staleness rule, the verifier MUST
   emit `{"snapshot":"<name>"}`, not nothing — otherwise the staleness rule is
   dead on arrival. This is now satisfied for ecFixes (`verify_ecFixes` emits
   the `bundleShas` snapshot it verified EC against). It still bites Phase 3
   apply steps (see "Staleness rules for apply steps"), but the carry mechanism
   now exists, so each apply verifier need only emit its snapshot.

   This caveat is specific to `snapshot` rules. Time-based rules (`Nd`) are
   the mirror image: they need only `.timestamp` (always recorded), so `{}`
   does *not* kill them — instead they can fire *spuriously* on a step that
   is permanently done. fbcProdUrls was the cautionary example: it once carried
   a `75d` rule, and because URL conversion is a one-time permanent action, the
   rule fired spuriously 75 days after its verifier auto-completed. That rule
   was therefore *dropped* (the `STALENESS_RULES` map no longer has an
   fbcProdUrls entry — see the explanatory comment where it would sit in
   `jira-tracker.sh`). Under the linear closeout model, the conversion is done
   per-release at closeout: `verify_fbcProdUrls` self-completes the step once the
   template flips to registry.redhat.io URLs, then `all_done` auto-closes the
   tracker — no time-based rule, no follow-up ticket. Kept here as a worked
   example of why time-based rules on one-shot steps are a trap (see the `75d`
   rule decision under "Staleness in conductor").

## Phase 1: Make the conductor usable

Fix the completion gap (described above) and basic UX.

### 1a. --complete and --refresh flags

Add `--complete <step>` and `--refresh <step>` to the conductor. Both call
`update_step` — `--complete` marks a step done, `--refresh` resets it.
Same code path, different status value. `--refresh` must use
`in_progress` as the status string — the only value that both makes
`find_next_step` treat the step as not-complete AND transitions the Jira
subtask back to "In Progress" for dashboard consistency. `--refresh`
handles stage re-iteration: it re-runs *only* the one named step after a
bug fix — not the steps that follow it (see the stale-downstream caveat
below).

**Caveat — re-running a create step duplicates its YAML.** The create-*
scripts (componentStage, fbcStageReleases, etc.) name their output with a
date + sequence suffix (`...-YYYYMMDD-01.yaml`). After
`--refresh componentStage`, re-running the conductor generates a *new*
file with an incremented suffix rather than overwriting the first — leaving
two YAMLs on disk. This is intentional for genuine retries (the retry
pattern in `check-*-release.md` relies on it) but surprising when the intent
was to regenerate. The user must delete the stale file if it should not be
applied.

**Caveat — `--refresh` does not cascade to downstream steps.**
`handle_step_override` resets a single step, and
`find_next_step` skips every step already marked `complete`
(`find_next_step`) with no freshness check (`check_freshness` is never
called in the walk). So `--refresh bundleShas` re-runs bundleShas alone and
leaves componentStage, releaseNotes, fbcCatalogUpdate, and fbcStageReleases
`complete` — still referencing the *old* snapshot — with nothing to warn the
operator that those YAMLs no longer match. Today the blast radius is limited
to stale files on disk (apply is manual, Phase 3 deferred), but the operator
must `--refresh` each affected downstream step by hand. **Planned
mitigation:** after a `--refresh`, build the *inverse* adjacency of
`STEP_DEPENDENCIES` (for each step, the set of steps that list it as a
prerequisite), compute the *transitive closure* of the refreshed step's
dependents, filter to still-`complete`, and print them (e.g. "bundleShas
refreshed; likely-stale downstream: componentStage, releaseNotes,
fbcCatalogUpdate, fbcStageReleases — `--refresh` each"). Note this is an
inverse + closure traversal, **not** a forward walk of `STEP_DEPENDENCIES` —
`STEP_DEPENDENCIES` is a dependent→prerequisite map
(`STEP_DEPENDENCIES[componentStage]="bundleShas"` means componentStage depends
*on* bundleShas), so walking it forward from bundleShas yields bundleShas's own
prerequisites (the opposite direction), never its dependents. The eventual fix
is a cascading `--refresh` that resets the full downstream cone in one call. This matters
most once Phase 3 apply steps land — `--refresh componentStage` would
otherwise leave `componentStageApply` complete against the old snapshot.
Note too that `--refresh` re-applying an apply step depends on the Phase 3
park-status choice: under option (a) (routing verifier-owning steps to their
verifier on `in_progress`) a `--refresh` of an apply step would run its
status-checking verifier instead of re-applying — see "Park status must be distinct"
in Phase 3.

```text
/autorelease 0.25.1 --complete cveFixes
  → marks cveFixes complete in Jira
  → prints: "✓ CVE fixes: marked complete"

/autorelease 0.26.0 --refresh bundleShas
  → resets ONLY bundleShas to in_progress in Jira
  → next /autorelease re-runs bundleShas; downstream steps already marked
    complete are NOT re-evaluated (`find_next_step` never calls
    `check_freshness` — see "Staleness in conductor", Deferred)
```

**Implementation notes:**

- The old single-arg guard was replaced with a `while/case` flag parser
  (now the main block's arg parser). Implementation was ~30 lines (not 15)
  including arg parsing, step-key validation, and handler logic.
- The handler (`handle_step_override`) was extracted into a function
  outside the `_AUTORELEASE_TESTING` guard so the test harness can cover it
  (the main block is skipped during testing).
- `test-autorelease.sh` is now wired into `make test` (the `test:` target
  in `Makefile`).

**Validation:** `--complete` must validate the step key against
`STEP_TITLES` keys and reject unknown steps. Without this,
`--complete typoStep` silently writes a meaningless Jira comment.

**Staleness interaction:** Steps completed via `--complete` have no
`data.snapshot` field (just `{}`), so `check_freshness` with
snapshot-triggered staleness can never fire on them. If `--complete` is
used for a step that should track snapshots (e.g., ecFixes), it becomes
permanently "fresh." Fix: `--complete` should accept optional
`--snapshot <name>` to record the current snapshot, or the conductor
should query the latest snapshot and include it automatically.

### 1b. Reorder STEP_ORDER

Put script-backed Build Readiness steps before hint-only ones. 6-line
change, zero risk.

Before: `cveFixes(hint) ecFixes(hint) rpmLockfiles(script) tektonTasks(hint) versionLabels(script)`

After (now live, STEP_ORDER): `rpmLockfiles(script) versionLabels(script) tektonTasks(script) cveFixes(script) ecFixes(hint)`
(tektonTasks and cveFixes were scripted after this reorder — see item 7;
cveFixes is a `run` step at `review`, so it runs then stops. The ordering
rationale below predates that and still holds.)

All 5 steps have empty dependencies — truly independent, reorder is safe.

Ordering rationale: action steps before check steps. tektonTasks actively
bumps task refs (creates PRs). ecFixes passively checks if EC passes
(which requires tasks to be current). Running tektonTasks first means the
user pushes task-bump PRs in the same batch as lockfiles + labels. After
merge + rebuild, ecFixes auto-passes. Running ecFixes first (old proposal)
would always fail on a fresh release because tasks are stale, forcing an
extra conductor invocation.

**DAG fix (DONE):** `upstreamRelease` now depends explicitly on
`tektonComponents` and `tektonBundle` (Y-stream only — Tekton pipelines
must be configured before cutting the release), rather than relying on
STEP_ORDER position (incidental). This is safe because
`step_applies_to_release()` auto-skips the Y-stream-only steps for
Z-stream, so the extra deps are no-ops there. Live in
`STEP_DEPENDENCIES`:

```text
upstreamRelease deps: cveFixes,ecFixes,rpmLockfiles,tektonTasks,
                      versionLabels,tektonComponents,tektonBundle
```

**Y-stream serialization note:** For Y-stream, the Branch Setup step
tektonComponents blocks Build Readiness auto steps (rpmLockfiles, etc.) in
walk order, even though they're DAG-independent. tektonComponents now has a
backing `STEP_SCRIPT` (`scripts/tekton-component-setup.sh`, dispatches to `run`)
and auto-chains into tektonBundle (also `STEP_SCRIPT`, auto) which chains
straight into rpmLockfiles with no manual `--complete` needed. (tektonComponents
also carries a STEP_SKILL_HINT for the manual fallback, but it's inert when a
STEP_SCRIPT is present: the `run` branch is reached first.) This
still adds wall-clock time from the one hint stop; a parallel dispatch mode
could help but would require significant conductor changes.

Files: `scripts/lib/jira-tracker.sh` (STEP_ORDER),
`scripts/lib/test-autorelease.sh` (2 assertions: test 1 and test 10).

### 1c. Push summary after chaining

After chaining, the conductor should print a consolidated summary.

The conductor creates a temp file and exports its path as
`AUTORELEASE_PUSH_LOG`. Scripts append push/PR commands to it. The
conductor reads and prints grouped output after the loop exits. Temp
file is cleaned up on exit.

~10 lines in conductor, ~3 lines per script. Scripts run in subshells
so they can't use variables to pass data back — the temp file is the
communication channel.

**The summary must carry the load-bearing next action, which differs by
step type — a `git push` line is only correct for PR-based repo steps.**
Two shapes exist:

- **PR-based repo steps** (rpmLockfiles, cveFixes, componentSetup,
  bundleSetup, bundleShas, …): the next action is *push the branch and
  open a PR*. The `git push origin <branch>` / `gh pr create` block below
  is correct, and the trailer "After PRs merge, re-run: /autorelease" is
  the right closure.
- **Release-YAML steps in this repo** (componentStage, fbcStageReleases,
  componentProd, fbcProdReleases): there is **no PR**. The script writes a
  Release CR YAML into `releases/…` and commits it; the load-bearing next
  actions are `make apply FILE=…` and `make watch NAME=…` (optionally
  `make test-remote FILE=…` first). A summary that prints only `git push`
  for these steps hides the two commands that actually drive the release —
  the operator would push the YAML and then stall, because the conductor
  never applies CRs itself (see Principle 3, human-owned `oc apply`).

Because the closure differs, the trailer must be **step-type-aware**, not a
single hardcoded "After PRs merge, re-run" line (the conductor currently
prints that unconditionally at `_autorelease_cleanup`). Emit "After PRs merge,
re-run" only when the pending block is PR-based; for release-YAML steps emit
"After apply/watch succeeds, re-run: /autorelease $VERSION". The simplest
implementation keeps the temp-file channel but lets each script write its own
full trailer line (not just push/PR commands), so the conductor concatenates
verbatim rather than synthesizing a one-size trailer.

**DONE (implemented with a lower-risk variant).** Rather than moving the
trailer into every script, the conductor classifies steps via a
`RELEASE_YAML_STEPS` map and picks the trailer in its cleanup trap
(`ran_release_yaml_step` → "After apply/watch succeeds"; else "After PRs
merge"). Keeping it in the conductor also sidesteps a sourcing-order trap:
most push-log writers (5 of 8 — the exceptions are configure-downstream,
fbc-catalog-update, and konflux-bundle-setup, which source it earlier) source
`jira-tracker.sh` *after* their push-log write, so a shared trailer helper
could be undefined at the write site. Only the two release-YAML scripts were
edited — to append the load-bearing `make test-remote`/`make apply`/`make
watch` commands (the actual bug: they logged only `git push`). The six
PR-based scripts keep their correct `git push`/`gh pr create` blocks and the
"After PRs merge" trailer unchanged. Two independent flags are required, not
one: a single run *could* land BOTH a PR block and a release-YAML apply/watch
block in the push log, so each step's push-log growth is classified into
`ran_pr_step` / `ran_release_yaml_step`, and both trailer lines are emitted when
both kinds of work occurred. (The concrete trigger was the bundleShas →
componentStage auto-chain; Tier 2 item 5 flipped bundleShas to `review`, so the
two-flag design is now defensive rather than routinely exercised.) The
worktree/fork caveat below applies to the now-wired cveFixes, which forwards the
skill's own PR block rather than synthesizing push lines.

**This origin/same-repo/main-tree template is per-step and does not
generalize.** The `git push origin <branch>` / `gh pr create --head <branch>`
shape below assumes a step commits on a branch of `origin` in the repo's main
working tree. Steps that use a **git worktree** and/or push to a **fork** (e.g.
cveFixes, which does both — see its caveat under "Future Script Candidates")
must forward their own tool's printed PR block verbatim rather than synthesize
lines from this template, or the printed commands will target the wrong remote
and path.

```text
━━━ Pending Actions ━━━

  cd ~/go/src/submariner-io/submariner
  git push origin update-rpm-lockfiles-0.25
  gh pr create --base release-0.25 --head update-rpm-lockfiles-0.25

  cd ~/go/src/submariner-io/shipyard
  git push origin update-rpm-lockfiles-0.25
  gh pr create --base release-0.25 --head update-rpm-lockfiles-0.25

  [... more repos ...]

After PRs merge, re-run: /autorelease 0.25.1
```

### 1d. Auto-verify gate steps

With `--complete` (Phase 1a), every step CAN be marked complete manually.
Auto-verifiers make this automatic for steps whose completion is
externally detectable. They use `git ls-remote` (which needs no auth) rather
than `gh api`, so the conductor stays runnable without GitHub credentials:

- **createBranches:** `git ls-remote --heads` for each repo — if
  `release-$MAJOR_MINOR` branch exists → auto-complete
- **upstreamRelease:** `git ls-remote --tags` on `submariner-operator` — if
  `v$VERSION` tag exists → auto-complete

The conductor runs verifiers for both gate AND hint steps that have one:

```text
# Current: gate always stops, hint always stops
# New: verify first at both gate and hint dispatch points
if has_verifier → run verifier
  if verified → mark complete, continue
  else → STOP (with hint + "or: --complete <step>")
if no verifier → STOP ("use: --complete <step>")
```

~30 lines in conductor + verifier functions. createBranches is
`review`+hint (not gate), so the verifier must trigger at the hint
dispatch point too. qeValidation has no verifier — requires
`--complete qeValidation`.

**Same-step guard for verifiers:** The same-step guard (now
the `run` branch) only protects the `run)` branch. Verifiers that
auto-complete and continue the loop need their own guard — if `update_step`
fails silently (it returns 0 always via `|| true`), the next
`find_next_step` still shows the step as incomplete, the verifier runs
again, and the loop never terminates. Implemented via the `verified_steps`
associative array (checked in the `gate|hint` branch): the verifier
is skipped if already attempted this run.

## Phase 2: Bug fixes + verifiers

Phase 1 (`--complete`) makes the conductor usable. Phase 2 fixes bugs
that make it produce wrong results, and adds verifiers to eliminate
`--complete` calls where external state is checkable.

### 2a. Fix pre-existing script bugs

Two bugs in STEP_SCRIPT scripts that break the conductor on real releases:

**configure-downstream.sh has no tracker integration.** The only script
in STEP_SCRIPT that never calls update_step. The conductor runs it, it
exits 0, but no completion is recorded — same-step guard fires. Blocks
Y-stream chaining. ~11 lines: source jira-tracker.sh (hardcoded HOME
path), find_release_tracker(INPUT_VERSION), update_step in_progress
before work + complete after last commit.

**rpm-lockfile-update.sh constructs wrong branch name.** The conductor
passes 3-segment versions (0.25.1). The script constructs
`release-0.25.1` instead of `release-0.25`. Every repo is skipped
with "branch-not-found." ~3 lines: use `cut -d. -f1-2` to extract
MAJOR.MINOR (works for both 2-segment human input and 3-segment
conductor input — `${VERSION%.*}` would break on 2-segment input
by stripping the minor version).

### 2b. ecFixes as a verifier

ecFixes checks whether EC passes — a boolean check of external state,
exactly like `verify_createBranches` (branches exist?) and
`verify_upstreamRelease` (tag exists?). Use the Phase 1d STEP_VERIFIER
pattern instead of writing an 80-line script.

Add `verify_ecFixes` to STEP_VERIFIER (~15 lines):

- Get latest push-event component snapshot for VERSION (single oc call,
  fetch all snapshots as JSON, filter with jq)
- Check EC test annotation — use `TestPassed` only (not
  `BuildPLRInProgress` — a build in progress is non-deterministic;
  the verifier should return 1 and let the user re-run later)
- Component EC only — do NOT check FBC snapshots. ecFixes runs BEFORE
  fbcCatalogUpdate in STEP_ORDER, so FBC snapshots at this point
  reflect stale content from the previous release
- Return 0 if component EC passes, 1 otherwise

When the conductor hits ecFixes (auto+hint), the verifier fires. If EC
passes → auto-complete, conductor chains forward. If not → stops with
hint ("run /konflux-ci-fix"). No new script file, no arg parsing, no
tracker integration boilerplate. ~15 lines in autorelease.sh.

**Staleness side effect (resolved, reconcilable):** the auto-complete path now
records the evidence the verifier printed (the gate|hint verifier-complete write
carries `$vdata`), and `verify_ecFixes` emits the snapshot it verified EC
against, so ecFixes's `snapshot` staleness rule (`STALENESS_RULES`) is live.
Because ecFixes completes before `bundleShas` is set, the first pass records the
latest EC-passing snapshot; once `bundleShas` records the shipping snapshot,
`check_freshness` correctly flags ecFixes stale until it is re-verified against
that snapshot (`--refresh ecFixes`, or the next auto-verify run, which passes
`TRACKER` so `verify_ecFixes` checks EC on the recorded `bundleShas` snapshot).
Staleness remains display-only (`get_release_summary`); `find_next_step`
dispatches on status alone, so this changes reporting, not dispatch.

**Cluster access required — distinguish "can't check" from "not done."** The
verifier needs `oc login`. Today a missing/unauthenticated `oc` returns 1
(`verify_ecFixes`), indistinguishable from "EC genuinely hasn't passed," so
the conductor prints the step's skill hint ("run /konflux-ci-fix") — telling an
operator who simply isn't logged in to go fix EC. A precondition failure should
instead return **exit 2** ("could not check: not logged in"), distinct from
exit 1 ("not done"), and the conductor should treat exit 2 as a diagnosable
state — printing an actionable precondition hint (`oc login` required to
auto-verify ecFixes; or `--complete ecFixes`) rather than the skill hint, and
not suppressing it (the gate|hint auto-verify call currently discards verifier stderr).
The same applies to `verify_fbcProdUrls`, which returns 1 when the FBC repo dir
is absent (`verify_fbcProdUrls`): exit 2 with a hint to clone
`~/konflux/submariner-operator-fbc`.

This rule must cover *every* precondition path, not just the first check in each
verifier. Both named verifiers have a *second* precondition path that must also
return exit 2: `verify_ecFixes` (`oc get snapshots` failing *after*
`oc whoami` succeeds → RBAC/wrong-cluster, not an EC failure) and
`verify_fbcProdUrls` (template file absent though the repo dir exists →
wrong branch or incomplete clone). The same can't-check-vs-not-done trap also
exists in the two remote-querying verifiers this section doesn't name:
`verify_createBranches` and `verify_upstreamRelease`
collapse a failed `git ls-remote` (network outage/rate-limit —
these are public repos, so *not* auth) into the same empty result as a genuinely
absent ref, so both `return 1` and the conductor tells the operator to create
branches / cut a release that may already exist — most damaging for
`upstreamRelease`, the gate that auto-chains into `bundleShas`. Their fix
differs structurally from the `oc`/`-d` guards above: there is no explicit guard
and git's exit code is masked by `| grep ... || true`, so the fix must
**capture the `ls-remote` exit status separately** and return 2 only when the
query itself failed, reserving exit 1 for a confirmed-absent ref. Stated as a
rule: convert every `|| return 1` reflecting a missing tool, an auth/RBAC
failure, or a missing/incomplete local repo to exit 2 with an actionable hint,
reserving exit 1 strictly for "genuinely not done."

This requires the dispatch
(the `gate|hint` branch) to capture the verifier's exit code and branch on 2;
exit 1 behavior is unchanged.

**Real-world context (verified against live cluster 2026-08-12):**
Between releases, all component snapshots show EC TestFail (Tekton tasks
get stale). During release prep, after tektonTasks bumps task versions and
PRs merge, EC starts passing again. FBC snapshots typically pass EC
independently.

**Note:** ecFixes has no formal dependency on tektonTasks in the DAG
(both have empty deps), but there's an implicit dependency through the
push→merge→rebuild cycle. If the verifier runs before tektonTasks PRs
merge, EC will fail and the conductor stops with the hint — correct
behavior.

## Future Script Candidates

Prioritized by wall-clock impact. Items marked DONE have been implemented
and are listed for reference only.

### cveFixes — wrapper around shipyard cve-fix skill (DONE)

**Shipped** as `scripts/cve-fixes-update.sh` (`STEP_SCRIPT[cveFixes]`), a
`review`-gated `run` step. Eliminates the last reducible Z-stream `--complete`
call (`tektonTasks`, the other one, is also scripted). The `bundleShas`
branch-guard backstop (`assert_expected_branch`, see "Known bugs") had already
shipped, and the wrapper restores each repo's checkout itself (design #3), so
cveFixes cannot even *feed* the cross-step branch-misroute hazard.

The design below is the as-built record. **[audit]** markers flag claims the
2026-08-20 ground-truth audit corrected from an earlier draft. Net effect: the
wrapper is *not* the "~25-line" loop the old draft imagined (see §"Wrapper
design"), but a clean, robust fan-out sibling of `tekton-task-refs-update.sh`.

**Audited 2026-08-20** against the real tooling at
`~/go/src/submariner-io/shipyard/skills/cve-fix/` (branch `cve-fix-harden`;
companion scripts live under `scripts/`, e.g. `scripts/fix-all.sh`,
`scripts/lib.sh`, `scripts/detect.sh` — the line-number citations below are
from that audit and may drift as the skill evolves).

The shipyard repo has a full CVE fix automation system under
`~/go/src/submariner-io/shipyard/skills/cve-fix/scripts/`:

- **Per-repo entry:** `fix-all.sh [repo] [branch]` (both optional,
  order-independent; `repo` may be an absolute path — `detect.sh:24-27`). The
  Makefile `all` target loops the repo registry calling `make fix` per repo.
- **Deterministic fixers:** `fix-package.sh` bumps Go deps,
  `fix-stdlib.sh` bumps Go directive, `ignore.sh` handles unfixable CVEs — all
  pure bash, no `claude` (verified: no `claude` ref in any of the three).
- **AI legs (optional):** an AI-review leg (`review.sh:79`) and a subagent
  verification loop (`lib.sh:796`), each gated on `command -v claude`
  (`review.sh:55`, `lib.sh:740`) and degrading to deterministic companion-script
  evidence when `claude` is absent. **[audit]** Running from the conductor spawns
  nested `claude -p` per repo (×7) — a real latency/resource cost the "~25-line"
  framing hid, though wrapper logic is unaffected.
- **Exit codes — [audit] not what the old draft said.** `cve_fix_exit_code`
  (`lib.sh:623-632`) returns **only 0 or 2, never 1**. `0` = clean (and
  `fix-all.sh` then removes its own fix branch, `lib.sh:401`). `2` = "needs
  attention", **overloaded**: unresolved CVEs **OR** tests failed **OR**
  verification failed **OR** untrustworthy rescan — indistinguishable by exit
  code alone (must parse the "NOT READY TO PUSH" vs "PR command:" stdout block).
  `1` comes *only* from `set -e`/validation (scan fail `fix-all.sh:84-87`, dirty
  tree `detect.sh:80-86`, arg/repo errors) — a genuine hard error.
- **`make all` MAX-masks the hard-error signal** (`Makefile:28-34`): it exits
  the numeric max rc across repos, so a repo's `2` masks another's `1`. Confirmed
  — the wrapper therefore calls `fix-all.sh` per repo directly (§"Wrapper design").

### Wrapper design (`scripts/cve-fixes-update.sh`)

A fan-out sibling of `tekton-task-refs-update.sh`, following that template
(skeleton, `die`, guarded tracker writes, sourcing guard for tests). Four
load-bearing decisions, each forced by an **[audit]** finding:

1. **Own the repo list; do not read `repos.yaml`.** **[audit]** `repos.yaml`
   does not exist in the tree — only `repos.yaml.example` (2 placeholders), and
   `detect.sh`/`Makefile` silently fall back to it. So the list is user-local and
   git-ignored. The wrapper instead hardcodes its own authoritative
   `REPO_ORDER` — the 7 Go repos from `scan-cves.md`: `submariner-operator
   submariner lighthouse shipyard subctl admiral cloud-prepare` — exactly as
   every sibling fan-out script owns its list. It passes each repo's absolute
   path to `fix-all.sh` (`fix-all.sh "$SUBMARINER_BASE/$repo" "release-$MM"`),
   which resolves a path arg directly (`detect.sh:24-27`) with no yaml lookup.
   Drops the `yq`/`repos.yaml` precondition entirely, and makes "all repos
   scanned" a *meaningful* completeness guard.

2. **Call `fix-all.sh` per repo directly, capture each exit code.** Never
   `make all` (MAX-masks `1`→`2`) nor `make fix` (make exits 2 on recipe
   failure). Under `set -e`, capture with `rc=0; fix-all.sh ... || rc=$?`.

3. **The wrapper restores each repo's checkout itself.** **[audit]** `fix-all.sh`
   restores `ORIGINAL_REF` only on the no-CVE / env-abort exits (`lib.sh:401`);
   on the normal *fixed* path it leaves the repo on the throwaway
   `fix-<version>-cves-<YYYY-MM-DD>` branch, and its EXIT trap reverts only
   *uncommitted* changes. So the wrapper records the current ref before each call
   and `git checkout -f "$orig_ref"` after (the fix branch keeps its commits for
   the PR; a push-by-name still works). This closes the cross-step
   branch-misroute hazard *at the wrapper* — defense-in-depth over the
   `bundleShas` `assert_expected_branch` backstop — with ~4 lines and **zero
   changes to the external tooling** (this supersedes the old "restore
   ORIGINAL_REF in the cve-fix tooling" polish item). No-op for the shipyard
   self-fix/worktree case (its checkout never moves).

4. **Four buckets; complete only when nothing is pending.** **[audit]** `exit 0`
   is *two* sub-cases, not one — the earlier "exit 0 → clean/UPDATED" conflation
   would auto-complete on run 1 with fix PRs still open. So the wrapper splits it
   by a **fix-branch diff**: snapshot `git for-each-ref refs/heads/fix-*-cves-*`
   before the call and after; a *new* branch means fixes
   were committed and a PR is pending, while the skill *removes* its own branch on
   the no-CVE path (`lib.sh:401`), so a truly clean run nets no change. Buckets:
   - `exit 0` + new fix branch → **UPDATED** (fixed, PR pending merge)
   - `exit 0` + no branch change → **clean/SKIPPED** (nothing to do)
   - `exit 2` → **NEEDS_REVIEW** (CVEs remain / tests broke / verify failed —
     can't tell which by code)
   - `exit 1` (or anything else) → **FAILED**, hard-stop

   Mark the tracker step `complete` only when UPDATED, NEEDS_REVIEW, *and* FAILED
   are all empty — i.e. every repo came back clean with nothing awaiting a PR
   merge (shipped as `step_complete "${#REPOS_UPDATED[@]}"
   "${#REPOS_REVIEW[@]}" "${#REPOS_FAILED[@]}"`). Rationale: a security step's
   `complete` must not mean "ran, PRs still open, unsure if CVEs remain." The
   natural loop reaches all-clean: run → PRs created (UPDATED) → merge → re-run
   (origin now clean → every repo `exit 0` with no branch → fix branches
   auto-removed → UPDATED empty) → `complete`. `--complete cveFixes` stays the
   manual override. Costs two conductor passes — accepted for correctness on a
   security-critical step.

Mechanics carried from the template: `MAJOR_MINOR="${VERSION%.*}"` (parameter
expansion, as tekton uses); optional `[repo]` filter with the guarded
`in_progress`/`complete` writes keyed to `"cveFixes"`; final `update_step` in an
`if` block (not a trailing `&&`) so an empty `TRACKER` can't fail a good run.

**Push/PR output — forward, don't synthesize.** **[audit]** `fix-all.sh` prints
its *own* PR block: push to the auto-detected **fork** remote, `gh pr create
--head <fork-user>:<branch>`, a conditional `cd <worktree>` prefix for the
shipyard worktree case, `<fork-remote>`/`<fork-user>` placeholders when no fork
is found, and a "NOT READY TO PUSH" suppression when results are unconfirmed
(`fix-all.sh:385-423`). Synthesizing origin-based push lines (the Phase-1c
template) would be *wrong* here. Since `AUTOMATION_LEVEL=review` shows the full
per-repo output at the stop, the wrapper appends only a **one-line pointer** to
`$AUTORELEASE_PUSH_LOG` ("CVE-fix PRs: see per-repo `PR command:` blocks in the
review output above") rather than parsing an external tool's stdout (fragile
coupling). Add the noted one-line caveat to the Phase-1c template that its
origin/same-repo shape does not cover fork-remote steps like cveFixes.

**Wiring (as shipped).** One load-bearing change:
`STEP_SCRIPT["cveFixes"]="scripts/cve-fixes-update.sh"` in `jira-tracker.sh`
(next to the `tektonTasks` entry) — this alone flips dispatch `hint`→`run`
(`autorelease.sh:264-272`; `gate` beats `script`, but cveFixes is `review` not
`gate`). `AUTOMATION_LEVEL=review` kept (test `test-jira-tracker.sh:118` asserts
it). `STEP_ORDER`/`STEP_DEPENDENCIES`/`STEP_PHASE`/`STEP_TITLES` already carried
`cveFixes`; the now-dead `STEP_SKILL_HINT["cveFixes"]` is left in place (harmless).
`test-jira-tracker.sh` asserts every `STEP_SCRIPT` path exists on disk, so the
script landed in the same commit as the map entry. A `cve-fixes-update:` Makefile
target (mirroring `tekton-task-refs-update`) plus `.PHONY` entry, a `test-cve`
target for `scripts/lib/test-cve-fixes.sh`, and `test-cve` appended to the
aggregate `test` target. Two `test-autorelease.sh` expectations moved with the
`hint`→`run` flip: cveFixes now dispatches as `run` and `ecFixes` is the first
remaining `hint` step. The conductor invokes `script "$VERSION"` with `$VERSION`
the 3-segment `X.Y.Z` (`autorelease.sh:1091`), runs the script, then breaks for
the review stop (`autorelease.sh:1118-1122`).

**Testing (as shipped).** `scripts/lib/test-cve-fixes.sh` sources the guarded
script (like `test-tekton-task-refs.sh`) and runs 32 tests: the pure helpers —
arg parse / version validation, `classify_bucket` (exit + committed-flag →
clean/updated/review/failed), and the `step_complete` predicate (complete iff
UPDATED, NEEDS_REVIEW, *and* FAILED all empty), each mutation-verified; plus
end-to-end `update_repo` against a throwaway git repo with a **fake `fix-all.sh`
stub** (exit-code + fix-branch side-effect scripted per case, as
`test-tekton-task-refs.sh` fakes `PATCHER_SCRIPT`), asserting the branch-diff
bucketing and that the checkout is force-restored to the original ref on every
exit path — including the stranded-on-fix-branch case the skill leaves behind.

**Interaction with rpmLockfiles:** No overlap. rpmLockfiles handles RPM system
packages; cveFixes handles Go dependencies in the 7 Go repos. Independent DAG
steps, empty deps. `bundle-image-update.sh:601` reads `check_freshness
"cveFixes"` — a *soft, timestamp-based* warning only (fires only if cveFixes is
`complete` and older than the 3d `STALENESS_RULES` entry), so the all-clean
completion policy is fully compatible.

**Scope caveat — cveFixes does NOT cover the addon Go-toolchain leg.** The
wrapper covers only its 7 Go repos. The `scan-cves.md` workflow it maps to has a
third leg — "Addon Go Toolchain" — that bumps the builder image in
`stolostron/submariner-addon`'s `Dockerfile.konflux`; the shipyard skill cannot
do that (it edits Go versions, not a Dockerfile tag) and no conductor step
handles it. So the completeness guard proves "every one of the 7 Go repos was
scanned," NOT "the full CVE step is done." **Decision:** keep the `review` stop
and have the redo prompt remind the operator to bump the addon toolchain
manually. (The skill *does* fully triage the 7 Go repos — deterministic fixes, AI
review, `.grype.yaml` ignores — so the old "irreducible human judgment" framing
was wrong for those legs; it holds only for the addon leg.)

**Caveat — cveFixes is NOT idempotent; premature re-runs orphan branches
(Principle 6 does not hold).** Each invocation mints a *fresh* branch
`fix-<version>-cves-<YYYY-MM-DD>` cut from `origin/<branch>`
(`detect.sh:97-123`), never a resume; same-day collisions append `-v2`, `-v3`
(`detect.sh:102-105`). **[audit]** So re-running *before* merging the open PRs
re-scans already-fixed repos and strands the earlier branch (duplicate PRs if
pushed). The completion policy (all-clean, #4 above) makes the *intended* re-run
— after merge — safe: `origin` is now clean, every repo returns `exit 0`, and
`fix-all.sh` removes its own branch (`lib.sh:401`), so no orphan. The residual
risk is only a *premature* re-run; the `review` stop discourages it and the redo
prompt warns to prune stale `-vN` branches / close superseded PRs. Severity
bounded *medium* — nothing auto-pushes (Principle 3), so a strand needs a genuine
fix plus a human pushing twice.

**Cross-step branch-misroute hazard — now closed on both sides.** `fix-all.sh`
leaves fixed repos on `fix-<version>-cves-<date>` (`lib.sh:401` restores only on
the no-CVE path), and `bundle-image-update.sh` (bundleShas) commits to current
HEAD — historically a misroute risk. Two independent guards now close it: (1) the
shipped `bundleShas` `assert_expected_branch` backstop hard-stops rather than
committing onto a stray branch (Known bugs → "No trap/cleanup…"); (2) the wrapper
restores each repo's checkout after every `fix-all.sh` call (design #3 above), so
cveFixes never leaves a repo stranded in the first place. Defense in depth — the
external cve-fix tooling needs no change.

**Caveat — cveFixes hard-fails on any dirty working tree.** `detect.sh` exits 1
on a dirty non-self-fix repo, surfacing as a fatal exit 1 in the per-repo loop.
The Script Contract's "verify clean working tree (or warn)" cannot be honored
here — the hard-fail lives inside `fix-all.sh`, so "(or warn)" is impossible; the
guidance is clean/stash the dirty repo, then re-run. The failure is not opaque
(`detect.sh` names the cause and repo on stderr); the only gap is that the
precondition is undocumented.

**Why no downstream safety net makes the all-clean policy the right call.** No
later step re-examines CVE status: the `review` stop only proves output was
generated, `upstreamRelease` is a bare tag-existence check, `ecFixes` checks the
enterprise-contract annotation not CVE status, and the releaseNotes cross-check
is warn-only. So if cveFixes auto-completed on `exit 2`, nothing would ever
re-check whether the fix PRs merged before the tag is cut. That is exactly why
completion requires all-clean (design #4): the tracker's `complete` is the only
place CVE remediation is gated, so it must mean it. A future hardening, if
warranted, is a grype/clair verifier that proves completion from scan state
rather than exit code — deferred; the all-clean exit-0 gate is the cheap primary.

### tektonTasks — multi-repo pipeline-patcher (DONE)

**Shipped** as `scripts/tekton-task-refs-update.sh`
(`STEP_SCRIPT[tektonTasks]`). Completes the 3-step auto chain
rpmLockfiles → versionLabels → tektonTasks before the review stop at
cveFixes.

tektonTasks and ecFixes previously shared the `/konflux-ci-fix` hint but
are different operations:

- **tektonTasks** = actively bump Tekton task references across the 5
  component repos + FBC repo. Creates PRs.
- **ecFixes** = passively check whether EC passes (which requires tasks to
  be current).

`pipeline-patcher bump-task-refs` (from `simonbaird/konflux-pipeline-patcher`,
via `scripts/lib/pipeline-patcher.sh`) is the same helper
`konflux-bundle-setup.sh` uses for the `tektonBundle` step. The script loops
`submariner-operator submariner lighthouse shipyard subctl fbc`, runs
bump-task-refs in each on a per-repo fix branch, commits (never pushes), and
gates tracker completion on a full no-failure run.

**Dependencies:** `oras` + `yq` required by pipeline-patcher (the skill
never checks for them — the script does, in `check_prerequisites`).

**Ordering:** tektonTasks → push/merge → rebuild → ecFixes auto-verifies.
The DAG models them as independent (both have empty deps) because the
rebuild cycle is external; STEP_ORDER places tektonTasks first. No dedicated
verifier — the downstream `verify_ecFixes` catches the result even if tasks
were bumped by prior manual work.

**Robustness note:** unlike the version-labels template it copies, this
script refuses a dirty tree and restores each repo's original ref on every
exit path, so it never parks a repo on the fix branch — the same discipline
the shipped cveFixes wrapper adopts to close the cross-step branch-misroute
hazard.

### tektonComponents — multi-repo component setup

**Priority: LOW.** Y-stream only.

The existing `scripts/konflux-component-setup.sh` (1109 lines) handles one
repo/component at a time. The wrapper loops over 8 components across 5 repos:

```text
operator(1): submariner-operator
submariner(3): submariner-gateway, submariner-globalnet, submariner-route-agent
lighthouse(2): lighthouse-agent, lighthouse-coredns
shipyard(1): nettest
subctl(1): subctl
```

**Known issues:**

- `konflux-component-setup.sh` only checks LOCAL branch refs and never
  fetches from the remote — if bot PRs haven't been fetched, it fails
- Propagation gap from configureDownstream has no detection mechanism
  (bot PRs appear after ArgoCD sync, which can take ~30 min)
- Partial failure leaves components in inconsistent state

~200 lines. Complex enough to defer until Y-stream pain is real.

### DONE: fbcCatalogUpdate, tektonBundle, fbcProdUrls

- **fbcCatalogUpdate:** wired as STEP_SCRIPT (`scripts/fbc-catalog-update.sh`).
  AUTOMATION_LEVEL changed to `review`.
- **tektonBundle:** wired as STEP_SCRIPT (`scripts/konflux-bundle-setup.sh`)
  with tracker integration + push log.
- **fbcProdUrls: verifier fixed (was a no-op that always failed).** The old
  `verify_fbcProdUrls` grepped `bundle-v${version}` against
  `catalog-template.yaml` — a token that never appears there (the template
  names entries `submariner.v${version}`; `bundle-v*.yaml` files live under
  `catalog-4-XX/bundles/`), so it always returned 1 and the step could never
  auto-complete. Rewritten to locate the olm.bundle
  entry — matching the 2-space-indented `- name: submariner.v${version}` line
  (anchored `^  - name:`) so it selects the bundle, not the 6-space channel
  entry, and anchoring the trailing `$`
  so `0.17.2` does not match `0.17.2-0.<ts>.p` — read the image line directly
  after it, and assert it is `registry.redhat.io` rather than
  `quay.io/redhat-user-workloads`. Behaviorally verified against the live
  template: 0.20.3 (still quay.io) → not done; 0.17.2/0.21.3/0.24.0
  (registry.redhat.io) → done; absent version → not done. The step's
  *intent* — the FBC repo's `make update-bundle` converts quay.io →
  registry.redhat.io URLs — was always sound; only the completion check was
  wrong.

### Staleness in conductor

**Purpose:** wire `check_freshness()` into `find_next_step` so a completed-but-
stale step re-runs instead of being skipped. Fixes the stage re-iteration
problem that hit 4 of 8 historical releases (0.22.0, 0.22.1, 0.23.1, 0.24.0).

**Deferred.** `--refresh` (Phase 1a, implemented) already solves this in 5
seconds of typing — the operator always knows they just pushed a fix and waited
for a rebuild, so staleness automation only re-detects what they already know.
Not worth ~50-80 lines across `autorelease.sh`, `jira-tracker.sh`, and 3-4 step
scripts (the estimate grew from ~20 once the review below landed). Revisit if
`--refresh` proves insufficient.

**Why the integration is ~50-80 lines, not ~20** (load-bearing constraints for
whoever builds it): (1) `find_next_step`'s single-fetch jq cache
extracts only `[.step,.status]`; `check_freshness` needs the full step JSON
(timestamp, `data.snapshot`), so the cache query must expand. (2) `check_freshness`
re-fetches via `get_step`; pass cached data through its 4th arg to preserve
single-fetch — but the `snapshot`-rule branch (`check_freshness`) *also*
fetches `bundleShas` as its reference, so that reference must come from the cache
too (5th arg or cache lookup) or every snapshot-rule step still costs one Jira call.

**Orthogonal, cheaper, and independent of the deferral — a "/release-ls staleness
accuracy" fix.** Every `STALENESS_RULES` bug below lives in the *reporting* path
(`get_release_summary` → `/release-ls`), never in
`find_next_step`, so all are fixable without wiring staleness into dispatch.
Three snapshot rules were dead — they read an empty `.data.snapshot` and
returned "fresh" early — via three routes that all reduced to "`.data.snapshot`
empty at completion." All three are now fixed by recording the snapshot at
completion (Design Principle 7's verifier-records-snapshot rule): the FBC catalog
script records it (`fbcCatalogUpdate`, via `snapshot_step_data` in
`fbc-catalog-update.sh`), `--complete` stamps it (`qeValidation`, via
`handle_step_override`), and the auto-verifier emits it (`ecFixes`,
`verify_ecFixes` → the gate|hint verifier-complete write). Still open: add a
`componentStage` (=`snapshot`) entry; change `bundleShas`'s self-referential
`snapshot` rule to time-based (`3d`). (Latent, not bugs:
`releaseNotes`/`fbcStageReleases`/`fbcProdReleases` omit the snapshot but have no
rule, so they're never checked.)

**`fbcProdUrls` `75d` rule — a time-based rule that misfires (decision: drop it).**
Unlike the snapshot rules (which needed the verifier to emit their snapshot),
this time rule fires on `.timestamp` alone, so it does the opposite harm: 75 days
after auto-completion it
nags forever on a permanent one-time action. Do NOT replace it with a
"no-successor / >90-days-out" auto-trigger — the conductor cannot compute either:
`_resolve_version` has no release-schedule source, and "no newer tracker" is true
at the *end of every release* (trackers are created only when the next release
starts, `create-release-tracker.sh:100`), so it would fire every time. **Resolved
by the linear closeout model:** the conversion is done per-release at closeout, not
deferred. `print_terminal_summary` prints a fixed terminal line nudging the
operator to do the quay.io→registry.redhat.io conversion and re-run; once done,
`verify_fbcProdUrls` self-completes the step, `all_done` auto-closes the tracker,
and there is no follow-up ticket. See "Terminal message + closeout" below and the
Design Principle 7 caveat.

### Read-only verification gates

> **DONE (Tier 2 item #5).** With apply shelved, read-only gates are the primary
> robustness play (catching false-positive chaining), not a Phase 3 warm-up. The
> design points below stand as shipped, with one simplification: the concrete
> `componentStage` gate compares `submariner-bundle` *image digests* rather than
> `relatedImages` SHAs (see the "one good gate" paragraph). The two design-principle
> points (gate the consumer, in-script assertion) shipped verbatim.

Inspired by k8s-rebase's explicit gate architecture. Run a step's upstream "Done
When" *reads* as a precondition; pass → continue, fail → stop with diagnostics.
Two design points (see Tier 2 item #5 for the full rationale):

- **Gate the consumer's precondition, not the producer's completion.** A gate
  that fires "after a step self-completes" runs only in the producing run —
  `find_next_step` skips the now-`complete` producer on the next invocation, so
  such a gate *fails open* in the normal repeated-run mode. Key it instead to
  the *consumer* step's precondition (verify the upstream artifact before the
  consumer runs, while the consumer is still non-`complete`).
- **Implement as an in-script precondition assertion inside the consumer's own
  script.** `componentStage` owns a `STEP_SCRIPT`, so `find_next_step` routes it
  to the `run` branch, which never consults `STEP_VERIFIER` — a verifier gate
  would be dead code (see "Chain hazards"). Assert at the top of the consumer's
  existing script; no `scripts/gates/<step>.sh` tree (contradicts Design
  Principle 7 and adds a third place to encode "Done When" beside
  `release-status.sh`'s `check_step_*` and the verifiers), no conductor-loop
  change. *(A `STEP_VERIFIER`-on-dispatch-hook variant is possible but deferred —
  it needs the run-branch dispatch change gated behind extracting the untested
  loop into a testable function.)*

The one good gate — **before `componentStage`** (shipped as `assert_bundle_rebuilt`
in `create-component-release.sh`): compare the chosen snapshot's `submariner-bundle`
*image digest* against the `bundleShas`-recorded snapshot's — equal means no
rebuild happened → stale → hard-STOP; the check that prevents a documented live
wrong output (a stale pre-rebuild bundle; see "Chain hazards"). This digest-change
proxy replaced the originally-planned `relatedImages` comparison: it is simpler
(two `oc get snapshot` reads, no image pull) and still catches an unrelated
intervening snapshot (new snapshot, unchanged bundle digest). Complementary and
also shipped: `bundleShas` flipped to `review` so the human merges and awaits the
rebuild first.

**Do not** add a symmetric gate elsewhere. All YAML-emitting steps are now `review`
(AUTOMATION_LEVEL) — `componentStage` was flipped from `auto` to `review` so the
conductor stops after the YAML is committed, letting the operator apply/watch before
proceeding to `releaseNotes` and `fbcCatalogUpdate`. It is also the sole *unverified* gap:
`verify-component-release.sh` only checks 9 components present + tests, never
bundle `relatedImages` freshness. `fbcStageReleases` runs
`verify-fbc-release.sh` before generating any YAML, which already asserts each
snapshot's bundle SHA matches the updated catalog (postdates `fbcCatalogUpdate`)
plus event-type and tests; `fbcProdReleases` and `componentProd` reuse the
stage-verified snapshot and skip re-verification (`create-fbc-releases.sh:234`,
`create-component-release.sh:179-183`).

The `componentStage` gate was added proactively — the stale-bundle hazard it
catches was documented and live (see "Chain hazards"), not a defect to wait on.

## Phase 3: Apply steps (SHELVED — retained as a record, not planned work)

> **Shelved indefinitely (see Status).** The conductor will not write to the
> Konflux cluster for the foreseeable future — apply/watch stay a human
> action, and the active roadmap is "Backlog: non-cluster improvements". This
> section is kept only so the analysis isn't lost if the decision is ever
> revisited. Do not treat anything below as scheduled.

The highest wall-clock-impact automation. Each apply→watch cycle
is 20-30 minutes of human attention. A stage release with 1 component +
one FBC apply per supported OCP version (currently 7: 4-16 through 4-22)
represents ~4 hours of wait time.

**Shelved** — Phase 3 would write to the Konflux cluster (`oc apply`), which
is out of scope by decision. Phase 3 is also inherently complex
(cluster-touching, retry logic). The verifier-based approach (below) reduces
complexity
but the risk of incorrect applies (duplicate Release CRs, wrong
snapshots) requires high confidence in the conductor first.

**Phase 1+2 lesson to apply:** The verifier pattern could simplify Phase 3
dramatically. Instead of building apply scripts with polling loops:

- **STEP_SCRIPT** does the one-shot work: `git push` + `oc apply`. Exits
  immediately after applying. Marks the step with a distinct pipeline-park
  status (`applied`/`awaiting`, per option (b) below — NOT `in_progress`,
  NOT `complete`).
- **STEP_VERIFIER** on the same step checks Release CR status on subsequent
  `/autorelease` invocations: Succeeded → auto-complete, Progressing →
  stop with "pipeline running, re-run later", Failed → stop with
  "retry or investigate."

This eliminates: the 30-min polling loop, session crash recovery, the
`NotFound-after-being-found` state detection. The user simply re-runs
`/autorelease` after the pipeline finishes, and the verifier catches the
result.

**Conductor dispatch change required (not optional) — the load-bearing piece.**
Unlike ecFixes (which reaches its verifier only *because* it has no
`STEP_SCRIPT`, so it dispatches to the `hint` branch — one of the two places the
conductor consults `STEP_VERIFIER`, the `gate|hint` branch), an apply step has
BOTH a script and a verifier. Under today's dispatch, `find_next_step` routes any
non-gate step with a script to the `run` branch (`find_next_step`), which
never consults `STEP_VERIFIER` — so the apply verifier is dead code and a step
marked non-`complete` just re-executes its script (duplicate `git push` +
`oc apply`; the same-step guard only catches repeats within one run). Fix: when a step is parked in its post-apply status, run
the verifier *instead of* re-running the script.

**Park status must be distinct — do NOT key routing on `in_progress`.** All 9
`STEP_SCRIPT` scripts write `update_step ... in_progress` as their *first* action
(e.g. `bundle-image-update.sh:538`, `create-component-release.sh:422`, …), so
`in_progress` means "started, maybe crashed → safe to re-run" and a crash there
is auto-recovered by re-running the idempotent script (Principle 6). Routing on
`in_progress` would break that crash recovery for all 9 scripts *and* break
`--refresh` (which sets `in_progress`, `handle_step_override`). **Decision: option
(b) — give apply steps a distinct park status** (`applied`/`awaiting`). This keeps
`in_progress` intact and lets `--refresh`→`in_progress` still route back to the
script for a fresh `oc apply`. (Option (a), scoping the routing to
verifier-owning steps, is rejected: it routes `--refresh` to the status-checking
verifier, which cannot re-apply.) No step has both a script and a verifier today
(`STEP_SCRIPT ∩ STEP_VERIFIER = ∅`), which is why the gap has never bitten.

**jira-tracker.sh joins the change surface:** `update_step`'s `case "$status"`
(in `_update_step_impl`) maps only `in_progress`/`complete`/`failed` and has no
`*)` default, so a new `applied`/`awaiting` value is stored in STEP_DATA but does
not transition the Jira subtask. Add a transition arm (e.g. keep the subtask "In
Progress" while the pipeline runs) or explicitly accept it stays put until the
verifier marks `complete` — state which, don't let the missing default decide.

**Longer-term true-gate review model (optional, separate from apply).** The five
verifier-less review scripts (releaseNotes, fbcCatalogUpdate, fbcStageReleases,
componentProd, fbcProdReleases) currently self-complete on exit 0, so their
`review` stop is a one-time visual pause, not an await-`--complete` gate.
Converting them to a true gate reuses option (b)'s park status but needs a code
prerequisite (remove their `update_step … complete` calls) and a verifier-less
dispatch branch: in the park status, run the verifier if one exists, else stop
and await `--complete`. Keep the two completion triggers distinct — not "one
mechanism." Whatever form the change takes, it must ship with dispatch-loop tests
(see "The dispatch loop is partially tested") before it gains `oc apply` power.

Estimated reduction: Phase 3 from ~300 lines (4 scripts with polling) to
roughly ~180 lines — the two *component* apply steps are thin (~15-line
script + ~10-line verifier each, sharing a `_check_release_status` helper),
but the two *FBC* apply steps carry the per-OCP retry state machine (~120
lines of verifier logic between them; see "FBC apply with auto-retry") —
**plus ~15-25 lines of conductor dispatch changes** (the
verifier-on-park-status routing above, extended so a non-complete re-run
can write arbitrary STEP_DATA). The original ~100-line estimate omitted both
the dispatch change and the FBC retry state — the parts that actually make
the pattern work.

### DAG expansion

Add 4 new DAG steps: `componentStageApply`, `fbcStageApply`,
`componentProdApply`, `fbcProdApply`. ~50 lines of constant additions,
~4 new test assertions. Adding these constants needs no dispatch change —
but do not read that as "Phase 3 needs no dispatch changes." The
verifier-based apply design above requires the dispatch change described in
"Conductor dispatch change required."

**Dependency updates (ship with Phase 3):** Adding apply steps requires
specifying their dependencies AND updating downstream deps:

New apply step dependencies:

- `componentStageApply` depends on: `releaseNotes` (YAML has no notes
  until releaseNotes adds them — applying without notes is wrong)
- `fbcStageApply` depends on: `fbcStageReleases`
- `componentProdApply` depends on: `componentProd`
- `fbcProdApply` depends on: `fbcProdReleases`

Downstream dependency updates:

- `fbcCatalogUpdate`: change dep from `componentStage` → `componentStageApply`
- `qeValidation`: change dep from `fbcStageReleases` → `fbcStageApply`
- `fbcProdReleases`: change dep from `componentProd` → `componentProdApply`
- `fbcProdUrls`: change dep from `fbcProdReleases` → `fbcProdApply`

**Pre-existing divergence — FIXED (commit 8f8d70c), was a prerequisite for
`fbcProdApply`.** The prod-FBC path used to re-select the latest per-OCP snapshot
at prod time instead of reusing the QE-validated stage snapshot; it now reads and
reuses each stage YAML's snapshot (see Known bugs → "FBC prod re-selects the
snapshot"). Phase 3's `fbcProdApply` verifier assumes prod snapshot == stage
snapshot, and that invariant now holds — modulo the lexical `tail -1` stage-YAML
selection caveat noted there, which would still need hardening before apply is
automated.

**Staleness rules for apply steps:** Apply steps need snapshot-triggered
staleness. Without this, stage re-iteration breaks: componentStage
re-runs with snapshot-B (staleness detected), but componentStageApply
from snapshot-A stays "fresh" (no staleness rule) and is skipped. The
un-applied new YAML causes downstream failures. Add:

- `componentStageApply` = `snapshot`
- `fbcStageApply` = `snapshot`
- `componentProdApply` = `snapshot`
- `fbcProdApply` = `snapshot`

**Hard prerequisite — these rules do nothing until staleness is wired into
`find_next_step`.** The entire scenario above ("staleness detected",
"stays fresh and is skipped") presupposes the conductor consults
`check_freshness` during the DAG walk. It does not today — `find_next_step`
treats any `status=complete` step as done regardless of freshness (see
"Staleness in conductor", which is **Deferred**). So adding these
`STALENESS_RULES` entries is necessary but has zero effect on the conductor
until that deferred wiring ships. Ship the two together, or the apply-step
staleness rules end up dead — the same way ecFixes/fbcCatalogUpdate/qeValidation
were before they recorded their snapshot — surfacing only in `/release-ls`.

**Prerequisite (script side):** `create-fbc-releases.sh` currently records
no `data.snapshot` in its `update_step` call — staleness on fbcStageApply
and fbcProdApply would be silently ineffective. Fix: include the
component snapshot name from the stage release YAML in the tracker data.
**Record the *component* snapshot, not the per-OCP FBC snapshot** — the
`snapshot` rule compares against `bundleShas`'s `.data.snapshot`, which is a
component snapshot, so an FBC-snapshot value would never match and the rule
would misfire (or never fire). This is a scope difference (component vs FBC
snapshot), not a naming detail.

**Prerequisite (verifier side) — do not miss this.** These `snapshot` rules
are ALSO dead unless the apply step's *verifier* emits the snapshot when it
marks `complete`. The one-shot apply script marks the park status
(`applied`/`awaiting`) and the verifier marks `complete`; `check_freshness`
reads the latest STEP_DATA comment, which is the verifier's. The gate|hint
verifier-complete write now carries the verifier's own evidence (falling back to
`{}` only when the verifier emits nothing), so the burden is on the apply
verifier to *emit* `{"snapshot":"<name>"}` — if it emits nothing, the fallback
`{}` overwrites whatever snapshot the park-status update stored and the rule can
never fire. This was the failure mode formerly live on
ecFixes/fbcCatalogUpdate/qeValidation, now fixed (they record the snapshot at
completion). See the STEP_VERIFIER bullet in "Apply step design" and the Design
Principle 7 caveat. Recording the snapshot on the script side alone is necessary
but not sufficient.

### Apply step design (verifier-based approach)

With the Phase 1+2 lesson applied, each apply step has TWO parts. Both parts
depend on the dispatch change in "Conductor dispatch change required" above:
without it the verifier is never invoked and the script re-applies on every
invocation.

**STEP_SCRIPT (one-shot, ~15 lines):**

- AUTOMATION_LEVEL = `review`
- Pushes the YAML commit in this repo
- Runs `oc apply -n submariner-tenant -f $FILE`
- Marks step with the distinct park status (`applied`/`awaiting`, per option
  (b) in "Park status must be distinct" — NOT `in_progress`, NOT `complete`), and
  records `{"snapshot":"<name>"[,"image":"<published-ref>"]}` in that update —
  the `image` ref at apply time only when it is snapshot-derivable (component
  apply); the FBC per-OCP index ref is not derivable yet and is recorded later
  by the verifier (see "Deriving the expected published image" below)
- Exits immediately — no polling

**STEP_VERIFIER (check on re-run, ~10 lines):**

- Checks Release CR status: Succeeded → auto-complete, Progressing →
  return 1 (hint: "pipeline running, re-run later"), Failed → return 1
  (hint: "retry or investigate")
- Release CRs are ephemeral (archived after completion), so CR-absent is
  **not** by itself proof of success — it must be disambiguated by the
  registry, giving *two* CR-absent outcomes:
  - **CR absent AND published image found** → the release succeeded and the
    CR was reaped → auto-complete with `{"snapshot":"<name>"}` (same as the
    Succeeded path).
  - **CR absent AND no published image** → the apply never took effect (crash
    before/at `oc apply`, wrong namespace, CR never created, or an aborted
    run) → **do NOT auto-complete.** Treat as a distinct outcome: either
    re-apply using the `snapshot` the one-shot script recorded in the
    park-status STEP_DATA (safe — `oc apply` is idempotent on the same CR),
    or hard-stop with "cannot determine apply state — Release CR gone and no
    published image; investigate or `--refresh <step>` to re-apply." The one
    outcome that must never happen here is silently marking the step complete:
    that would publish nothing yet unblock every downstream step, and for a
    prod apply it strands the release with no artifact and no error.
- **Must emit `{"snapshot":"<name>"}`, not nothing.** Apply steps have
  `snapshot` staleness rules (below). The standard auto-verify path records the
  verifier's own stdout (the gate|hint verifier-complete write), falling back to
  `{}` only when the verifier emits nothing — so an apply verifier that prints
  no snapshot would make those rules dead on arrival (Design Principle 7
  caveat). The verifier-on-park-status dispatch (see "Conductor dispatch change
  required") must emit the snapshot the one-shot script recorded into the
  `complete` update — the `complete` comment is the one `check_freshness` reads
  (latest STEP_DATA wins), so a bare `{}` there overwrites the snapshot the
  park-status update stored.

**Deriving the expected published image (CR-absent disambiguation).** The
"published image found?" test needs a concrete ref, persisted to STEP_DATA the
moment it is first observable — which differs by step:

- **Component apply** — a `registry.redhat.io/rhacm2/…` bundle ref derivable
  from snapshot + version, so the one-shot script records it at apply time and
  the verifier confirms with `skopeo inspect`.
- **FBC apply** — the per-OCP index ref only exists as the CR's
  `.status…index_image_resolved`, populated ~15-30 min after `oc apply`, so it is
  NOT derivable at apply time. The **verifier** captures each per-OCP ref the
  first time it sees that CR `Succeeded` and persists it; later re-runs use it to
  probe the registry. Reserve the hard-stop for the narrow window where a CR is
  reaped before any verifier run saw it `Succeeded`. (Or reuse the per-OCP
  `succeeded` flag the retry verifier already persists — no registry probe.)

Consequence: apply-step STEP_DATA must carry the published-image ref(s), not just
`snapshot` — "record the snapshot" everywhere below means snapshot **and** ref.
Session crash needs no special code: the script already applied, and the verifier
detects the result on re-run. Both script and verifier need `oc login`.

**The apply "verifier" is a completion check, not a boolean gate.** The existing
call site (`if "$verifier" "$VERSION" 2>/dev/null`, the gate|hint auto-verify call) discards
stderr and collapses to one boolean + one static hint — fine for the read-only
existence checks, inadequate for an apply check that must distinguish *running*
(re-run later) from *Failed* (retry) from *hard error* (no cluster access, or the
**CR-absent + no-image** case above — stop distinctly, never auto-complete). So
the dispatch change must also **stop redirecting the check's stderr to
`/dev/null`** (surface its diagnostics; the check writes its own STEP_DATA via
`update_step`, so stdout is not a data channel) and **return tri-state, not
boolean**. This is a real contract change from the boolean `STEP_VERIFIER`;
calling the apply role a "completion check" keeps the two contracts distinct. The
DAG/STEP_DATA/dispatch remain the single source of truth — this only widens the
return channel from one bit to three states plus visible output.

**Test-gate scope (extends "The dispatch loop is partially tested").** The completion
check has a *mutating* body (`oc apply`, retry files, STEP_DATA writes), so
routing tests are not enough. Phase 3's test gate must cover the check body with a
mockable `oc`: Succeeded → complete-with-snapshot, Progressing → still-running,
Failed → error, CR-absent+registry-present → complete-with-snapshot, and
**CR-absent+registry-absent → re-apply/hard-stop, never auto-complete** (the
load-bearing assertion — retried vs. silently marked done) — all before it gains
`oc apply` power.

### FBC apply with auto-retry

FBC releases fail more than component releases. Historical data: 21 FBC
retry files across 8 releases, with 0.21.3 being worst (15 retry files =
5 OCP versions × 3 attempts). Failure causes: IIB infra issues,
platform-wide stage blocks, wrong snapshots.

**Key pattern from history:** retries re-apply the failed OCP versions in a
batch. Every retry commit creates a new file per version with an incremented
suffix.

`fbcStageApply` and `fbcProdApply` follow the **same one-shot-script +
verifier model** as the component apply steps above — *not* a blocking poll
loop. A polling port of `check-fbc-releases.md` would re-introduce the 30-min
wait the verifier pattern exists to remove and cannot persist retry state
across process invocations, so the retry logic lives in the verifier, driven
by STEP_DATA on each re-run:

- **Count is data-driven, never hardcoded.** The OCP set is whatever
  `create-fbc-releases.sh` actually generated stage YAMLs for (equivalently,
  `verify-fbc-release.sh`'s releasable set: `verify-fbc-release.sh:124,137,
  206-232`) — currently up to 7 (4-16 through 4-22) but routinely fewer
  (0.21.3's worst case was 5), and it grows via the async "Add FBC Support
  for New OCP Version" task. Derive it at apply time; a gate that demands
  "all 7" when only 5-6 are releasable never fires and deadlocks the DAG.
- **Script (one-shot):** `oc apply` the not-yet-applied versions, mark the
  distinct park status (`applied`/`awaiting`, per option (b) in
  "Park status must be distinct" — NOT `in_progress`, NOT `complete`, so the
  option-(b) dispatch routes re-runs to the retry verifier and not back to
  this script), exit immediately.
- **Verifier (on re-run):** read each applied Release CR's status; create a
  fresh retry file and `oc apply` only for versions still failing; persist
  per-OCP status and an attempt counter into STEP_DATA, e.g.
  `{"snapshot":"<name>","attempts":2,"pending":["4-18","4-20"]}`.
- **Complete when all *applied* versions succeed.** Stop at N attempts
  (N = worst historical case, 3) and surface which versions still fail.
- **Exhausted-after-N is a distinct terminal that must offer both escapes.** At N
  attempts with a version still failing, the step does NOT auto-complete; because
  it dispatches through the park-status branch it does not inherit the
  `Or: --complete <step>` line (the gate|hint branch's --complete nudge), so it must surface both
  itself: `--refresh` (reset counter, re-apply from scratch) and `--complete`
  (force-accept). Without this, one stuck OCP version parks forever and silently
  blocks `qeValidation` and the whole prod half.
- **Partial-ship policy (decision): block by default, ship the passing subset
  only on explicit `--complete`.** The conductor never auto-ships an incomplete
  OCP set — a still-failing version keeps the step non-`complete` until a human
  chooses `--refresh` (retry all) or `--complete` (accept the passing subset).
  Safe default for the plan's highest-flake area (21 retry files; 0.21.3 = 15).
- **The shipped subset must be durable, not a lost comment.** A plain
  `--complete` routes through `handle_step_override`'s `update_step … "{}"`
  (`handle_step_override`), and `get_step` returns the *latest* STEP_DATA
  so `{}` erases the verifier's
  `pending:["4-XX"]`. The partial-ship `--complete` must instead persist the
  still-failing set — either carry `pending[]` into the `complete` update (the
  same non-clobber fix "who owns STEP_DATA" needs) or open an idempotent tracked
  Jira follow-up (mirroring `create_release_tracker`). Minimum bar: give a missing
  customer-facing prod OCP index a real, tracked owner rather than a lost comment.
- **The prod FBC path must honor the shipped subset — it still does not.** A
  stage-deferred version must not reappear at prod (never QE-validated). Since
  commit 8f8d70c the prod path derives its OCP set from the **stage YAMLs present
  on disk** (the `create-fbc-releases.sh` prod block iterates
  `releases/fbc/4-*/stage/*.yaml`), not from a cluster re-query — but that is
  still the *full releasable set*, not what actually shipped: a stage YAML that
  was created but whose stage Release never reached `Succeeded` would still spawn
  a prod Release. Constrain prod to the complement of `fbcStageApply`'s
  `pending[]` (equivalently, the stage Release CRs that reached `Succeeded`) —
  **not** every stage YAML on disk. As the Known-bugs entry notes, the "read the
  stage YAML's snapshot" reuse does *not* close this (stage YAMLs exist for the
  full releasable set), so prefer the STEP_DATA/`Succeeded`-CR source.

**Who owns STEP_DATA (one writer, not two):** the verifier writes its own
STEP_DATA directly via `update_step` (best-effort, always returns 0), exactly as the nine step scripts do — the
conductor is not a transport, so the compound FBC blob lives where the verifier
writes it. The non-clobber capability the stock architecture formerly lacked —
the `complete` path **carrying the verifier's STEP_DATA instead of a hardcoded
`{}`** at the gate|hint verifier-complete write — now ships (the write carries
`$vdata`, falling back to `{}` only when empty). What remains for Phase 3
apply steps is a stop-at-N guard and the tri-state park-status dispatch.
Conductor-side change ≈ 10-15 lines (tri-state dispatch + stop-at-N); the
~100-line bulk is verifier logic replacing the old polling script.

## Phase 4: Auto-push for mechanical changes

> **Shelved (out of scope).** Auto-push/PR-open is a cluster-adjacent write the
> hand-driven, read-only conductor deliberately leaves to the human. Retained as
> analysis, not scheduled work.

Phases 1-3 reduce typing and apply friction. Phase 4 reduces the
push/PR/merge wait.

For steps that produce purely mechanical changes — the script IS the
review — add `--auto-push` support:

1. Script creates commit (existing behavior)
2. Script pushes branch to remote
3. Script creates PR via `gh pr create`
4. Script enables auto-merge if repo allows it

**Low risk (deterministic output):**

- rpmLockfiles: podman regenerates lockfiles
- versionLabels: sed replaces version strings

**Medium risk (correct by construction but more complex):**

- tektonComponents, tektonBundle, bundleShas

**Not candidates (require human judgment on the diff):**

- configureDownstream, fbcCatalogUpdate, cveFixes

Note: ecFixes is now a verifier (Phase 2b), not a script — it doesn't
produce commits so auto-push doesn't apply.

Prerequisites: repos have branch protection allowing auto-merge, `gh` CLI
authenticated, opt-in flag (`--auto-push`) — never push by default.

## Phase 5: CVE fix automation

**Shipped as the cveFixes wrapper script** (see Future Script Candidates
above). The shipyard repo's `skills/cve-fix/` provides a complete CVE fix
pipeline — scanning, deterministic fixing, AI review, verification
subagents — with a per-repo entry point (`scripts/fix-all.sh [repo] [branch]`).

The conductor wrapper calls this existing system per repo and relies on the
`review` automation level to stop for human verification. It adds a fan-out
loop, checkout restore, exit-code + fix-branch-diff bucketing, and a
nothing-pending completion guard (see the as-built record in "Future Script
Candidates → cveFixes") — but no new scanning or triage logic; the skill
handles that.

**Impact:** Eliminated the last *reducible* `--complete` call, leaving
`qeValidation` (an irreducible external team gate) as the sole one. Note it did
not cut an invocation: because cveFixes is `review`-level *and* completes only
when origin is clean, its review stop fires on both the fix pass and the
post-merge clean-completion pass — it trades the `--complete` for a second real
run, not for a chained step.

## Phase 6: Pipeline monitoring

> **Not planned (read-only).** Long-poll auto-advance is a background daemon the
> hand-driven conductor doesn't need — the human re-runs `/autorelease` to
> advance. Retained as analysis, not scheduled work.

The conductor watches for pipeline completion and auto-advances.

After a step that triggers a rebuild (PR merge, release apply):

1. Conductor records what it's waiting for (snapshot, release name)
2. User runs `/autorelease --watch` or sets up a `/loop`
3. Conductor polls cluster state every N minutes
4. When passing snapshot/release appears, auto-advance to next step

Where this matters:

- After Build Readiness PRs merge: 15-30 min for snapshot rebuild
- After stage release apply: 30 min for release pipeline
- After FBC catalog update: 15-30 min for FBC snapshot rebuild
- After FBC release apply: 30 min for release pipeline

The apply steps (Phase 3) and the monitor (Phase 6) compose: the apply
step starts the pipeline, the monitor waits for completion, and the
conductor advances when ready.

**Reduced urgency after Phase 3 verifier design.** If Phase 3 apply steps
use verifiers to check pipeline completion (user re-runs `/autorelease`
periodically), persistent monitoring becomes a convenience rather than a
necessity. Consider `/loop`-based implementation if manual re-running
proves tedious.

## Not Automatable (execution)

These steps must be performed externally. The conductor detects their
completion via Phase 1d verifiers or the `--complete` flag, but does not
execute them.

- **createBranches** (review) — cascading side effects across all upstream
  repos, triggers bot PRs, community visibility. Verified by
  `git ls-remote --heads`.
- **upstreamRelease** (gate) — deliberate human decision to cut the release.
  Verified by `git ls-remote --tags`.
- **qeValidation** (gate) — external team tests stage catalogs and approves.
  No verifier possible — the only *irreducibly* manual `--complete`: an external
  team gate that can never have a verifier. It is now the *sole* `--complete`
  call in a Z-stream run: tektonTasks and cveFixes were the two reducible ones
  and are both scripted (cveFixes self-completes on its post-merge clean re-run).

## Impact Summary

| Phase | What it changes | Wall-clock impact | Status |
| --- | --- | --- | --- |
| 1a --complete/--refresh | Unblocks 10 steps, manual re-iteration | Conductor becomes usable | DONE |
| 1b Reorder + deps | Action steps before check steps | ~30 sec (one less invocation) | DONE |
| 1c Push summary | Pending pushes after chaining; step-type-aware trailer | Correct apply/watch vs PR-merge cue | DONE |
| fbcProdUrls terminal msg | "All release steps shipped"; re-run-to-close nudge | Fixes false blocker each prod release | DONE |
| 1d Auto-verifiers | createBranches, upstreamRelease auto-complete | Eliminates 2 --complete calls | DONE |
| 2a Bug fixes | configure-downstream tracker, rpm-lockfile branch | Unblocks Y-stream + Z-stream | DONE |
| 2b ecFixes verifier | Auto-complete when EC passes | Eliminates 1 --complete call | DONE |
| Quick wins | Partial-completion fix, fbcCatalogUpdate script | Correct state + 1 less --complete | DONE |
| tektonBundle | Bundle setup wired as STEP_SCRIPT | 1 less hint stop (Y-stream) | DONE |
| fbcProdUrls verifier | Verifier fixed (was wrong grep token, always failed) | Auto-completes once URLs converted | DONE |
| tektonTasks | Multi-repo pipeline-patcher (bump task refs) | 1 less hint stop, 3-step auto chain | DONE |
| cveFixes | Wrapper around shipyard cve-fix skill | Eliminated last reducible --complete (adds no invocation) | DONE |
| 3 Apply steps | Create + apply + retry in one flow | 4+ hours of wait → background | Shelved (design decision) |
| 4 Auto-push | Push/PR/merge becomes automatic | 1-2 hours per release | Shelved (out of scope) |
| 6 Monitoring | Pipeline waits become automatic | 2-4 hours | Not planned (read-only) |

### Z-stream walkthrough: current vs target

**Current flow** (all done work):

```text
/autorelease 0.25.1
  → rpmLockfiles: runs (auto+script)
  → versionLabels: chains (auto+script)
  → tektonTasks: chains (auto+script)
  → cveFixes: runs (review, script) → fixes CVEs, prints PR commands, stops
  ━━━ Pending Actions ━━━
  (push instructions for lockfile + label + task-ref branches; cve-fix PRs
   surface in cveFixes' own review output)
/autorelease 0.25.1   # after the cve-fix + task-ref PRs merge and rebuild
  → cveFixes: runs (review, script) → origin now clean → marks complete, stops
/autorelease 0.25.1
  → ecFixes: auto-verifies (EC check) → chains if passing
  → upstreamRelease: auto-verifies (tag check) → chains if tag exists
  → bundleShas: runs (review, script), stops
/autorelease 0.25.1   # after SHA-bump PR merges + bundle rebuilds
  → componentStage → releaseNotes: chain, stops (review)
/autorelease 0.25.1
  → fbcCatalogUpdate: runs (review, script), stops
/autorelease 0.25.1
  → fbcStageReleases: runs (review, script), stops
  ... qeValidation gate, prod steps, fbcProdUrls (hint stop; auto-completes
      once URLs converted) ...
```

~9 invocations, 0 *reducible* --complete calls, plus the one irreducible
qeValidation gate and the `bundleShas` review stop (Tier 2 item 5 — an
intentional pause for the SHA-bump PR to merge and the bundle to rebuild, not a
--complete). tektonTasks and cveFixes were the two reducible calls and are both
scripted; cveFixes self-completes on the post-merge clean re-run rather than via
`--complete` (that second cveFixes pass is why the invocation count held at ~9
rather than dropping). fbcProdUrls no longer forces a --complete: its verifier
auto-completes once the URL conversion lands, and stops with a hint otherwise
(the URL conversion usually happens during the *next* release's FBC catalog
update, so a hint stop at this release's end is correct, not a bug). Total
*reducible* --complete calls today: 0.

**Operator note (pre-Phase-3):** `fbcCatalogUpdate` currently depends only on
`componentStage` (the *create* step), not on the stage apply
(`componentStageApply` does not exist yet; Phase 3 repoints this dep to it,
"DAG expansion" above). So the DAG will let `fbcCatalogUpdate` proceed as soon
as the stage YAML is *committed*. What the script actually consumes is *not* the
stage apply's output: `fbc-catalog-update.sh` → `make update-bundle` reads the
bundle from a passing bundle **PUSH** snapshot's `spec.components[].containerImage`
quay.io ref (`update-bundle.sh:416-419`) — a snapshot produced by the bundle
repo's push pipeline, independent of whether any stage Release CR has been
applied. So applying Step 10 is **not** a hard input requirement of this script;
it is workflow-ordering *hygiene* — a recommendation — so that the same bundle is
already progressing toward registry.redhat.io for downstream QE resolution when
the catalog lands. (No registry.redhat.io precondition here — the catalog update
consumes the quay.io Konflux ref; the registry.redhat.io conversion is a later,
separate concern — see fbcProdUrls.) The `componentStage`-not-`componentStageApply`
dep is thus a documented judgment call: it gates on the create step because that
is the only stage node that exists pre-Phase-3, and the repoint to
`componentStageApply` is deferred with the rest of the apply-step work.

**Terminal message + closeout (DONE; linear model).** When `fbcProdUrls` is the
*only* remaining incomplete step, every release-shipping step is done and only the
quay.io→registry.redhat.io FBC prod-URL conversion remains. `verify_fbcProdUrls`
returns 1 until that conversion lands in the FBC template (it is a real verifier
reading `catalog-template.yaml`, not a stub), so the walk stops on the terminal
message rather than reaching `all_done`. `print_terminal_summary` (shared by the
real loop and `--dry-run` so the wording never diverges):

- prints **"All release steps shipped"** — not "the release is complete":
  pre-Phase-3 `componentProd`/`fbcProdReleases` are `review`-level where `complete`
  means only "YAML committed locally", and the prod `oc apply` is operator-driven
  and unmodeled, so it adds "confirm the prod component/FBC releases were applied
  and their pipelines succeeded before announcing";
- points at the conversion (the `fbcProdUrls` title + the
  `update-fbc-templates-prod.md` skill hint);
- nudges **"re-run once done to close the release"** and does NOT emit the generic
  `Or: --complete fbcProdUrls` line (which would falsely mark the conversion done).
  The generic `--complete` escape is kept only for the abnormal mid-release case
  where a step genuinely blocks.

Once the operator does the conversion and re-runs, `verify_fbcProdUrls` passes →
the walk reaches `all_done` → auto-close (item 9) verifies the release shipped
(prod bundle live + every in-scope operator index) and resolves the tracker, with
`--close` as the manual fallback. So the prod-URL conversion always precedes the
epic close.

**Superseded — the `--final`/deferred-follow-up design.** An earlier design
treated the prod-URL conversion as normally deferred to the *next* release and
added a `--final` flag for last-in-stream releases (it filed a standalone Jira
follow-up Task carrying the conversion obligation AND marked `fbcProdUrls`
complete). Per operator practice the conversion is done per-release at closeout
(shipped → convert → done), so `--final`, `handle_final`, and the follow-up
machinery (`ensure_fbc_prod_url_followup`/`find_fbc_prod_url_followup`) were
removed in favor of the linear model above.

> ✓ The `bundleShas → componentStage` chain, a former hazard (it could emit a
> stage YAML pointing at a stale, pre-rebuild bundle), is now broken by design:
> Tier 2 item 5 flipped `bundleShas` to `review` and added an in-script digest
> gate to `create-component-release.sh`. Walkthroughs written before that flip may
> still show the two steps chaining in one invocation — treat the review stop at
> `bundleShas` as current. See "Chain hazards: rebuild boundaries the auto-chain
> can cross silently".

**Progression as steps got scripted** (reducible `--complete` calls fell to
zero — the same flow from `ecFixes` onward):

- **After tektonTasks scripted (DONE):** rpmLockfiles → versionLabels →
  tektonTasks chain in one invocation — with tektonTasks now auto+script there
  is no hint/gate/review boundary before cveFixes, so the run branch continues
  the loop straight to the cveFixes stop. → **9 invocations, 1 reducible
  `--complete`** (cveFixes, before it was scripted).
- **After cveFixes scripted (DONE — the current flow above):** cveFixes *runs*
  (review) instead of stopping on a hint, so its `--complete` disappears and its
  fix-PR commands surface in the same invocation's review output. It does *not*
  save an invocation, though: on a pass with CVEs still open the step fixes them,
  stays `in_progress` (nothing-pending completion), and stops at its review
  break; only on the post-merge re-run does it go clean, mark complete, and stop
  again — two real runs where the hint flow had one stop plus one `--complete`.
  → **~9 invocations, 0 reducible `--complete`**; qeValidation remains the sole
  irreducible one (external gate), and fbcProdUrls auto-completes via its
  verifier or stops with the terminal-message special case above.

  (Both counts include the `bundleShas` review stop added by Tier 2 item 5 — one
  irreducible pause for the SHA-bump PR to merge and the bundle to rebuild, not a
  `--complete`.)

Push and apply/watch stay human actions (Phases 3-4 shelved); the push-log and
step-type-aware trailer tell the operator exactly what to run between invocations.

## Script Contract

- **Exit 0** on success. Call `update_step` with "complete" before exiting.
- **Exit 0 without marking complete** for "needs human intervention."
  Same-step guard stops the conductor — **but only for `auto` steps.** The
  same-step guard lives in the `run` branch's loop,
  which only re-iterates for `auto` steps. A `review` step breaks the loop
  unconditionally after the script exits 0 (the `run`-branch review break), before
  the guard can apply, so it produces no "ran but didn't mark complete"
  message. On the next invocation `prev_step` is `""` (fresh process) and, if
  the step still isn't `complete`, the conductor re-runs the script's *entire*
  body. **This hazard only bites a review script that exits 0 *without* marking
  complete.** Every current review script self-completes at the end of its body
  (`fbc-catalog-update.sh:61`, `create-fbc-releases.sh:426`,
  `add-release-notes.sh:139`, `create-component-release.sh:445`, and the planned
  `cveFixes` wrapper, which marks complete on exit 0/2), so it is skipped on
  re-run (`find_next_step`), not re-executed. Where it still bites
  `cveFixes` is the *error-recovery* path: if the wrapper bails on a real
  `fix-all.sh` hard error (or the completion write to Jira fails), the step is
  left `in_progress` and the next invocation silently re-runs the per-repo CVE
  loop across 7 repos. The lifecycle change (see "Park status must be distinct") removes exactly
  that: a verifier-less `in_progress` step stops and requires `--refresh`
  rather than re-running. Until it lands, a review script that chooses to exit 0
  without completing must make its re-run a safe no-op.
- **Exit non-zero** only for real failures. Conductor exits.

**REVIEW stop must offer a redo path.** Review scripts mark themselves
`complete` before the conductor prints its "REVIEW" prompt
(the `run`-branch review break), so re-running `/autorelease` *accepts* the step
(`find_next_step` skips `complete`). The prompt today
prints only "re-run: /autorelease $VERSION" — no way to reject/redo — whereas
the gate/hint branch offers `--complete` (the gate|hint branch's --complete nudge). Reject *is*
possible via `--refresh STEP`, but it is undiscoverable from the prompt. The
review branch must print both paths:

- `Accept & continue: /autorelease $VERSION`
- `Redo this step: /autorelease $VERSION --refresh $NEXT_STEP` (then re-run)

Redoing a *create* step compounds with the duplicate-YAML caveat (see
"Caveat — re-running a create step duplicates its YAML" in Phase 1a): the
re-run emits a *new* dated/sequenced file rather than overwriting, so redoing
`componentStage` leaves two stage YAMLs and redoing `fbcStageReleases` can
leave up to 7 stale files (one per OCP version) alongside their replacements.
The operator must delete the superseded files before apply. The redo prompt
should say so.

**Redo target when a review step decorates an upstream auto step's artifact.**
`--refresh $NEXT_STEP` redoes only the review step itself. `releaseNotes`
(review) is a separate invocation from `componentStage` (also review since
815bcfd). If the defect the operator spots at the `releaseNotes` stop is in
the componentStage-produced YAML (e.g. wrong snapshot), `--refresh releaseNotes`
cannot fix it; the operator must `--refresh componentStage`.
The redo prompt (or its docs) must call this out.

Impact is bounded — review "create" steps write local YAMLs and do not push or
apply (Design Principle 3), so a wrongly-accepted step is still caught at the
later push/apply checkpoint — making this a medium-severity discoverability
gap, not a correctness bug. The longer-term true-gate fix (review scripts mark a
distinct park status — not `in_progress` — and the operator `--complete`s to
accept) reuses option (b)'s distinct status but is NOT covered by option (b)'s
dispatch rule (which keys off a verifier); it additionally needs the
verifier-less-review dispatch branch described under "Longer-term true-gate review model",
since a review step left parked today falls to the `run` branch and re-runs its
script.

Scripts that operate on external repos must:

- Verify repo is cloned and on correct branch. **This is currently violated by
  `bundle-image-update.sh` (bundleShas):** it commits to whatever HEAD is checked
  out (`:107` `git rev-parse --abbrev-ref HEAD`, no `release-0.X` checkout), so
  when an upstream step (cveFixes, versionLabels) leaves submariner-operator on a
  `fix-*` branch, bundleShas commits and prints its push onto that branch — see
  the cveFixes cross-step caveat. Any commit-to-current-HEAD step must
  checkout/verify `release-0.X` (or branch from `origin/release-0.X` like
  rpmLockfiles/versionLabels) and fail loudly otherwise.
- Verify clean working tree (or warn). **Note the "(or warn)" fallback is not
  achievable for cveFixes** — the dirty-tree check inside `fix-all.sh` hard-fails
  (see the cveFixes dirty-tree caveat).
- Return to original directory *and original branch* after completion — restoring
  the branch is what prevents the cross-step inheritance bug above; today the
  restore happens only on scripts' no-op paths.
- Append push/PR commands to `$AUTORELEASE_PUSH_LOG` if set (Phase 1c). For
  release-YAML steps this must include the load-bearing `make apply`/`make watch`
  lines, not just `git push` (see Phase 1c).

Apply scripts (Phase 3, verifier-based approach):

- Push the YAML commit + run `oc apply` (one-shot, exit immediately)
- Mark the pipeline-park status — a distinct `applied`/`awaiting` per option (b)
  of "Park status must be distinct" — not `complete`; the verifier handles
  completion. Prefer option (b) here: reusing `in_progress` with option (a)'s
  routing sends a `--refresh`ed apply step to its status-checking verifier
  instead of re-applying (see the option (a) caveat), so a distinct park status
  is what keeps both crash-recovery and `--refresh` re-apply working
- Verifier checks Release CR status on subsequent conductor runs
- Record release name and status in tracker — and the published-image ref(s),
  not just the snapshot, so the verifier's CR-absent disambiguation has a
  concrete artifact to probe once the ephemeral CR is reaped (see "Deriving the
  expected published image"). Component refs are snapshot-derivable and recorded
  at apply time; FBC's `index_image_resolved` only exists after the pipeline
  completes, so the verifier captures it from the CR the first time it sees
  `Succeeded` (it cannot be captured at apply time)

## Reference

Design influenced by the k8s-rebase gate architecture in
`openshift-eng/ai-helpers`. Key patterns integrated: STEP_VERIFIER
(gate verification), companion verifier + skill fallback (ecFixes),
boot-loader anti-satisficing (DAG walk prevents step-skipping).

**Alternative state backend:** `tracker.yaml` in git instead of Jira
comments. Would simplify staleness, crash recovery, and testing.
Higher upfront cost. Evaluate if Jira state management becomes painful.

**Release history (8 releases, 10 months):** Z-stream dominates 3:1.
Clean releases average 4 days (QE wait). Iterated releases average 39
days. FBC is flakiest (6 of 9 retries). Stage-to-prod: 0-8 days clean,
25-53 days iterated.

## Implementation Notes

### Known bugs

**No trap/cleanup in repo-modifying scripts — including on the SUCCESS path.**
Two distinct cases: (1) on *failure*, scripts leave repos on fix branches with
uncommitted changes (no trap restores state). (2) on *success* (the more
insidious case), branch-creating steps leave the repo checked out on the fix
branch: versionLabels leaves submariner-operator on `fix-version-labels-<mm>`
(restore only on the no-changes path). The external cve-fix tooling has the same
shape — `detect.sh:97-123` cuts `fix-<version>-cves-<date>`, and `fix-all.sh`
restores `ORIGINAL_REF` only on the no-CVE / env-abort path (`lib.sh:401`) — but
the shipped cveFixes *wrapper* neutralizes it by force-restoring each repo's
checkout after every `fix-all.sh` call (see "Future Script Candidates →
cveFixes", design point 3), so cveFixes does not leave a stranded repo. Because `bundle-image-update.sh`
(bundleShas) commits to whatever branch is checked out, this success-path
inheritance *used to* silently misroute the bundle-SHA commit onto a stale/merged
fix branch and print a wrong `git push origin <fix-branch>` — see the cveFixes
cross-step caveat and the Script Contract.

**Backstop SHIPPED (the commit-to-HEAD half of the fix).**
`bundle-image-update.sh` now refuses to commit onto a stray branch:
`assert_expected_branch` requires the checkout to be `release-<X.Y>` (or the
Konflux bundle bot branch `konflux-submariner-bundle-<X-Y>`, Y-stream step 3b),
and it runs unconditionally — both the conductor/scripted (explicit-version) path
and the manual auto-detect path. A leftover fix branch, detached HEAD, or
wrong-version branch now hard-stops with `cd … && git checkout release-<X.Y>`
guidance instead of silently misrouting. (The guard was initially scoped to the
explicit path on the theory that auto-detect derives the version *from* the branch
so "only the explicit path can misroute". Review found that false: the old
auto-detect `*)` fallback greps any `X-Y` token out of the branch name, so a real
tooling branch like `konflux-submariner-operator-0-25` — `konflux-component-setup.sh`'s
`BOT_BRANCH` — resolved to `0.25` and slipped past the scoped guard. The fix drops
that fallback (unknown branches now die at "Cannot auto-detect version") and makes
the assert unconditional; net ~9 fewer lines, and the guard no longer depends on
external fix-branch naming.) This defends the one repo bundleShas writes to
(submariner-operator) at the collision point, so the CONFIRMED data-corruption bug
can no longer fire even with the external cveFixes tooling unfixed. 10 tests
(`test-bundle-image-update.sh`, `make test-bundle`), sourcing guard added for
testability.

**Still open (the restore half).** One branch-creating step still strands a repo
where it lives: versionLabels (restore only on the no-changes path). The external
cve-fix tooling has the same shape (`fix-all.sh` restores `ORIGINAL_REF` only on
the no-CVE path), but the shipped cveFixes *wrapper* force-restores each repo on
every exit path — the pattern `tekton-task-refs-update.sh` demonstrates — so
cveFixes no longer strands at the conductor level even with the external tooling
unchanged. The backstop turns any residual stranding from silent corruption into
a clear stop. tektonTasks itself is already safe; it never strands a repo.

**FBC prod re-selects the snapshot instead of reusing the QE-validated stage
snapshot — FIXED (commit 8f8d70c).** `create-fbc-releases.sh` now has a `prod`
branch (`RELEASE_TYPE = "prod"`) that reads each per-OCP stage Release YAML's
`spec.snapshot` and reuses it, skipping the Konflux re-query entirely (the prod
block makes no cluster calls and needs no `oc` login). Previously it called
`verify_release` unconditionally and `verify-fbc-release.sh` picked the newest
push/incoming/retest snapshot per OCP by timestamp, so any OCP catalog that
rebuilt between stage and prod (FBC is the flakiest area) would ship a snapshot
QE never tested. Prod now matches the component path, which likewise reuses the
stage YAML's `spec.snapshot`.

**Remaining caveat (both prod paths) — lexical `tail -1` stage-YAML selection.**
Neither prod branch resolves the *applied/QE-approved* stage release; each picks
the newest stage YAML by lexical sort (`find "$STAGE_DIR" -name "…-stage-*.yaml"
| sort | tail -1`, in both `create-component-release.sh` and
`create-fbc-releases.sh`). This is safe *only when a single stage YAML exists per
OCP version*. If a retry produced a second stage YAML (`-02`), or a Z-stream left
multiple stage attempts in the directory, `tail -1` can pick a snapshot other
than the one QE validated (see "Caveat — re-running a create step duplicates its
YAML" in Phase 1a). Lower-risk than the original defect — `verify-fbc-release.sh`
still checked bundle/component SHAs + event-type + tests at stage time, and the
review stop + manual apply mean no silent auto-apply — but still worth hardening.
**Follow-up:** resolve the snapshot from the applied/QE-approved Release CR, or
fail when more than one stage-YAML candidate is present, rather than trusting
lexical order.

**Jira outage zeroes state — FIXED (`find_next_step`'s fetch guard).** The
single-fetch cache used to swallow the acli exit code
(`all_comments=$(acli ... 2>/dev/null || true)`), making a failed fetch (auth
blip, network, rate limit) indistinguishable from a tracker with zero
completed steps: `step_statuses` came back empty and `find_next_step` treated
**every** step as incomplete, re-dispatching from the top of `STEP_ORDER`.
This was not merely a wrong `/release-ls` — the entire DAG walk's correctness
rests on this one fetch, and the failure mode is **re-executing steps**,
including scripts that create commits and push. It was tolerable only because
every step is idempotent (worst case a wasted push), but would have become
dangerous at Phase 3, which adds `oc apply` (duplicate Release CRs, wrong
snapshots) to the re-dispatch blast radius. Now fixed: the acli exit code is
captured separately (`... ) || fetch_rc=$?`) and a nonzero fetch aborts the
walk with "Could not read tracker state from Jira" instead of proceeding.
A second guard closes the exit-0 gap: an acli success can still emit empty or
truncated output (e.g. a cut-off `--paginate` response), which would look like
zero completed steps just as a failed fetch would. The payload is now
validated with `jq -e 'type=="array"'`, which rejects empty output, a bare
`null`, a JSON object, and garbled non-JSON alike — anything but the JSON array
acli returns on success aborts the walk. A genuinely empty tracker (fresh
release, no STEP_DATA comments) is the one safe case — it returns exit 0 *and*
the JSON array `[]`, which passes both guards and proceeds normally. This was a
hard prerequisite for any cluster-writing step.

**But `_resolve_version` is a second Jira read path that still swallows.** The
2-segment entry point (`/autorelease 0.25`, the 2-segment version resolution) resolves
to a patch version via `_resolve_version`, whose strategy 1 uses the very
pattern the fix above condemns: `tracker_result=$(query_jira ... 2>/dev/null) ||
tracker_result=""` (`_resolve_version`), then falls through to strategies 2-4
(local stage/prod YAMLs, GitHub Releases, default `.0`) when it is empty.
`query_jira` genuinely `return 1`s after retries on a hard outage, so a
transient blip that trips only strategy 1 silently picks a version from the
GitHub/local heuristics instead of the tracker's intended patch. The downstream
`find_release_tracker` gate provides only *partial*
safety: it aborts if the resolved version has no tracker, but if the
mis-resolved version *coincidentally* has its own tracker (e.g. 0.25.2's tracker
just created while 0.25.1's stage YAML still reads in-progress), the hardened
walk then faithfully drives the *wrong* release's tracker. Resolve for
consistency with the "correctness rests on the fetch" philosophy: harden
strategy 1 to distinguish a hard `query_jira` failure (nonzero exit → abort with
the same "Could not read tracker state from Jira" message) from a
successful-but-no-match query (fall through to strategies 2-4). The trade-off is
that this weakens the resolver's ability to operate during a genuine Jira
outage; the alternative is to document strategies 2-4 as deliberate
Jira-independent fallbacks and accept the narrow mis-resolution window.

**Jira write failure reports false success (write path not hardened).** The
read path above aborts the walk on any failed/garbled fetch, but the symmetric
*write* path does not. `update_step` is best-effort and returns 0 even when
`_add_comment` fails (`update_step`/`_update_step_impl`, asserted by
`test-jira-tracker.sh:316-318`); it emits only a stderr warning. The conductor
then reports success regardless: the run path prints `✓ script succeeded` on script
exit code alone (the `run` branch) and the verifier path prints
`✓ verified externally` before calling `update_step` (the gate|hint verifier-complete write).
Because Jira then has no record, the next `find_next_step` still sees the step
incomplete: run steps trip the same-step guard (`✓ script succeeded` then `⚠️ ran but
didn't mark complete`, and the script re-runs next invocation — with its
commit/push, and eventually Phase 3 `oc apply`, side effects); verifier steps
skip re-verification via the `verified_steps` guard (checked in the `gate|hint` branch,
which exists to prevent an infinite verifier loop, not to address write
integrity) and fall straight to a stop-with-hint — so the operator sees
`✓ verified externally` immediately followed by a stop for the same step,
within one run. Fix (preferred, contract-preserving). **All three conductor
completion writes converge on the same remedy — re-read tracker state — because
checking `update_step`'s exit code cannot detect a write failure:** both
`update_step` *and* the inner `_update_step_impl`
swallow the `_add_comment` failure and `return 0`.
A "strict wrapper that aborts on nonzero" therefore has nothing to test — the
nonzero never propagates. The only reliable signal is the tracker's own state
after the write. So harden each path conductor-only by re-reading and withholding
the success line unless the step now reports `complete`, leaving `update_step`'s
best-effort return-0 contract and its test
(`test-jira-tracker.sh:316-318`) intact:

- **Verifier path (the gate|hint verifier-complete write)** is a genuine conductor write —
  `update_step` is called directly by the conductor. After it returns, re-read
  the step (e.g. via `get_step`) and withhold the `✓ verified externally` line —
  or abort with "could not record completion in Jira — check auth/network before
  re-running" — unless the step now shows `complete`. (Do **not** rely on a
  nonzero return from `update_step`; per above, there isn't one.)
- **Run path (auto steps)** has NO conductor write to harden: the `run`-branch `✓ script succeeded` line
  is an `echo` gated on the script's exit code alone (as noted above), and the
  actual completion write lives *inside* the nine scripts
  (`create-component-release.sh:445`, `bundle-image-update.sh:561`, …), which the
  conductor invokes in a subshell that returns only an exit code. Same remedy:
  the conductor **re-reads tracker state after the script exits** and withholds
  `✓ script succeeded` (the `run` branch) unless the step now shows `complete`. For
  auto steps a swallowed write is *also* caught on the next loop iteration by the
  same-step guard (the `run` branch, `⚠️ ran but didn't mark complete`),
  but that guard is a within-run backstop only — it compares against `prev_step`,
  reset to `""` each process — so the re-read is still
  needed to fail on the *first* invocation rather than only on a chained re-run.
- **Review path** is a distinct, worse case the same-step guard does **not**
  cover. A review-level `run` step prints `⏸ REVIEW` and `break`s at
  the `run`-branch review break — *before* the `✓ script succeeded` echo and before
  the loop can re-iterate — so the same-step guard at the top of the `run` branch
  never sees it repeat, and on the operator's next `/autorelease` the
  step (still not `complete`) is re-selected and its create script **runs again**,
  emitting a *duplicate sequenced YAML* (generate-fbc-release.sh:74-81,
  generate-component-release.sh:116-121,166-173 bump the `-NN` suffix rather than
  overwrite). fbcStageReleases, componentProd, and fbcProdReleases are the
  at-risk steps. Remedy (conductor-only): place the tracker re-read **ahead of
  the review `break`** and make the `⏸ REVIEW` banner conditional — if
  the step now shows `complete`, print REVIEW and break as today; if it does not,
  print a distinct "⚠️ could not record completion in Jira — check auth/network,
  do NOT re-run yet" and stop, so a swallowed write never invites the duplicate
  re-run. A return channel from the scripts would also work but touches all nine
  scripts, so it is not conductor-only.
- **Override path (`handle_step_override`, invoked
  pre-loop)** is the third genuine conductor write, and the worst of the three
  for silent failure. `--complete`/`--refresh` call `update_step` directly, then
  `handle_step_override` unconditionally prints "Step '$step' marked as $action" and `return 0`
  regardless of whether the write landed — and unlike the verifier and run paths,
  there is **no in-run contradiction**: the process exits immediately
  right after the override, so a false "marked as complete" is only detectable
  on the *next* `/autorelease` invocation, when the step reappears as not-done.
  Harden it symmetrically: after the `update_step` in `handle_step_override`, re-read the step and
  only print the confirmation if it now matches `$action` (else warn "could not
  record override in Jira — check auth/network and re-run"). This matters most for
  **qeValidation**, whose *only* completion path is a human `--complete` (no
  script, no verifier) — a swallowed write there silently strands the whole
  prod half of the release behind an apparently-satisfied gate.

**Do not** simply give `update_step` a global nonzero-on-write-failure return:
all nine `[ -n TRACKER ] && update_step ... in_progress` AND-list call sites
(`bundle-image-update.sh:538`, `create-component-release.sh:422`,
`create-fbc-releases.sh:414`, `fbc-catalog-update.sh:21`,
`configure-downstream.sh:84`, `add-release-notes.sh:66`,
`konflux-bundle-setup.sh:718`, `rpm-lockfile-update.sh:319`,
`update-version-labels.sh:313`) — plus their bare `complete` calls (e.g.
`bundle-image-update.sh:561`) — would then exit their script under `set -e` on a
transient Jira blip (the command after the final `&&` is not exempt), tripping
the conductor's `run`-branch failure path and converting
best-effort tracking into mandatory-intervention-after-every-blip (the same harm
warned against under "Park status must be distinct"). If that contract change is made
anyway, wrap each tracker write as `update_step ... || true` (optionally still
inside the existing `[ -n TRACKER ] && ...` guard) and update
`test-jira-tracker.sh:316-318`. Converting the AND-lists to
`if [ -n TRACKER ]; then ... fi` blocks does **not** achieve this: under `set -e`
a failing `update_step` as the last statement of an if-then body exits the script
exactly as it does at the end of an AND-list — the `if` form only changes the
empty-TRACKER case (it returns 0 where the AND-list returns 1). Only `|| true`
restores best-effort behavior. At minimum, do not print
`✓ script succeeded`/`✓ verified externally` when the tracker write did not succeed (for
the run path, that means the re-read check above). Same hard prerequisite as the
read-path fix for any cluster-writing step.

**Dead `manual` dispatch branch.** `find_next_step` sets
`NEXT_REASON=manual` only when a step has neither `gate` level, nor a
`STEP_SCRIPT`, nor a `STEP_SKILL_HINT` (`find_next_step`). Every
step in the DAG has at least one of those, so the `manual)` arm
is unreachable today. Harmless, but it should
either be removed or kept deliberately as a guard for future step
definitions — right now it reads as a supported path that never runs.

**No concurrency guard.** Two `/autorelease` invocations for the same
version race on repo directories and Jira tracker. *Caveat (not a required
fix):* the blast radius is wider than one version, because several shared
artifacts key on major.minor only — the release-0.X upstream branch and the
per-minor Konflux snapshots (`submariner-0-25-*`) that bundle-image-update.sh
`find_snapshot` (`VERSION_DASH`) and `verify_ecFixes` (`dash_mm`) select — so
concurrent runs for two *different Z-stream patches of the same minor* (e.g.
0.25.3 and 0.25.4) can also collide on those shared inputs, not just two runs
of the identical version.

**The dispatch loop is partially tested; the routing skeleton still isn't.**
Most of the 167 tests run with `_AUTORELEASE_TESTING=true`, which skips the
main `while true` block. They cover `find_next_step`'s step-selection logic (the
for-loop over `STEP_ORDER`), the STEP_VERIFIER *map* (the tests assert the
mappings, not the verifier function bodies — those shell out to git/oc/gh and
are never invoked under `_AUTORELEASE_TESTING`), `handle_step_override`,
`handle_close`, and — now extracted outside the main guard so it *is* covered
— `try_auto_verify` (the gate/hint auto-verify-and-chain decision, incl. the
once-per-run anti-loop guard). The fetch+parse+abort block at the top of
`find_next_step` is **also now tested**: dedicated cases unset
`_AUTORELEASE_TESTING` in a subshell, mock `acli`, and assert the outcomes —
valid read parses and feeds the DAG, while a failed fetch / empty output / bare
`null` / JSON object / garbled payload each refuse with `exit 1`, and a
genuinely empty tracker (`[]`) proceeds. (Those tests surfaced a real bug:
`jq empty` exits 0 on *empty input* — and also on `null` and objects — so those
cases slipped past the payload guard and would have re-dispatched from the top
of `STEP_ORDER`; the guard is now `[ -z ]` for the empty string plus
`jq -e 'type=="array"'`, which rejects `null`, objects, and garbled JSON while
accepting only the array acli returns.) Still uncovered inside the main block: the gate/hint/run/manual
routing itself, the same-step guard, the failure `exit 1` path, the review
break, and the EXIT-trap push summary — they run only in production. Any change
to that routing skeleton (notably the Phase 3 verifier-on-park-status routing)
remains unverifiable by the suite. **Prerequisite for Phase 3:** extract the
dispatch loop into a testable function (or add an integration harness that
drives the real main block with a stubbed `acli`/`oc`), so the new routing has
coverage before it gains the power to `oc apply`.

### Multi-repo environment

The conductor assumes 7 repos are pre-cloned at conventional paths.
Future improvements (implement when pain is real, not before):

- **Auto-clone** missing repos (`_ensure_repo` pattern from k8s-rebase)
- **Configurable paths** via env var `SUBMARINER_REPOS_BASE`
- **Preflight check** verifying repos exist before the DAG walk
- **Per-step repo requirements** (only check repos the next step needs)

### Jira round-trip per loop iteration

Every `find_next_step` call fetches all tracker comments. During
auto-chaining, that's one API call per step. Optimization: cache within
a single conductor run, invalidate after `update_step`.

### Chain hazards: rebuild boundaries the auto-chain can cross silently

Two auto-chain edges cross a Konflux rebuild boundary that neither existing
stop mechanism (the propagation-gap failure/exit-0 paths, above) protects,
because the downstream script runs *successfully* against a stale-but-valid
snapshot. The first (bundleShas → componentStage) is now **MITIGATED** (Tier 2
item 5, below); the second must still be closed before Phase 4 auto-push.

**bundleShas → componentStage (MITIGATED — Tier 2 item 5).** The earlier framing —
"the steps operate on different artifacts referencing the same snapshot, no
rebuild dependency between them" — was wrong, and it contradicts the
propagation-gap table (bundleShas needs "push + PR merge + bundle rebuild").
`bundleShas` writes updated component SHAs into the operator-repo bundle CSV as
a *local, unpushed* commit (`bundle-image-update.sh:489`); the
`submariner-bundle` image in every existing snapshot was built from the OLD
CSV. A correct release needs push + PR merge + bundle rebuild + a new snapshot
first. But both steps are `auto` (AUTOMATION_LEVEL), so the conductor
chains them back-to-back in one invocation with nothing in between, and
`componentStage`'s check (`verify-component-release.sh:70-196`) only confirms 9
components are present and tests pass — it never validates the bundle's
`relatedImages` SHAs or that the snapshot postdates the bundleShas merge.
Result: `componentStage` silently generates and commits a stage Release YAML
pointing at a pre-rebuild (stale) bundle. The thin backstop is that the YAML is
applied by a *later* manual step (Step 10), not immediately — but a human
reviewing the commit is unlikely to notice, since the snapshot is valid and
passes tests.

**Fix (shipped):** two complementary levers. (1) `bundleShas` is now `review` in
`AUTOMATION_LEVEL`, so the conductor *stops* at bundleShas — the human pushes/merges
and waits for the rebuild before `componentStage` runs. (2) An in-script
`assert_bundle_rebuilt` precondition in `create-component-release.sh` (called in
`main`, stage-only) backstops a *direct* invocation that never consults the DAG:
it compares the chosen snapshot's `submariner-bundle` *image digest* against the
`bundleShas`-recorded snapshot's and hard-STOPs on equality (no rebuild happened).
This digest-change proxy replaced the originally-planned `relatedImages` SHA
comparison — simpler (two `oc get snapshot` reads, no image pull) and equally
robust against the one realistic false-pass (an unrelated intervening component
push makes a new snapshot but leaves the bundle digest unchanged, so it's still
caught). The gate fails open on absent bookkeeping (no tracker / no recorded
snapshot / unreadable digest) so it never blocks on missing data.

A `STEP_VERIFIER`-style gate would have been **dead code under today's dispatch**:
`componentStage` owns a `STEP_SCRIPT`, so `find_next_step` routes it to the
`run` branch, which never consults `STEP_VERIFIER` (only the `gate|hint` branch
does) — which is exactly why the assertion lives *inside* the consumer's script.
The two levers are complementary, not interchangeable: the `review` flip inserts
a human stop but adds no SHA validation; the assertion validates the digest but
only fires when the script actually runs.

**upstreamRelease → bundleShas (guard before Phase 4).** One edge earlier, the
same class of hazard, hidden by a proxy: `verify_upstreamRelease`
clears the gate on tag *existence* alone, then
auto-chains into `auto`-level `bundleShas`, whose `find_snapshot`
(`bundle-image-update.sh:216-244`) takes the latest passing snapshot with no
guard that it postdates the tag/release-commit rebuild. A tag appearing on
GitHub does not imply Konflux has finished rebuilding the release-branch
components at the tagged commit — that rebuild is asynchronous and can lag the
tag. A stale-SHA pin requires a release-cut that pushes a new `release-0.X`
commit whose rebuild lags the tag (the Y-stream/version-bump case, not a plain
Z-stream tag on an already-built HEAD), so this is a reasoning/documentation
gap rather than a confirmed bug today; impact is bounded because `bundleShas`
only produces a reviewable commit/PR (push deferred to Phase 3/4). It becomes
materially dangerous once Phase 4 auto-push lands. Minimum: treat this as a
required guard before auto-push; stronger: have `find_snapshot` (or a
bundleShas pre-check) require the selected snapshot's component images resolve
to (or postdate) the tagged release commit, not merely be the latest passing.

## Execution Order

**Phase 1 — DONE.** --complete/--refresh, reorder, verifiers
(10 commits, 157 tests). Push summary is **DONE** — the post-chain pending-push
mechanism ships with a step-type-aware trailer: release-YAML steps emit `make
apply`/`make watch`, PR-based steps emit "After PRs merge", and both lines
print when one run produces both kinds of pending work (the two-flag design is
now defensive — its original trigger, bundleShas auto-chaining into
componentStage, was retired when Tier 2 item 5 flipped bundleShas to `review`).

**Phase 2 — DONE.** Bug fixes (configure-downstream tracker, rpm-lockfile
branch) + ecFixes verifier (1 commit, 29 lines).

**Quick wins — DONE.** Partial-completion bug fix + fbcCatalogUpdate script
(1 commit, 71 lines). 17/19 steps now automated (13 script-backed + 4
verifier-backed); only `tektonComponents` and the irreducible `qeValidation`
gate remain manual.

**fbcProdUrls terminal-message — DONE** (see "Terminal message + closeout").
The conductor prints "All release steps shipped" at the fbcProdUrls hint,
points at the prod-URL conversion, nudges "re-run once done to close the
release", and suppresses the misleading `--complete` nudge. Shipped alongside
dropping the blanket `75d` staleness rule for fbcProdUrls. The conversion is
done per-release at closeout: once the operator does it and re-runs,
`verify_fbcProdUrls` passes → the walk reaches `all_done` → auto-close resolves
the tracker. (The earlier `--final`/deferred-follow-up design was superseded by
this linear model — see "Terminal message + closeout".)

**Reprioritized (apply shelved):** the active order now leads with
trust/legibility/read-only robustness — see "Backlog: non-cluster
improvements". Of the write-automation completeness items, `tektonTasks` and
`cveFixes` have shipped; only `tektonComponents` remains valid in Tier 3,
after the tiny wins and `--dry-run`.

**tektonTasks (DONE)** — `scripts/tekton-task-refs-update.sh` bumps `.tekton`
task refs across the 5 component repos + FBC, wired as `STEP_SCRIPT`. Removed
the last Build-Readiness hint stop, enabling the 3-step auto chain
(rpmLockfiles → versionLabels → tektonTasks). It restores each repo's original
ref on every exit path — the same discipline the cveFixes wrapper now adopts.

**cveFixes wrapper (DONE)** — `scripts/cve-fixes-update.sh` wires shipyard's
cve-fix skill into `STEP_SCRIPT` as a `review`-gated `run` step. Eliminated the
last reducible `--complete` call (though not an invocation — see the progression
note). The cross-step branch hazard is closed on both sides — the shipped
`bundleShas` `assert_expected_branch` backstop, plus the wrapper force-restoring
each repo's checkout after every `fix-all.sh` call — so it needed no change to
the external tooling. Fuller than the old "~25-line" estimate (~300 lines + 32
tests): owns its 7-Go-repo list, calls `fix-all.sh` per repo, buckets by exit
code + fix-branch diff, and completes only when every repo is clean with nothing
pending. See the as-built record in "Future Script Candidates → cveFixes". A
Z-stream release now needs only the qeValidation `--complete` (irreducible
external team gate).

**Phase 3 (apply) SHELVED indefinitely** — no cluster write operations
(`oc apply`), by decision, for the foreseeable future (see Status). Retained
here only as a record. If it were ever revisited, two hard entry gates from
"Known bugs" would still apply: (1) the dispatch loop must become testable and
the verifier-on-park-status routing must have coverage before it gains
`oc apply` power (today the entire main block is skipped under
`_AUTORELEASE_TESTING`); (2) the `fbcProdReleases` prod path must resolve the
QE-approved snapshot robustly — stage-snapshot reuse is now in place (commit
8f8d70c), but the lexical `tail -1` stage-YAML selection should be hardened
(resolve from the applied Release CR, or fail on multiple candidates) before it
gains apply power.

**Phase 4 (auto-push) SHELVED** — out of scope under the hand-driven
direction: pushing commits/PRs stays a human action (the push-log tells the
operator exactly what to run). Kept as a record only. It would multiply the
blast radius of every upstream bug from "a wasted local run" to "an unwanted
push/PR/merge," and is only conceivable behind the same trust bar as Phase 3.

**Phase 6 (pipeline monitoring)** — read-only; would fold into Tier 2
verification gates / status tooling if pursued. Not currently planned.
