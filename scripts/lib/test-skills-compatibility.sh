#!/bin/bash
# Static compatibility contract for the shared Claude and Codex skills.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import os
import re
import sys
from pathlib import Path

import yaml


root = Path(sys.argv[1])
skills_root = root / "skills"
codex_skills = root / ".agents" / "skills"
passed = 0
failed = 0


def check(condition: bool, label: str, detail: str = "") -> None:
    global passed, failed
    if condition:
        print(f"  ✓ {label}")
        passed += 1
    else:
        print(f"  ✗ {label}")
        if detail:
            print(f"    {detail}")
        failed += 1


def skill_names(path: Path) -> list[str]:
    if not path.is_dir():
        return []
    return sorted(entry.name for entry in path.iterdir() if entry.is_dir())


def compare_debt(label: str, actual: set[str], expected: set[str]) -> None:
    missing = sorted(expected - actual)
    added = sorted(actual - expected)
    details = []
    if missing:
        details.append("remove resolved entries from the expected debt set: " + ", ".join(missing))
    if added:
        details.append("new debt: " + ", ".join(added))
    check(actual == expected, label, "; ".join(details))


expected_skills = {
    "add-fbc-ocp-version",
    "add-release-notes",
    "add-team-member",
    "autorelease",
    "bundle-image-update",
    "configure-downstream",
    "create-component-release",
    "create-fbc-release",
    "create-release-tracker",
    "fbc-update",
    "get-fbc-urls",
    "konflux-bundle-setup",
    "konflux-ci-fix",
    "konflux-component-setup",
    "learn-release",
    "release-ls",
    "rpm-lockfile-update",
    "update-version-labels",
}

portable_delegates = {
    "add-fbc-ocp-version": "scripts/add-fbc-ocp-version.sh",
    "autorelease": "scripts/autorelease.sh",
    "bundle-image-update": "scripts/bundle-image-update.sh",
    "configure-downstream": "scripts/configure-downstream.sh",
    "create-component-release": "scripts/create-component-release.sh",
    "create-fbc-release": "scripts/create-fbc-releases.sh",
    "create-release-tracker": "scripts/create-release-tracker.sh",
    "fbc-update": "scripts/fbc-catalog-update.sh",
    "get-fbc-urls": "scripts/get-fbc-urls.sh",
    "konflux-bundle-setup": "scripts/konflux-bundle-setup.sh",
    "konflux-component-setup": "scripts/konflux-component-setup.sh",
    "release-ls": "scripts/release-status.sh",
    "rpm-lockfile-update": "scripts/rpm-lockfile-update.sh",
    "update-version-labels": "scripts/update-version-labels.sh",
}
portable_knowledge_skills = {"learn-release"}

# These sets are a ratchet, not permanent exceptions. A compatibility change
# must remove the entries it resolves. Adding an entry means adding new debt and
# should not be done merely to make this test pass. All sets must be empty when
# the compatibility plan is complete.
expected_argument_debt = {
    "add-release-notes",
    "add-team-member",
    "konflux-ci-fix",
}
expected_slash_only_debt = {
    "add-team-member",
    "konflux-ci-fix",
}
expected_host_tool_debt = {"konflux-ci-fix"}
expected_terminal_read_debt = {"konflux-ci-fix"}
expected_shared_tmp_debt = {"konflux-ci-fix"}
expected_release_root_debt: set[str] = set()
expected_target_root_debt = {"add-team-member"}
expected_model_cli_debt = {"scripts/release-notes/review-issue.sh"}

print("=== Shared Skill Discovery ===")
check(codex_skills.is_symlink(), ".agents/skills is a symlink")
if codex_skills.is_symlink():
    check(os.readlink(codex_skills) == "../skills", "symlink target is ../skills")
    check(
        codex_skills.resolve() == skills_root.resolve(),
        "symlink resolves to the canonical skills directory",
    )

canonical_names = skill_names(skills_root)
discovered_names = skill_names(codex_skills)
check(set(canonical_names) == expected_skills, "canonical inventory contains the expected 18 skills")
check(discovered_names == canonical_names, "Codex and Claude inventories are identical")

print("\n=== Frontmatter and References ===")
seen_names: set[str] = set()
skill_text: dict[str, str] = {}
frontmatter_ok = True
references_ok = True
reference_errors: list[str] = []
references_by_skill: dict[str, set[str]] = {}

for directory_name in canonical_names:
    skill_file = skills_root / directory_name / "SKILL.md"
    if not skill_file.is_file():
        frontmatter_ok = False
        reference_errors.append(f"missing {skill_file.relative_to(root)}")
        continue

    text = skill_file.read_text(encoding="utf-8")
    skill_text[directory_name] = text
    lines = text.splitlines()
    try:
        if not lines or lines[0] != "---":
            raise ValueError("opening --- delimiter is missing")
        closing = lines.index("---", 1)
        metadata = yaml.safe_load("\n".join(lines[1:closing]))
        if not isinstance(metadata, dict):
            raise ValueError("frontmatter is not a mapping")
        name = metadata.get("name")
        description = metadata.get("description")
        if name != directory_name:
            raise ValueError(f"name {name!r} does not match directory")
        if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9-]{1,64}", name):
            raise ValueError("name is not a valid Agent Skills name")
        if not isinstance(description, str) or not description.strip():
            raise ValueError("description is empty")
        if name in seen_names:
            raise ValueError(f"duplicate name {name!r}")
        seen_names.add(name)
    except (ValueError, yaml.YAMLError) as error:
        frontmatter_ok = False
        reference_errors.append(f"skills/{directory_name}/SKILL.md: {error}")

    references = set(re.findall(r"\b(scripts/[A-Za-z0-9_./-]+\.(?:sh|py))", text))
    references_by_skill[directory_name] = references
    for reference in references:
        referenced_path = root / reference
        if ".." in Path(reference).parts or not referenced_path.is_file():
            references_ok = False
            reference_errors.append(f"skills/{directory_name}/SKILL.md: missing {reference}")

