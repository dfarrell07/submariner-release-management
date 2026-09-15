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

# These sets are a ratchet, not permanent exceptions. A compatibility change
# must remove the entries it resolves. Adding an entry means adding new debt and
# should not be done merely to make this test pass. All sets must be empty when
# the compatibility plan is complete.
expected_argument_debt = expected_skills - {"autorelease"}
expected_slash_only_debt = {
    "add-fbc-ocp-version",
    "add-team-member",
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
    "release-ls",
    "rpm-lockfile-update",
    "update-version-labels",
}
expected_host_tool_debt = {"konflux-ci-fix"}
expected_terminal_read_debt = {"konflux-ci-fix"}
expected_shared_tmp_debt = {"konflux-ci-fix"}
expected_release_root_debt = {"learn-release", "release-ls"}
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
    has_slash_usage = re.search(rf"/{re.escape(name)}(?:\s|$)", text) is not None
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
