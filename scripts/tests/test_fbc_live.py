"""Live readiness must establish source/content identity and preserve partial evidence."""

import isolate_git  # noqa: F401  (must precede any git use)
import copy
from contextlib import redirect_stdout
from io import StringIO
import json
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from test_fbc_onboarding import ROOT, mod
from test_fbc_review import BASE, pipeline


class LiveEvidence(unittest.TestCase):
    def setUp(self):
        self.app, self.commit = "submariner-fbc-5-0", "a" * 40
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        lifecycle = Path(self.temporary.name) / "lifecycle.json"
        lifecycle.write_text(
            json.dumps(
                {
                    "schema": "io.openshift.operators.lifecycles.v1alpha1",
                    "package": "submariner",
                    "versions": [{"name": "0.24", "phases": [{"name": "full"}]}],
                }
            )
        )
        self.args = SimpleNamespace(
            ocp="5-0", expected_commit=self.commit, expected_lifecycle=lifecycle
        )
        self.repo = f"quay.io/redhat-user-workloads/submariner-tenant/{self.app}"
        self.tests = [
            {
                "scenario": f"submariner-fbc-{kind}-5-0",
                "status": "TestPassed",
                "completionTime": "2026-09-24T00:10:00Z",
            }
            for kind in ("standard", "operator")
        ]
        self.snapshot = {
            "metadata": {
                "name": self.app + "-snapshot",
                "creationTimestamp": "2026-09-24T00:00:00Z",
                "labels": {
                    "pac.test.appstudio.openshift.io/event-type": "push",
                    "pac.test.appstudio.openshift.io/original-prname": self.app
                    + "-on-push",
                    "appstudio.openshift.io/build-pipelinerun": "build",
                },
                "annotations": {
                    "test.appstudio.openshift.io/status": json.dumps(self.tests)
                },
            },
            "spec": {
                "application": self.app,
                "components": [
                    {
                        "name": self.app,
                        "containerImage": self.repo + "@sha256:" + "b" * 64,
                        "source": {
                            "git": {
                                "revision": self.commit,
                                "url": "https://github.com/stolostron/submariner-operator-fbc",
                            }
                        },
                    }
                ],
            },
            "status": {
                "conditions": [
                    {
                        "type": "AppStudioIntegrationStatus",
                        "status": "True",
                        "reason": "Finished",
                    },
                    {
                        "type": "AppStudioTestSucceeded",
                        "status": "True",
                        "reason": "Passed",
                    },
                ]
            },
        }
        self.resources = {
            (obj["kind"].lower(), obj["metadata"]["name"]): obj
            for obj in json.loads(
                (ROOT / "scripts/tests/fixtures/ocp5-tenant.json").read_text()
            )
        }
        admissions = json.loads(
            (ROOT / "scripts/tests/fixtures/ocp5-admissions.json").read_text()
        )
        for env, admission in admissions.items():
            plan = f"submariner-fbc-release-plan-{env}-5-0"
            self.resources["releaseplan", plan]["status"] = {
                "releasePlanAdmission": {
                    "active": True,
                    "name": f"rhtap-releng-tenant/submariner-fbc-{env}",
                },
                "conditions": [{"type": "Matched", "status": "True"}],
            }
            admission["status"] = {
                "releasePlans": [{"name": f"submariner-tenant/{plan}"}]
            }
            self.resources["releaseplanadmission", f"submariner-fbc-{env}"] = admission
        self.account = {
            "metadata": {"ownerReferences": [{"kind": "Component", "name": self.app}]},
            "secrets": [{"name": f"imagerepository-{self.app}-image-push"}],
        }
        self.secret_keys = "kubernetes.io/dockerconfigjson\n.dockerconfigjson\n"
        self.build = pipeline("push")
        self.build["metadata"].setdefault("annotations", {}).update(
            {
                "pipelinesascode.tekton.dev/event-type": "push",
                "build.appstudio.redhat.com/target_branch": "main",
            }
        )
        params = mod.named_values(self.build["spec"]["params"], "params")
        params.update(
            revision=self.commit,
            **{
                "output-image": self.repo + ":" + self.commit,
                "git-url": "https://github.com/stolostron/submariner-operator-fbc",
            },
        )
        self.build["spec"]["params"] = [
            {"name": name, "value": value} for name, value in params.items()
        ]
        self.build["status"] = {
            "conditions": [{"type": "Succeeded", "status": "True"}],
            "results": [
                {"name": "IMAGE_DIGEST", "value": "sha256:" + "b" * 64},
                {"name": "IMAGE_URL", "value": self.repo + ":" + self.commit},
            ],
        }
        self.arches = ["amd64", "arm64", "ppc64le", "s390x"]
        self.child_base = BASE
        self.child_labels = {}
        for name in (
            "require_merged_commit",
            "catalog_git_files",
            "merged_catalog_contract",
            "verify_catalog_images",
        ):
            mock = patch.object(mod, name).start()
            self.addCleanup(patch.stopall)
            setattr(self, name, mock)
        self.verify_catalog_images.return_value = self.arches
        patch.object(mod, "run", side_effect=self.fake_run).start()

    def fake_run(self, *args, **kwargs):
        if args[:3] == ("oc", "get", "secret"):
            self.assertTrue(args[-1].startswith("go-template="))
            self.assertNotIn("\n", args[-1])
            self.assertNotIn("{{$value}}", args[-1])
            return self.secret_keys
        if args[0] == "skopeo":
            if "--config" in args:
                return json.dumps({"config": {"Labels": self.child_labels}})
            if args[-1].endswith("@sha256:" + "b" * 64):
                return json.dumps(
                    {
                        "manifests": [
                            {
                                "digest": "sha256:" + str(i) * 64,
                                "platform": {"architecture": arch, "os": "linux"},
                            }
                            for i, arch in enumerate(self.arches)
                        ]
                    }
                )
            return json.dumps(
                {"annotations": {"org.opencontainers.image.base.name": self.child_base}}
            )
        kind, name = args[2:4]
        if kind == "snapshots":
            return json.dumps({"items": [self.snapshot]})
        if kind == "pipelinerun":
            return json.dumps(self.build)
        if kind == "serviceaccount":
            return json.dumps(self.account)
        return json.dumps(self.resources[kind, name])

    def verify(self):
        output = StringIO()
        with redirect_stdout(output):
            passed = mod.verify_live(self.args, BASE)
        result = json.loads(output.getvalue())
        self.assertEqual(passed, not result["errors"])
        self.assertIn("unverified", result["runtime_on_requested_ocp"])
        return result

    def test_lifecycle_reference_is_required_and_reported(self):
        result = self.verify()
        self.assertTrue(result["build_ready"])
        self.assertEqual(len(result["lifecycle_reference_sha256"]), 64)
        self.assertEqual(
            self.verify_catalog_images.call_args.args[-1],
            self.args.expected_lifecycle.read_bytes(),
        )
        self.args.expected_lifecycle = None
        result = self.verify()
        self.assertFalse(result["build_ready"])
        self.assertIn("--expected-lifecycle", result["errors"][0])

    def test_complete_content_and_provenance_are_required(self):
        result = self.verify()
        self.assertTrue(result["configuration_ready"] and result["build_ready"])
        self.require_merged_commit.assert_called_once_with(self.commit)
        self.verify_catalog_images.assert_called_once()
        self.verify_catalog_images.side_effect = ValueError("wrong catalog content")
        result = self.verify()
        self.assertTrue(result["configuration_ready"])
        self.assertFalse(result["build_ready"])
        self.assertIn("wrong catalog content", result["errors"][0])

    def test_completed_retained_marker_is_accepted(self):
        # The tenant's standard scenario keeps BuildPLRInProgress after passing.
        self.snapshot["metadata"]["annotations"]["test.appstudio.openshift.io/status"] = (
            json.dumps([dict(self.tests[0], status="BuildPLRInProgress"), self.tests[1]])
        )
        self.assertTrue(self.verify()["build_ready"])

    def test_unmerged_commit_is_never_ready(self):
        self.require_merged_commit.side_effect = ValueError("not on main")
        self.assertFalse(self.verify()["build_ready"])
        self.catalog_git_files.assert_not_called()

    def test_binding_and_admission_errors_preserve_build_evidence(self):
        mutations = [
            lambda: self.account.update(secrets=[]),
            lambda: self.account["metadata"].update(ownerReferences=[]),
            lambda: setattr(self, "secret_keys", "Opaque\nwrong-key\n"),
            lambda: self.resources["releaseplanadmission", "submariner-fbc-stage"][
                "spec"
            ]["data"]["fbc"].update(publishingCredentials="wrong"),
        ]
        for mutate in mutations:
            original = copy.deepcopy((self.account, self.resources, self.secret_keys))
            mutate()
            result = self.verify()
            self.assertFalse(result["configuration_ready"])
            self.assertTrue(result["build_ready"])
            self.account, self.resources, self.secret_keys = original

    def test_build_snapshot_and_manifest_mismatches_fail(self):
        def param(name, value):
            next(item for item in self.build["spec"]["params"] if item["name"] == name)[
                "value"
            ] = value

        mutations = [
            lambda: self.snapshot["metadata"]["labels"].update(
                {
                    "pac.test.appstudio.openshift.io/original-prname": self.app
                    + "-on-pull-request"
                }
            ),
            lambda: self.snapshot["metadata"]["annotations"].update(
                {
                    "test.appstudio.openshift.io/status": json.dumps(
                        [
                            {
                                key: value
                                for key, value in self.tests[0].items()
                                if key != "completionTime"
                            }
                            | {"status": "BuildPLRInProgress"},
                            self.tests[1],
                        ]
                    )
                }
            ),
            lambda: self.snapshot["metadata"]["annotations"].update(
                {
                    "test.appstudio.openshift.io/status": json.dumps(
                        [dict(self.tests[0], status="TestFail"), self.tests[1]]
                    )
                }
            ),
            lambda: self.snapshot["status"]["conditions"][1].update(reason="Failed"),
            lambda: self.snapshot.pop("status"),
            lambda: self.build["metadata"]["annotations"].update(
                {"build.appstudio.redhat.com/target_branch": "other"}
            ),
            lambda: self.build["spec"]["taskRunTemplate"].update(
                serviceAccountName="wrong"
            ),
            lambda: self.build["status"]["results"][0].update(
                value="sha256:" + "c" * 64
            ),
            lambda: self.build["status"]["results"][1].update(
                value="quay.io/wrong:tag"
            ),
            lambda: param("revision", "c" * 40),
            lambda: param(
                "build-args", ["INPUT_DIR=catalog-4-22", "OPM_IMAGE=" + BASE]
            ),
            lambda: self.arches.pop(),
            lambda: self.arches.append("s390x"),
            lambda: setattr(self, "child_base", BASE.replace("v5.0", "v4.22")),
            lambda: setattr(
                self, "child_labels", {"com.redhat.fbc.openshift.version": '["v4.22"]'}
            ),
            lambda: self.build["spec"]["pipelineSpec"].update(tasks=[]),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                original = copy.deepcopy(
                    (
                        self.snapshot,
                        self.build,
                        self.arches,
                        self.child_base,
                        self.child_labels,
                    )
                )
                mutate()
                self.assertFalse(self.verify()["build_ready"])
                (
                    self.snapshot,
                    self.build,
                    self.arches,
                    self.child_base,
                    self.child_labels,
                ) = original


class ImageContents(unittest.TestCase):
    def test_reviewed_lifecycle_is_exact_on_every_platform_and_other_files_stay_exact(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            reference = source / "lifecycle.json"
            reference.write_text(
                json.dumps(
                    {
                        "schema": "io.openshift.operators.lifecycles.v1alpha1",
                        "package": "submariner",
                        "versions": [{"name": "0.24", "phases": [{"name": "full"}]}],
                    }
                )
            )
            lifecycle = mod.read_expected_lifecycle(reference)
            expected = {"package.yaml": mod.git_blob(b"package data\n")}
            manifests = [
                {"digest": "sha256:" + str(i) * 64, "platform": {"architecture": arch}}
                for i, arch in enumerate(("amd64", "arm64", "ppc64le", "s390x"))
            ]
            mode = "valid"

            def extract(*args, **kwargs):
                directory = Path(args[args.index("--path") + 1].split(":", 1)[1])
                (directory / "package.yaml").write_bytes(b"package data\n")
                (directory / "lifecycle.json").write_bytes(lifecycle)
                if directory.name == "s390x":
                    if mode == "missing":
                        (directory / "lifecycle.json").unlink()
                    elif mode == "changed_lifecycle":
                        (directory / "lifecycle.json").write_bytes(lifecycle + b"\n")
                    elif mode == "changed_source":
                        (directory / "package.yaml").write_text("wrong package\n")
                    elif mode == "extra":
                        (directory / "extra.json").write_text("{}")
                    elif mode == "symlink":
                        (directory / "lifecycle.json").unlink()
                        (directory / "lifecycle.json").symlink_to(reference)

            with (
                patch.object(mod, "run", side_effect=extract),
                patch.object(mod, "validate_catalog_contents"),
            ):
                self.assertEqual(
                    mod.verify_catalog_images(
                        "example/image", manifests, expected, (), lifecycle
                    ),
                    ["amd64", "arm64", "ppc64le", "s390x"],
                )
                self.assertNotIn("lifecycle.json", expected)
                for mode in (
                    "missing",
                    "changed_lifecycle",
                    "changed_source",
                    "extra",
                    "symlink",
                ):
                    with self.subTest(mode=mode), self.assertRaises(ValueError):
                        mod.verify_catalog_images(
                            "example/image", manifests, expected, (), lifecycle
                        )
                mode = "valid"
                with self.assertRaisesRegex(ValueError, "catalog differs"):
                    mod.verify_catalog_images("example/image", manifests, expected, ())

    def test_lifecycle_bytes_are_compared_directly_not_only_by_git_hash(self):
        """A weak or colliding hash must not let changed lifecycle bytes through."""
        lifecycle = b'{"schema": "reference"}'
        manifests = [
            {"digest": "sha256:" + "a" * 64, "platform": {"architecture": "amd64"}}
        ]
        changed = {"value": lifecycle}

        def extract(*args, **kwargs):
            directory = Path(args[args.index("--path") + 1].split(":", 1)[1])
            (directory / "lifecycle.json").write_bytes(changed["value"])

        with (
            patch.object(mod, "run", side_effect=extract),
            patch.object(mod, "validate_catalog_contents"),
            patch.object(mod, "git_blob", return_value="c" * 40),
        ):
            self.assertEqual(
                mod.verify_catalog_images("example/image", manifests, {}, (), lifecycle),
                ["amd64"],
            )
            changed["value"] = lifecycle + b" "
            with self.assertRaisesRegex(ValueError, "differs from the reviewed"):
                mod.verify_catalog_images("example/image", manifests, {}, (), lifecycle)

    def test_lifecycle_reference_rejects_wrong_packages_and_malformed_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "lifecycle.json"
            for content in (
                "[]",
                "{}",
                "not json",
                '{"schema":"io.openshift.operators.lifecycles.v1alpha1","package":"other","versions":[{}]}',
                '{"schema":"io.openshift.operators.lifecycles.v1alpha1","package":"other","package":"submariner","versions":[{}]}',
                '{"schema":"io.openshift.operators.lifecycles.v1alpha1","package":"submariner","versions":[NaN]}',
            ):
                with self.subTest(content=content):
                    path.write_text(content)
                    with self.assertRaises(ValueError):
                        mod.read_expected_lifecycle(path)

    def test_each_platform_is_extracted_and_wrong_content_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / "package.yaml").write_text("package data\n")
            expected = {
                "package.yaml": mod.git_blob((source / "package.yaml").read_bytes())
            }
            manifests = [
                {"digest": "sha256:" + str(i) * 64, "platform": {"architecture": arch}}
                for i, arch in enumerate(("amd64", "arm64", "ppc64le", "s390x"))
            ]
            wrong = False

            def extract(*args, **kwargs):
                destination = Path(args[args.index("--path") + 1].split(":", 1)[1])
                shutil.copy2(source / "package.yaml", destination)
                if wrong and destination.name == "s390x":
                    (destination / "package.yaml").write_text("different catalog\n")

            with (
                patch.object(mod, "run", side_effect=extract) as command,
                patch.object(mod, "validate_catalog_contents") as validate,
            ):
                self.assertEqual(
                    mod.verify_catalog_images(
                        "example/image@sha256:" + "a" * 64,
                        manifests,
                        expected,
                        (1, 2, 3),
                    ),
                    ["amd64", "arm64", "ppc64le", "s390x"],
                )
                self.assertEqual(command.call_count, 4)
                self.assertEqual(validate.call_count, 4)
                wrong = True
                with self.assertRaisesRegex(ValueError, "s390x catalog differs"):
                    mod.verify_catalog_images(
                        "example/image@sha256:" + "a" * 64,
                        manifests,
                        expected,
                        (1, 2, 3),
                    )


if __name__ == "__main__":
    unittest.main()