check(frontmatter_ok, "all SKILL.md frontmatter is valid")
check(seen_names == expected_skills, "frontmatter names are unique and match their directories")
check(references_ok, "all referenced local scripts exist")
for error in reference_errors:
    print(f"    {error}")

delegate_mismatches = []
for name, expected_script in portable_delegates.items():
    actual_scripts = references_by_skill.get(name, set())
    if actual_scripts != {expected_script}:
        delegate_mismatches.append(
            f"{name}: expected only {expected_script}, found {sorted(actual_scripts)}"
        )
check(
    not delegate_mismatches,
    "portable delegates reference exactly their intended backing script",
    "; ".join(delegate_mismatches),
)

invocation_mismatches = []
for name in portable_delegates.keys() | portable_knowledge_skills:
    text = skill_text.get(name, "")
    has_claude = re.search(
        rf"/release-management:{re.escape(name)}(?:\s|$)", text
    ) is not None
    has_codex = re.search(
        rf"\$release-management:{re.escape(name)}(?:\s|$)", text
    ) is not None
    if not has_claude or not has_codex:
        invocation_mismatches.append(name)
check(
    not invocation_mismatches,
    "portable skills document Claude and Codex invocation",
    ", ".join(sorted(invocation_mismatches)),
)

bare_public_invocations = []
for public_doc in (root / "README.md", root / ".claude" / "SKILLS.md"):
    text = public_doc.read_text(encoding="utf-8")
    for name in expected_skills:
        if re.search(rf"/{re.escape(name)}(?:\s|`|$)", text):
            bare_public_invocations.append(
                f"{public_doc.relative_to(root)}: /{name}"
            )
check(
    not bare_public_invocations,
    "public Claude examples use the plugin namespace",
    ", ".join(sorted(bare_public_invocations)),
)

print("\n=== Compatibility Debt Ratchet ===")
actual_argument_debt = {name for name, text in skill_text.items() if "$ARGUMENTS" in text}
actual_host_tool_debt = {name for name, text in skill_text.items() if "AskUserQuestion" in text}
actual_terminal_read_debt = {
    name for name, text in skill_text.items() if re.search(r"(?m)^\s*read\s+-[^\n]*p", text)
}
actual_shared_tmp_debt = {name for name, text in skill_text.items() if "/tmp/konflux-" in text}
actual_release_root_debt = {
    name for name, text in skill_text.items() if "~/konflux/submariner-release-management" in text
}
actual_target_root_debt = {
    name for name, text in skill_text.items() if re.search(r"(?m)^\s*cd ~/konflux/", text)
}

actual_slash_only_debt: set[str] = set()
for name, text in skill_text.items():
    has_slash_usage = re.search(
        rf"/(?:release-management:)?{re.escape(name)}(?:\s|$)", text
    ) is not None
    has_codex_usage = re.search(
        rf"\$(?:release-management:)?{re.escape(name)}(?:\s|$)", text
    ) is not None
    if has_slash_usage and not has_codex_usage:
        actual_slash_only_debt.add(name)

actual_model_cli_debt: set[str] = set()
for script in (root / "scripts").rglob("*.sh"):
    for line in script.read_text(encoding="utf-8").splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        if re.search(r"(?:^|[\s=(])(?:claude\s+-p|codex\s+exec)(?:\s|$)", line):
            actual_model_cli_debt.add(str(script.relative_to(root)))
            break

compare_debt("Claude $ARGUMENTS debt has not grown", actual_argument_debt, expected_argument_debt)
compare_debt("slash-only usage debt has not grown", actual_slash_only_debt, expected_slash_only_debt)
compare_debt("host-specific tool debt has not grown", actual_host_tool_debt, expected_host_tool_debt)
compare_debt("terminal prompt debt has not grown", actual_terminal_read_debt, expected_terminal_read_debt)
compare_debt("shared temporary-state debt has not grown", actual_shared_tmp_debt, expected_shared_tmp_debt)
compare_debt("fixed release-root debt has not grown", actual_release_root_debt, expected_release_root_debt)
compare_debt("fixed target-root debt has not grown", actual_target_root_debt, expected_target_root_debt)
compare_debt("nested model-CLI debt has not grown", actual_model_cli_debt, expected_model_cli_debt)

debt_count = sum(
    len(items)
    for items in (
        actual_argument_debt,
        actual_slash_only_debt,
        actual_host_tool_debt,
        actual_terminal_read_debt,
        actual_shared_tmp_debt,
        actual_release_root_debt,
        actual_target_root_debt,
        actual_model_cli_debt,
    )
)
print(f"\nKnown compatibility debt entries: {debt_count} (must reach 0)")
print(f"Checks passed: {passed}; failed: {failed}")
sys.exit(1 if failed else 0)
PY
