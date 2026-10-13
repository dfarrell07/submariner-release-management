"""Failures reproduced in the onboarding audit; fixtures use the reviewed inputs."""

import isolate_git  # noqa: F401  (must precede any git use)
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import yaml

from test_fbc_onboarding import ROOT, mod
from test_fbc_review import BASE, pipeline


class PipelineExecution(unittest.TestCase):
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

    def test_disabled_checks_context_and_index_are_rejected(self):
        for name, value in (
            ("skip-checks", "true"),
            ("path-context", "elsewhere"),
            ("build-image-index", "false"),
            ("build-args-file", "override.env"),
        ):
            with self.subTest(name=name):
                self.pair["push"] = pipeline("push")
                self.pair["push"]["spec"]["params"].append(
                    {"name": name, "value": value}
                )
                with self.assertRaisesRegex(ValueError, "Wrong effective"):
                    self.validate()

    def test_empty_missing_or_unresolved_tasks_never_pass(self):
        for mode in ("empty", "missing", "reference", "continue"):
            with self.subTest(mode=mode):
                self.pair["push"] = pipeline("push")
                spec = self.pair["push"]["spec"]
                if mode == "empty":
                    spec["pipelineSpec"]["tasks"] = []
                elif mode == "missing":
                    spec["pipelineSpec"]["tasks"].pop()
                elif mode == "reference":
                    del spec["pipelineSpec"]
                    spec["pipelineRef"] = {"name": "not-present"}
                else:
                    spec["pipelineSpec"]["tasks"][-1]["onError"] = "continue"
                with self.assertRaises(ValueError):
                    self.validate()

    def test_effective_argument_platform_and_result_forwarding(self):
        for mode in ("args", "matrix", "result", "guard", "task-image"):
            with self.subTest(mode=mode):
                self.pair["push"] = pipeline("push")
                spec = self.pair["push"]["spec"]["pipelineSpec"]
                tasks = {task["name"]: task for task in spec["tasks"]}
                if mode == "args":
                    next(
                        p
                        for p in tasks["build-images"]["params"]
                        if p["name"] == "BUILD_ARGS"
                    )["value"] = ["INPUT_DIR=catalog-4-22"]
                elif mode == "matrix":
                    tasks["build-images"]["matrix"]["params"][0]["value"] = [
                        "linux/x86_64"
                    ]
                elif mode == "result":
                    spec["results"][0]["value"] = (
                        "$(tasks.build-images.results.IMAGE_URL)"
                    )
                elif mode == "guard":
                    tasks["validate-fbc"]["when"][0]["values"] = ["true"]
                else:
                    next(
                        p
                        for p in tasks["validate-fbc"]["taskRef"]["params"]
                        if p["name"] == "bundle"
                    )["value"] = "quay.io/unrelated/task@sha256:" + "a" * 64
                with self.assertRaises(ValueError):
                    self.validate()

    def test_required_lifecycle_task_and_forwarding(self):
        self.validate()
        for mode in ("missing", "opm-bypass", "wrong-source", "skipped"):
            with self.subTest(mode=mode):
                self.pair["push"] = pipeline("push")
                tasks = self.pair["push"]["spec"]["pipelineSpec"]["tasks"]
                lifecycle = next(t for t in tasks if t["name"] == "fbc-inject-lifecycle")
                if mode == "missing":
                    tasks.remove(lifecycle)
                elif mode == "skipped":
                    lifecycle["when"] = [{"input": "true", "operator": "in", "values": ["false"]}]
                else:
                    target = lifecycle if mode == "wrong-source" else next(t for t in tasks if t["name"] == "run-opm-command")
                    next(p for p in target["params"] if p["name"] == "SOURCE_ARTIFACT")["value"] = "$(tasks.init.results.SOURCE_ARTIFACT)"
                with self.assertRaises(ValueError):
                    self.validate()

    def test_base_override_is_reusable_and_failed_pair_leaves_no_files(self):
        self.validate()
        override = (
            "registry.redhat.io/openshift5/ose-operator-registry-rhel9@sha256:"
            + "a" * 64
        )
        for event in self.pair:
            path = self.root / ".tekton" / f"submariner-fbc-5-0-{event}.yaml"
            path.write_text(path.read_text().replace(BASE, override))
        mod.pipelines(self.root, "5-1", "5-0", BASE.replace("v5.0", "v5.1"))
        before = {
            path.name: path.read_bytes()
            for path in (self.root / ".tekton").glob("*.yaml")
        }
        mod.pipelines(self.root, "5-1", "5-0", BASE.replace("v5.0", "v5.1"))
        self.assertEqual(
            before,
            {
                path.name: path.read_bytes()
                for path in (self.root / ".tekton").glob("*.yaml")
            },
        )
        (self.root / ".tekton/submariner-fbc-5-1-pull-request.yaml").unlink()
        with self.assertRaises(ValueError):
            mod.pipelines(self.root, "5-2", "5-1", BASE.replace("v5.0", "v5.2"))
        self.assertFalse(list((self.root / ".tekton").glob("*5-2*")))


class ConfigurationContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.admissions = json.loads(
            (ROOT / "scripts/tests/fixtures/ocp5-admissions.json").read_text()
        )
        self.objects = json.loads(
            (ROOT / "scripts/tests/fixtures/ocp5-tenant.json").read_text()
        )

    def test_sequence_layouts_preserve_comments_and_values(self):
        for text in (
            "# keep\nresources:\n- old # comment\n",
            "# keep\nresources:\n  - old # comment\n",
            "# keep\nresources: [old] # comment\n",
            "# keep\nresources: [] # comment\n",
        ):
            with self.subTest(text=text):
                result = mod.sequence_item(text, ["resources"], "new")
                self.assertEqual(yaml.safe_load(result)["resources"][0], "new")
                self.assertIn("# keep", result)
                self.assertIn("# comment", result)
                self.assertEqual(
                    mod.sequence_item(result, ["resources"], "new"), result
                )

    def test_alias_cannot_modify_an_unrelated_sequence(self):
        text = "unrelated: &shared [old]\nresources: *shared\n"
        with self.assertRaises(ValueError):
            mod.sequence_item(text, ["resources"], "new")

    def test_ocp5_rejects_the_legacy_install_path_and_wrong_secret_key(self):
        for legacy in (True, False):
            docs = copy.deepcopy(self.objects)
            its = next(
                doc
                for doc in docs
                if doc["metadata"]["name"] == "submariner-fbc-operator-5-0"
            )
            if legacy:
                next(
                    item
                    for item in its["spec"]["resolverRef"]["params"]
                    if item["name"] == "pathInRepo"
                )[
                    "value"
                ] = "pipelines/deploy-fbc-operator/0.1/deploy-fbc-operator.yaml"
            else:
                next(
                    item
                    for item in its["spec"]["params"]
                    if item["name"] == "CREDENTIALS_SECRET_KEY"
                )["value"] = "oci-storage-dockerconfigjson"
            with self.assertRaisesRegex(ValueError, "OCP 5"):
                mod.validate_tenant_objects(
                    {(doc["kind"], doc["metadata"]["name"]): doc for doc in docs}, "5-0"
                )

    def test_base_override_must_work_with_the_deployed_release_version_filter(self):
        mod.validate_base_reference("registry.example/approved/base:v5.0", "5-0")
        for image in (
            BASE.replace("v5.0", "v4.22"),
            BASE + "@sha256:" + "a" * 64,
            "registry.example:5000/base:v5.0",
        ):
            with self.assertRaisesRegex(ValueError, "release version filter"):
                mod.validate_base_reference(image, "5-0")
        mod.validate_image_target({"config": {"Labels": {}}})
        for target in ('["v4.22"]', '["v5.0"]'):
            with self.assertRaisesRegex(ValueError, "target label"):
                mod.validate_image_target(
                    {"config": {"Labels": {"com.redhat.fbc.openshift.version": target}}}
                )

    def test_both_admissions_are_checked_before_either_write(self):
        (self.root / mod.RPA).mkdir(parents=True)
        for env, data in self.admissions.items():
            data["spec"]["applications"].remove("submariner-fbc-5-0")
            mod.save(self.root / mod.RPA / f"submariner-fbc-{env}.yaml", data)
        prod = self.root / mod.RPA / "submariner-fbc-prod.yaml"
        data = mod.load(prod)
        data["spec"]["pipeline"]["serviceAccountName"] = "unrelated"
        mod.save(prod, data)
        before = {
            path: path.read_bytes() for path in (self.root / mod.RPA).glob("*.yaml")
        }
        with self.assertRaisesRegex(ValueError, "service account"):
            mod.prepare_rpas(self.root, "5-0")
        self.assertEqual(before, {path: path.read_bytes() for path in before})
        data["spec"]["pipeline"]["serviceAccountName"] = "release-index-image-prod"
        mod.save(prod, data)
        mod.prepare_rpas(self.root, "5-0")
        for env in self.admissions:
            mod.validate_rpa(
                mod.load(self.root / mod.RPA / f"submariner-fbc-{env}.yaml"), "5-0", env
            )

    def test_wrong_index_credentials_and_resolver_are_rejected(self):
        mutations = [
            lambda d: d["spec"]["data"]["fbc"].update(
                fromIndex="quay.io/other/index:{{ OCP_VERSION }}"
            ),
            lambda d: d["spec"]["data"]["fbc"].update(publishingCredentials="other"),
            lambda d: d["spec"]["pipeline"]["pipelineRef"].update(resolver="other"),
        ]
        for mutation in mutations:
            data = copy.deepcopy(self.admissions["stage"])
            mutation(data)
            with self.assertRaises(ValueError):
                mod.validate_rpa(data, "5-0", "stage")

    def test_wrong_its_package_resolver_and_extra_context_are_rejected(self):
        for mode in ("package", "resolver", "context"):
            docs = copy.deepcopy(self.objects)
            its = next(
                doc
                for doc in docs
                if doc["metadata"]["name"] == "submariner-fbc-operator-5-0"
            )
            if mode == "package":
                its["spec"]["params"][0]["value"] = "other"
            elif mode == "resolver":
                its["spec"]["resolverRef"]["params"][0]["value"] = (
                    "https://example.invalid/pipeline"
                )
            else:
                its["spec"]["contexts"].append({"name": "unrelated"})
            with self.assertRaises(ValueError):
                mod.validate_tenant_objects(
                    {(doc["kind"], doc["metadata"]["name"]): doc for doc in docs}, "5-0"
                )

    def test_missing_registration_and_stale_generated_tenant_are_rejected(self):
        (self.root / mod.GENERATED).mkdir(parents=True)
        for index, doc in enumerate(self.objects):
            mod.save(self.root / mod.GENERATED / f"{index}.yaml", doc)
        registration = self.root / mod.TENANT / "kustomization.yaml"
        registration.parent.mkdir(parents=True)
        mod.save(registration, {"resources": []})
        with self.assertRaisesRegex(ValueError, "registration"):
            mod.validate_tenant(self.root, "5-0")
        mod.add_resource(registration, "overlay/application-submariner-fbc/5-0-overlay")
        fresh = copy.deepcopy(self.objects)
        next(doc for doc in fresh if doc["kind"] == "Component")["spec"][
            "application"
        ] = "wrong"
        with (
            patch.object(mod, "kustomize_binary", return_value="kustomize"),
            patch.object(mod, "run", return_value=yaml.safe_dump_all(fresh)),
        ):
            with self.assertRaisesRegex(ValueError, "Wrong application"):
                mod.validate_tenant(self.root, "5-0")


class CatalogContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.name = "submariner.v0.24.1"
        self.image = (
            "registry.redhat.io/rhacm2/submariner-operator-bundle@sha256:" + "a" * 64
        )
        self.package = {
            "schema": "olm.package",
            "name": "submariner",
            "defaultChannel": "stable-0.24",
        }
        self.channel = {
            "schema": "olm.channel",
            "name": "stable-0.24",
            "package": "submariner",
            "entries": [{"name": self.name}],
        }
        template = {
            "entries": [
                self.package,
                self.channel,
                {"schema": "olm.bundle", "name": self.name, "image": self.image},
            ]
        }
        mod.save(self.root / "catalog-template.yaml", template)
        (self.root / "drop-versions.json").write_text('{"5.0": "0.23"}')
        self.catalog = self.root / "catalog-5-0"
        (self.catalog / "channels").mkdir(parents=True)
        (self.catalog / "bundles").mkdir()
        mod.save(self.catalog / "package.yaml", self.package)
        mod.save(self.catalog / "channels/channel.yaml", self.channel)
        mod.save(
            self.catalog / "bundles/bundle.yaml",
            {
                "schema": "olm.bundle",
                "name": self.name,
                "package": "submariner",
                "image": self.image,
                "properties": [
                    {
                        "type": "olm.package",
                        "value": {"packageName": "submariner", "version": "0.24.1"},
                    }
                ],
            },
        )

    def test_cutoff_is_enforced_without_optional_cli_minimum(self):
        with patch.object(mod, "run"):
            self.assertEqual(mod.validate_catalog(self.root, "5-0", None), 1)
            (self.root / "drop-versions.json").write_text('{"5.0": "0.99"}')
            with self.assertRaises(ValueError):
                mod.validate_catalog(self.root, "5-0", None)

    def test_structurally_valid_wrong_digest_graph_and_version_rejected(self):
        for relative, mutate in (
            (
                "bundles/bundle.yaml",
                lambda data: data.update(image=self.image[:-1] + "b"),
            ),
            (
                "channels/channel.yaml",
                lambda data: data["entries"][0].update(skipRange=">=0.0.0 <0.24.1"),
            ),
            (
                "bundles/bundle.yaml",
                lambda data: data["properties"][0]["value"].update(version="0.24.0"),
            ),
        ):
            path = self.catalog / relative
            before = path.read_text()
            data = mod.load(path)
            mutate(data)
            mod.save(path, data)
            with patch.object(mod, "run") as opm:
                with self.assertRaises(ValueError):
                    mod.validate_catalog(self.root, "5-0", None)
                opm.assert_not_called()
            path.write_text(before)
