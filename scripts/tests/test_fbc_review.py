"""Adversarial contract checks discovered during the OCP 5 review."""

import isolate_git  # noqa: F401  (must precede any git use)
import copy
import json
import os
from pathlib import Path
import tempfile
import yaml
import unittest
import subprocess


import test_fbc_onboarding as onboarding_tests
from test_fbc_onboarding import ROOT, mod

BASE = "registry.redhat.io/openshift5/ose-operator-registry-rhel9:v5.0"


def pipeline(event):
    app = "submariner-fbc-5-0"
    paths = [f".tekton/{app}-{e}.yaml" for e in ("push", "pull-request")]
    paths += [".tekton/images-mirror-set.yaml", "catalog-5-0/***", "catalog.Dockerfile"]
    return {
        "apiVersion": "tekton.dev/v1",
        "kind": "PipelineRun",
        "metadata": {
            "name": f"{app}-on-{event}",
            "namespace": "submariner-tenant",
            "labels": {
                f"appstudio.openshift.io/{k}": app for k in ("application", "component")
            },
            "annotations": {
                "pipelinesascode.tekton.dev/cancel-in-progress": str(
                    event == "pull-request"
                ).lower(),
                "pipelinesascode.tekton.dev/on-cel-expression": f'event == "{event.replace("-", "_")}" && target_branch == "main" && ('
                + " || ".join(f'"{p}".pathChanged()' for p in paths)
                + ")",
            },
        },
        "spec": {
            "pipelineSpec": yaml.safe_load(
                (ROOT / "scripts/tests/fixtures/fbc-pipeline-spec.yaml").read_text()
            ),
            "taskRunTemplate": {"serviceAccountName": f"build-pipeline-{app}"},
            "params": [
                {"name": "build-platforms", "value": mod.PLATFORMS},
                {"name": "dockerfile", "value": "catalog.Dockerfile"},
                {"name": "git-url", "value": "{{source_url}}"},
                {"name": "revision", "value": "{{revision}}"},
                {
                    "name": "output-image",
                    "value": f"quay.io/redhat-user-workloads/submariner-tenant/{app}:"
                    + ("on-pr-" if event == "pull-request" else "")
                    + "{{revision}}",
                },
                {
                    "name": "image-expires-after",
                    "value": "5d" if event == "pull-request" else "",
                },
                {
                    "name": "build-args",
                    "value": ["INPUT_DIR=catalog-5-0", f"OPM_IMAGE={BASE}"],
                },
            ],
        },
    }


class PipelineContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / ".tekton").mkdir()
        self.pair = {event: pipeline(event) for event in ("push", "pull-request")}

    def validate(self):
        for event, data in self.pair.items():
            mod.save(self.root / ".tekton" / f"submariner-fbc-5-0-{event}.yaml", data)
        mod.validate_pipelines(self.root, "5-0", BASE)

    def test_valid_inline_and_resolved_pipeline_pairs(self):
        self.validate()
        definition = self.pair["push"]["spec"].pop("pipelineSpec")
        self.pair["push"]["spec"]["pipelineRef"] = {"name": "fbc-builder"}
        mod.save(
            self.root / ".tekton/fbc-builder.yaml",
            {
                "apiVersion": "tekton.dev/v1",
                "kind": "Pipeline",
                "metadata": {"name": "fbc-builder"},
                "spec": definition,
            },
        )
        self.validate()

    def test_upstream_build_image_index_params_are_accepted(self):
        # build-image-index 0.4 declares neither COMMIT_SHA nor IMAGE_EXPIRES_AFTER;
        # upstream fbc-builder and stolostron common-fbc omit both.
        for data in self.pair.values():
            task = next(
                task
                for task in data["spec"]["pipelineSpec"]["tasks"]
                if task["name"] == "build-image-index"
            )
            task["params"] = [
                param
                for param in task["params"]
                if param["name"] not in ("COMMIT_SHA", "IMAGE_EXPIRES_AFTER")
            ]
        self.validate()
        task["params"] = [p for p in task["params"] if p["name"] != "IMAGES"]
        with self.assertRaisesRegex(ValueError, "build-image-index"):
            self.validate()

    def test_conflicting_build_args_rejected(self):
        for argument in ("INPUT_DIR=catalog-4-22", "OPM_IMAGE=wrong:v4.22"):
            with self.subTest(argument=argument):
                original = copy.deepcopy(self.pair)
                self.pair["push"]["spec"]["params"][-1]["value"].append(argument)
                with self.assertRaises(ValueError):
                    self.validate()
                self.pair = original

    def test_service_account_substring_is_insufficient(self):
        self.pair["push"]["spec"]["taskRunTemplate"]["serviceAccountName"] += "-wrong"
        with self.assertRaises(ValueError):
            self.validate()

    def test_wrong_event_is_rejected(self):
        key = "pipelinesascode.tekton.dev/on-cel-expression"
        self.pair["pull-request"]["metadata"]["annotations"][key] = self.pair[
            "pull-request"
        ]["metadata"]["annotations"][key].replace("pull_request", "push")
        with self.assertRaises(ValueError):
            self.validate()

    def test_disabled_or_negated_triggers_are_rejected(self):
        key = "pipelinesascode.tekton.dev/on-cel-expression"
        self.pair["push"]["metadata"]["annotations"][key] += " && false"
        with self.assertRaises(ValueError):
            self.validate()

    def test_duplicate_architecture_is_rejected(self):
        self.pair["push"]["spec"]["params"][0]["value"] = mod.PLATFORMS + [
            mod.PLATFORMS[0]
        ]
        with self.assertRaises(ValueError):
            self.validate()

    def test_push_image_must_not_expire(self):
        params = self.pair["push"]["spec"]["params"]
        next(p for p in params if p["name"] == "image-expires-after")["value"] = "5d"
        with self.assertRaisesRegex(ValueError, "must not expire"):
            self.validate()

    def test_inline_expiry_default_and_unknown_reference_default(self):
        spec = self.pair["push"]["spec"]
        spec["params"] = [
            p for p in spec["params"] if p["name"] != "image-expires-after"
        ]
        self.validate()
        next(
            p
            for p in spec["pipelineSpec"]["params"]
            if p["name"] == "image-expires-after"
        )["default"] = "5d"
        with self.assertRaisesRegex(ValueError, "must not expire"):
            self.validate()
        del spec["pipelineSpec"]
        spec["pipelineRef"] = {"name": "missing-builder"}
        with self.assertRaisesRegex(ValueError, "Unverified pipelineRef"):
            self.validate()


