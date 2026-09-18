# Review Release Notes Issue: ${ISSUE_KEY}

You are reviewing whether Jira issue ${ISSUE_KEY} belongs in the
Submariner ${VERSION} release notes. These are Submariner component
releases — only issues with actual Submariner code or doc changes
belong here.

**Version mapping:** Submariner ${VERSION_MAJOR_MINOR} = ${ACM_VERSION}.

All evidence has been pre-fetched and is appended below. Your job
is to evaluate the evidence and decide KEEP or REMOVE.

**Default is KEEP.** This issue already passed deterministic filters
for component (Multicluster Networking or Documentation), addon
exclusion, and process task patterns. It is likely a real Submariner
issue. Only REMOVE if you find clear evidence it does NOT belong.

**Jira status lags reality.** The team does not reliably update
status, and the release process itself is what moves issues to
Done. Never use status or lack of fixVersion as a reason to remove.

## When to REMOVE

Remove for any of these specific reasons:

- **Cross-squad addon-only:** The issue has multiple components and
  the fix is ONLY in stolostron/submariner-addon (built separately).
  There must be no matching commits in submariner-io repos. Note:
  coincidental keyword matches in submariner-io repos do NOT count
  — only commits that address the specific problem described in the
  issue qualify. (See "Evaluating evidence" below.)

- **Not about Submariner:** The description is clearly about a
  non-Submariner system despite having MCN component. (Rare after
  deterministic filtering.)

- **No relevant corroborating evidence:** After evaluating all
  evidence sources (see below), none of them actually corroborate
  that code or docs for THIS issue shipped. This includes cases
  where keyword searches return hits but those hits address
  different work. A plausible Jira description alone is not
  sufficient. But be thorough first: check keyword variants, check
  for PRs that fix the described problem without referencing the
  Jira key, check if a related issue's PR also addresses this one.
  Only conclude "no relevant evidence" after exhausting these
  avenues.

## Evaluating evidence

Most git keyword hits are false positives — different work that
shares a keyword. For each commit, apply this test:

1. State the issue's goal in one sentence (what specific change?)
2. State what the commit does in one sentence
3. Is the commit implementing that goal — same problem, same
   approach — or is it different work that happens to produce
   a superficially similar outcome?

Only count a commit as evidence if #3 answers "same problem,
same approach." A commit that achieves a similar-sounding outcome
through a different mechanism for a different reason is NOT
evidence. Consider the commit's motivation, not just what it
changes — a commit made for linter compliance, security scanning,
or dependency updates is not implementing a feature even if it
modifies the same code area.

Use the full commit message and changed file paths to judge what
a commit does. File paths narrow the scope — a commit changing
`pkg/azure/` files is relevant to an Azure bug regardless of how
generically the commit message is worded.

When in doubt about relevance and there is no other evidence,
lean toward KEEP.

## Evaluating CVE issues

CVE fixes often have NO keyword-matchable commits. Instead,
check the "CVE-Specific Evidence" section:

1. **Go dependency version:** If the CVE specifies a fixed version
   (e.g., "gRPC >= 1.79.3"), compare against the version in
   go.mod. If installed version >= fix version, the CVE is fixed.

2. **GHSA commits:** A commit referencing a GHSA identifier may
   fix this CVE even if the CVE number differs. Check the GHSA
   summary — if it describes the same vulnerability, it counts.

3. **Go toolchain version:** For stdlib CVEs (crypto/tls, net/url,
   x509), the Go version determines whether the fix is included.
   Check the Go version in go.mod against the CVE's fix version.

4. **RPM lockfile changes:** For non-Go CVEs (e.g., Python urllib3
   in base images), RPM lockfile updates indicate dependency fixes.

5. **Builder image:** The FROM line in Dockerfile.konflux shows
   which Go toolchain builds the component.

6. **OSV vulnerability check:** If present, this is the definitive
   signal. "NOT affected (fixed)" means KEEP. "STILL AFFECTED"
   means REMOVE — the installed version does not include the fix.

7. **Base image CVEs (e.g., Python urllib3 in a Go component):**
   The CVE is in the container base image RPMs, not in the Go
   source code. RPM lockfile regeneration commits are sufficient
   evidence — they pull in updated packages from Red Hat repos.
   Don't reject just because the language doesn't match.

For CVEs, KEEP if OSV says "NOT affected" or the dependency
version meets the fix threshold. REMOVE if OSV says "STILL
AFFECTED." If no OSV result, fall back to dependency version
comparison and lean toward KEEP when uncertain.

## When to KEEP

Keep if ANY of the following:

- DFBUGS tracker exists with status MODIFIED or ON_QA
- GitHub links found in Jira comments (often the best evidence)
- Commits or PRs found in submariner-io repos that address the
  specific problem described in the issue (not just keyword overlap)
- **Merged** PRs found in stolostron/rhacm-docs (for Documentation
  issues) targeting a branch for this release version (e.g.,
  `2.14_stage` for Submariner 0.21) — open/unmerged PRs or PRs
  targeting a different version branch are NOT evidence of shipped work
- You are uncertain AND some relevant evidence exists — err on
  inclusion

## Decision

Write exactly one JSON object to `${DECISION_FILE}`:

```json
{
  "issue_key": "${ISSUE_KEY}",
  "decision": "KEEP",
  "reason": "One-line reason grounded in the evidence"
}
```

Use only `KEEP` or `REMOVE` for `decision`. Keep `reason` to one
non-empty line. Do not modify the stage YAML or Git repository; the
apply command validates this file and owns all release-note changes
and commits. If the evidence is unclear, choose `KEEP`.