class TenantContract(unittest.TestCase):
    def test_retest_of_a_pr_snapshot_is_not_releasable(self):
        app = "submariner-fbc-5-0"
        snapshot = {
            "metadata": {
                "name": app + "-fixture",
                "creationTimestamp": "2026-09-24T00:00:00Z",
                "labels": {
                    "pac.test.appstudio.openshift.io/event-type": "retest-all-comment",
                    "pac.test.appstudio.openshift.io/original-prname": app
                    + "-on-pull-request",
                },
            },
            "spec": {
                "application": app,
                "components": [
                    {
                        "name": app,
                        "source": {
                            "git": {
                                "revision": "a" * 40,
                                "url": "https://github.com/stolostron/submariner-operator-fbc",
                            }
                        },
                    }
                ],
            },
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "curl").write_text(
                '#!/bin/bash\nwhile [ "$#" -gt 0 ]; do\n'
                'case "$1" in -o) file=$2; shift 2 ;; *) shift ;; esac\ndone\n'
                'printf "image: quay.io/example@sha256:%064d\\n" 0 > "$file"\nprintf 200\n'
            )
            (root / "oc").write_text('#!/bin/bash\nprintf "%s\\n" "$SNAPSHOT_JSON"\n')
            for tool in ("oc", "curl"):
                (root / tool).chmod(0o755)
            result = subprocess.run(
                [str(ROOT / "scripts/verify-fbc-release.sh"), "0.24.1"],
                env=dict(
                    os.environ,
                    PATH=temporary + ":" + os.environ["PATH"],
                    FBC_OCP_VERSIONS="5-0",
                    SNAPSHOT_JSON=json.dumps({"items": [snapshot]}),
                ),
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not the push pipeline", result.stderr)

    def test_stale_catalog_cannot_bypass_build_map(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for mapping in ({}, {"5.0": "0.22"}):
                (root / "drop-versions.json").write_text(json.dumps(mapping))
                with self.assertRaisesRegex(ValueError, "build map"):
                    mod.validate_catalog(root, "5-0", "0.24")

    def test_admission_cannot_pin_an_old_index_or_wrong_environment(self):
        admissions = json.loads(
            (ROOT / "scripts/tests/fixtures/ocp5-admissions.json").read_text()
        )
        for env, admission in admissions.items():
            mod.validate_rpa(admission, "5-0", env)
            candidate = copy.deepcopy(admission)
            candidate["spec"]["data"]["fbc"]["fromIndex"] = "example/index:v4.22"
            with self.assertRaises(ValueError):
                mod.validate_rpa(candidate, "5-0", env)
        admissions["prod"]["spec"]["policy"] = "fbc-stage"
        with self.assertRaises(ValueError):
            mod.validate_rpa(admissions["prod"], "5-0", "prod")

    def test_semantic_tampering_is_rejected(self):
        objects = {
            (obj["kind"], obj["metadata"]["name"]): obj
            for obj in json.loads(
                (ROOT / "scripts/tests/fixtures/ocp5-tenant.json").read_text()
            )
        }
        mod.validate_tenant_objects(objects, "5-0")
        for kind, name, path, value in (
            (
                "ImageRepository",
                "imagerepository-submariner-fbc-5-0",
                ["spec", "image", "name"],
                "wrong",
            ),
            (
                "Component",
                "submariner-fbc-5-0",
                ["spec", "source", "git", "revision"],
                "wrong",
            ),
            (
                "ReleasePlan",
                "submariner-fbc-release-plan-prod-5-0",
                ["spec", "target"],
                "wrong",
            ),
            (
                "IntegrationTestScenario",
                "submariner-fbc-standard-5-0",
                ["metadata", "labels", "test.appstudio.openshift.io/optional"],
                "true",
            ),
        ):
            with self.subTest(kind=kind):
                candidate = copy.deepcopy(objects)
                target = candidate[kind, name]
                for part in path[:-1]:
                    target = target[part]
                target[path[-1]] = value
                with self.assertRaises(ValueError):
                    mod.validate_tenant_objects(candidate, "5-0")

    def test_retested_commit_must_be_an_ancestor_of_main(self):
        revision = "a" * 40
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "curl"
            executable.write_text('#!/bin/bash\nprintf "%s\\n" "$COMPARISON"\n')
            executable.chmod(0o755)
            command = f'source "{ROOT}/scripts/lib/fbc-snapshot.sh"; fbc_revision_on_main {revision}'
            for status, merge_base, expected in (
                ("identical", revision, 0),
                ("ahead", revision, 0),
                ("behind", "b" * 40, 1),
                ("diverged", "b" * 40, 1),
                ("ahead", "b" * 40, 1),
            ):
                result = subprocess.run(
                    ["bash", "-c", command],
                    env=dict(
                        os.environ,
                        PATH=temporary + ":" + os.environ["PATH"],
                        COMPARISON=json.dumps(
                            {
                                "status": status,
                                "base_commit": {"sha": revision},
                                "merge_base_commit": {"sha": merge_base},
                            }
                        ),
                    ),
                )
                self.assertEqual(result.returncode, expected, status)


class GitSafety(unittest.TestCase):
    setUp = onboarding_tests.Onboarding.setUp
    git = onboarding_tests.Onboarding.git
    init_repo = onboarding_tests.Onboarding.init_repo

    def test_commit_hook_isolates_worktrees_and_preserves_unrelated_staging(self):
        self.init_repo()
        (self.root / "input").write_text("user staged edit\n")
        (self.root / "selected").write_text("selected change\n")
        self.git("add", "input", "selected")
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        fake_make = fake_bin / "make"
        fake_make.write_text(
            "#!/bin/bash\nset -euo pipefail\n"
            'test "$*" = test\n'
            'git worktree add --detach "$PWD/test-worktree" HEAD\n'
            "trap 'git worktree remove --force \"$PWD/test-worktree\"' EXIT\n"
            'test -z "$(git -C test-worktree status --porcelain)"\n'
            'test "$(cat test-worktree/input)" = committed\n'
            "test ! -e test-worktree/selected\n"
        )
        fake_make.chmod(0o755)
        subprocess.run(
            [
                "git",
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@localhost",
                "-c",
                "commit.gpgsign=false",
                "-c",
                f"core.hooksPath={ROOT / '.githooks'}",
                "commit",
                "-qm",
                "Selected change",
                "--only",
                "--",
                "selected",
            ],
            cwd=self.root,
            env=dict(os.environ, PATH=str(fake_bin) + ":" + os.environ["PATH"]),
            check=True,
            capture_output=True,
        )
        self.assertEqual(
            self.git("show", "--format=", "--name-only", "HEAD"), "selected"
        )
        self.assertEqual(self.git("show", "HEAD:input"), "committed")
        self.assertEqual(self.git("show", ":input"), "user staged edit")
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "input")

    def test_resume_rejects_a_new_base_not_in_the_worktree(self):
        self.init_repo()
        target = self.root / "candidate"
        original = mod.base_commit(self.root, "HEAD")
        mod.worktree(self.root, target, original, "candidate")
        self.addCleanup(lambda: self.git("worktree", "remove", "--force", str(target)))
        (self.root / "input").write_text("new base\n")
        self.git("add", "input")
        self.git(
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@localhost",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "advance",
        )
        with self.assertRaisesRegex(ValueError, "rebase.*fresh --workspace"):
            mod.worktree(
                self.root, target, mod.base_commit(self.root, "HEAD"), "candidate"
            )
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=target), original)

    def test_selected_base_ignores_dirty_predecessor(self):
        self.init_repo()
        old = self.root / mod.OVERLAYS / "4-22-overlay/input"
        old.parent.mkdir(parents=True)
        old.write_text("base\n")
        self.git("add", ".")
        self.git(
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@localhost",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "overlay",
        )
        (old.parent.parent / "4-99-overlay").mkdir()
        self.assertEqual(mod.predecessor_at_ref(self.root, "5-0", "HEAD"), "4-22")

    def test_release_commit_leaves_unrelated_index_entry_staged(self):
        self.init_repo()
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@localhost")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", "/dev/null")
        (self.root / "input").write_text("user staged edit\n")
        self.git("add", "input")
        (self.root / "release.yaml").write_text("test fixture\n")
        script = (ROOT / "scripts/create-fbc-releases.sh").read_text()
        function = script[
            script.index("commit_changes() {") : script.index(
                "\n# ===", script.index("commit_changes() {")
            )
        ]
        subprocess.run(
            [
                "bash",
                "-euc",
                function
                + "\nget_gh_user() { echo fixture; }; fork_remote() { echo fixture; }; GIT_ROOT=$PWD; VERSION=0.24.1; RELEASE_TYPE=prod; CREATED_FILES=(release.yaml); declare -A SNAPSHOTS=([5-0]=snapshot); commit_changes",
            ],
            cwd=self.root,
            check=True,
            capture_output=True,
        )
        self.assertEqual(
            self.git("show", "--format=", "--name-only", "HEAD"), "release.yaml"
        )
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "input")
