"""Offline regressions for the OCP-major transition and safe onboarding."""

import isolate_git  # noqa: F401  (must precede any git use)
import argparse
import importlib.util
import io
from contextlib import redirect_stdout
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "onboard", ROOT / "scripts/fbc-onboard.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class Onboarding(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def git(self, *args, cwd=None):
        return mod.run("git", *args, cwd=cwd or self.root).strip()

    def init_repo(self):
        self.git("init", "-q")
        (self.root / "input").write_text("committed\n")
        self.git("add", ".")
        self.git(
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.org",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "core.hooksPath=/dev/null",
            "commit",
            "-qm",
            "base",
        )

    def test_full_versions_and_bad_inputs(self):
        for value in ("5.0", "5-0"):
            self.assertEqual(mod.ocp(value), "5-0")
        for value in ("5", "5.00", "5.0.1", "5x0", "0.5", "../5-0"):
            with self.assertRaises(argparse.ArgumentTypeError):
                mod.ocp(value)

    def test_extra_argument_is_rejected_before_repository_access(self):
        result = subprocess.run(
            [str(ROOT / "scripts/add-fbc-ocp-version.sh"), "5.0", "0.23", "ignored"],
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("unrecognized arguments", result.stderr)
        self.assertFalse(list(self.root.iterdir()))

    def test_legacy_cutoff_keeps_old_semantics(self):
        with patch.object(mod, "repo", side_effect=ValueError("stop after arguments")):
            with patch("sys.stderr") as stderr:
                with redirect_stdout(io.StringIO()) as output:
                    mod.main(["5.0", "0.23"])
                plan = json.loads(output.getvalue())
                self.assertEqual(plan["minimum_inclusive"], "0.24")
                self.assertEqual(plan["cutoff_exclusive"], "0.23")
                self.assertEqual(plan["blockers"]["catalog"], ["stop after arguments"])
                self.assertIn(
                    "inclusive minimum is 0.24",
                    "".join(call.args[0] for call in stderr.write.call_args_list),
                )
        with self.assertRaisesRegex(ValueError, "Do not combine"):
            mod.main(["5.0", "0.23", "--min-supported-sub", "0.25"])

    def test_worktree_preserves_dirty_checkout_and_existing_branch(self):
        self.init_repo()
        before = self.git("rev-parse", "HEAD")
        branch = self.git("branch", "--show-current")
        (self.root / "input").write_text("unsaved\n")
        (self.root / "untracked").write_text("retain\n")
        target = self.root.parent / (self.root.name + "-worktree")
        self.addCleanup(
            lambda: (
                self.git("worktree", "remove", "--force", str(target))
                if target.exists()
                else None
            )
        )
        mod.worktree(self.root, target, "HEAD", "ocp-5-test")
        self.assertEqual((self.root / "input").read_text(), "unsaved\n")
        self.assertEqual((self.root / "untracked").read_text(), "retain\n")
        self.assertEqual(self.git("branch", "--show-current"), branch)
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        (target / "candidate").write_text("keep on resume\n")
        mod.worktree(self.root, target, "HEAD", "ocp-5-test")
        self.assertEqual((target / "candidate").read_text(), "keep on resume\n")
        with self.assertRaisesRegex(ValueError, "already exists"):
            mod.worktree(self.root, self.root / "other", "HEAD", "ocp-5-test")
        self.assertEqual(self.git("rev-parse", "ocp-5-test"), before)

    def test_resource_registration_is_idempotent_and_preserves_comments(self):
        path = self.root / "kustomization.yaml"
        path.write_text("# keep\nresources:\n  - old # comment\npatches: []\n")
        mod.add_resource(path, "new")
        once = path.read_text()
        mod.add_resource(path, "new")
        self.assertEqual(path.read_text(), once)
        self.assertEqual(mod.load(path)["resources"], ["new", "old"])
        self.assertIn("# comment", once)

    def test_predecessor_orders_major_and_minor(self):
        self.init_repo()
        for version in ("4-9", "4-22", "5-0", "5-1"):
            path = self.root / mod.OVERLAYS / f"{version}-overlay/input"
            path.parent.mkdir(parents=True)
            path.write_text("overlay\n")
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
            "overlays",
        )
        self.assertEqual(mod.predecessor_at_ref(self.root, "5-0", "HEAD"), "4-22")
        self.assertEqual(mod.predecessor_at_ref(self.root, "5-1", "HEAD"), "5-0")

    def test_seven_malformed_objects_do_not_count_as_configuration(self):
        directory = self.root / mod.GENERATED
        directory.mkdir(parents=True)
        for i in range(7):
            (directory / f"{i}.yaml").write_text("hello: world\n")
        with self.assertRaises((ValueError, KeyError)):
            mod.validate_tenant(self.root, "5-0")

    def test_new_release_yaml_full_identity_and_snapshot_guard(self):
        script = ROOT / "scripts/generate-fbc-release.sh"
        result = subprocess.run(
            [
                str(script),
                "5.0",
                "0.24.1",
                "submariner-fbc-5-0-abc",
                "stage",
                "20260924",
            ],
            cwd=self.root,
            capture_output=True,
            text=True,
            check=True,
        )
        data = yaml.safe_load((self.root / result.stdout.strip()).read_text())
        self.assertEqual(
            data["spec"]["releasePlan"], "submariner-fbc-release-plan-stage-5-0"
        )
        self.assertEqual(
            data["metadata"]["name"], "submariner-fbc-5-0-0-24-1-stage-20260924-01"
        )
        result = subprocess.run(
            [
                str(script),
                "5.0",
                "0.24.1",
                "submariner-fbc-4-22-abc",
                "prod",
                "20260924",
            ],
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "releases/fbc/5-0/prod").exists())

    def test_snapshot_results_fail_closed(self):
        command = f'source "{ROOT}/scripts/lib/fbc-snapshot.sh"; fbc_tests_passed 5-0'
        passing = [
            {
                "scenario": f"submariner-fbc-{kind}-5-0",
                "status": "TestPassed",
                "completionTime": "2026-10-12T12:00:00Z",
            }
            for kind in ("standard", "operator")
        ]
        cases = [
            (passing, 0),
            ([], 1),
            ({}, 1),
            (passing[:1], 1),
            (passing + passing, 1),
            # Retained markers require completion and aggregate success evidence.
            ([dict(passing[0], status="BuildPLRInProgress"), passing[1]], 0),
            ([passing[0], dict(passing[1], status="BuildPLRInProgress")], 0),
        ]
        for status in ("InProgress", "TestSkipped", "TestFailed"):
            cases.append(([passing[0], dict(passing[1], status=status)], 1))
        for data, expected in cases:
            snapshot = {
                "metadata": {
                    "annotations": {
                        "test.appstudio.openshift.io/status": json.dumps(data)
                    }
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
            result = subprocess.run(
                ["bash", "-c", command], input=json.dumps(snapshot), text=True
            )
            self.assertEqual(result.returncode, expected, data)
        self.assertNotEqual(
            subprocess.run(
                ["bash", "-c", command], input="broken", text=True
            ).returncode,
            0,
        )

    def test_fbc_verifier_rejects_malformed_http_success_and_absent_snapshot(self):
        curl = self.root / "curl"
        curl.write_text("""#!/bin/bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) file=$2; shift 2 ;; *) shift ;; esac
done
if [ "${FIXTURE_VALID:-}" = yes ]; then
  printf 'image: quay.io/example@sha256:%064d\n' 0 > "$file"
else
  echo 'not a catalog' > "$file"
fi
printf 200
""")
        curl.chmod(0o755)
        oc = self.root / "oc"
        oc.write_text("""#!/bin/bash
echo '{"items":[]}'
""")
        oc.chmod(0o755)
        environment = dict(
            os.environ,
            PATH=str(self.root) + ":" + os.environ["PATH"],
            FBC_OCP_VERSIONS="5-0",
        )
        for mode, expected in [
            ("no", "malformed bundle content"),
            ("yes", "has no snapshot"),
        ]:
            result = subprocess.run(
                [str(ROOT / "scripts/verify-fbc-release.sh"), "0.24.1"],
                env=dict(environment, FIXTURE_VALID=mode),
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected, result.stderr)

    def test_stage_urls_require_exact_completed_publication(self):
        digest = 'b' * 64
        image = 'quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-19@sha256:' + 'a' * 64
        release = {
            'metadata': {'name': 'submariner-fbc-4-19-0-23-4-stage-20261012-02',
                         'creationTimestamp': '2026-10-12T19:00:00Z'},
            'spec': {'releasePlan': 'submariner-fbc-release-plan-stage-4-19',
                     'snapshot': 'submariner-fbc-4-19-replacement'},
            'status': {'conditions': [{'type': 'Released', 'status': 'True', 'reason': 'Succeeded'}],
                       'artifacts': {'components': [{'ocp_version': 'v4.19', 'fbc_fragment': image,
                                                     'target_index': '', 'target_index_with_timestamp': ''}]}}}
        snapshot = {'metadata': {'name': release['spec']['snapshot']},
                    'spec': {'application': 'submariner-fbc-4-19',
                             'components': [{'name': 'submariner-fbc-4-19', 'containerImage': image}]}}
        snapshot['status'] = {'conditions': [
            {'type': 'AppStudioIntegrationStatus', 'status': 'True', 'reason': 'Finished'},
            {'type': 'AppStudioTestSucceeded', 'status': 'True', 'reason': 'Passed'}]}
        snapshot['metadata']['annotations'] = {'test.appstudio.openshift.io/status': json.dumps([
            {'scenario': 'submariner-fbc-standard-4-19', 'status': 'BuildPLRInProgress', 'completionTime': '2026-10-12T18:00:00Z'},
            {'scenario': 'submariner-fbc-operator-4-19', 'status': 'TestPassed', 'completionTime': '2026-10-12T18:00:00Z'}])}
        bundle = {'name': 'submariner.v0.23.4', 'image': 'quay.io/example/bundle@sha256:' + digest}
        command = f'''source "{ROOT}/scripts/get-fbc-urls.sh"
VERSION=0.23.4; RAW_URL=true; OCP_FILTER=4-19
fbc_catalog_bundle_digest() {{ echo '{digest}'; }}
oc() {{
  if [ "$1 $2" = 'get releases' ]; then cat "$FIXTURE/releases.json"
  elif [ "$1 $2" = 'get snapshot' ]; then cat "$FIXTURE/snapshot.json"
  elif [ "$1 $2" = 'image extract' ]; then
    [ "${{EXTRACT_FAIL:-no}}" = no ] || return 1
    cp "$FIXTURE/bundle.yaml" "$TMPDIR/extract-4-19/bundle-v0.23.4.yaml"
  else return 1; fi
}}
get_urls
'''
        def run(r=release, s=snapshot, b=bundle, extra=''):
            (self.root / 'releases.json').write_text(json.dumps({'items': [r]}))
            (self.root / 'snapshot.json').write_text(json.dumps(s))
            (self.root / 'bundle.yaml').write_text(yaml.safe_dump(b))
            return subprocess.run(['bash', '-c', command.replace('get_urls\n', extra + '\nget_urls\n')],
                                  env=dict(os.environ, FIXTURE=str(self.root)),
                                  capture_output=True, text=True)
        good = run()
        self.assertEqual(good.returncode, 0, good.stderr)
        self.assertEqual(good.stdout.strip(), image)
        wrong_host = image.replace('quay.io/', 'quayXio/')
        wrong_release = json.loads(json.dumps(release))
        wrong_snapshot = json.loads(json.dumps(snapshot))
        wrong_release['status']['artifacts']['components'][0]['fbc_fragment'] = wrong_host
        wrong_snapshot['spec']['components'][0]['containerImage'] = wrong_host
        result = run(r=wrong_release, s=wrong_snapshot)
        self.assertNotEqual(result.returncode, 0, 'non-Quay registry accepted')
        self.assertEqual(result.stdout, '')
        # A newer failed attempt must not replace the exact completed stage publication.
        mutations = [
            ('pending', ['status', 'conditions', 0, 'status'], 'False'),
            ('wrong reason', ['status', 'conditions', 0, 'reason'], 'Running'),
            ('prod name', ['metadata', 'name'], 'submariner-fbc-4-19-0-23-4-prod-20261012-02'),
            ('other version', ['metadata', 'name'], 'submariner-fbc-4-19-0-23-3-stage-20261012-02'),
            ('other plan', ['spec', 'releasePlan'], 'submariner-fbc-release-plan-prod-4-19'),
            ('other OCP', ['status', 'artifacts', 'components', 0, 'ocp_version'], 'v4.20'),
            ('prod target', ['status', 'artifacts', 'components', 0, 'target_index'], 'production'),
            ('mutable tag', ['status', 'artifacts', 'components', 0, 'fbc_fragment'], image.split('@')[0] + ':latest'),
        ]
        for label, keys, value in mutations:
            with self.subTest(label=label):
                bad = json.loads(json.dumps(release)); cursor = bad
                for key in keys[:-1]: cursor = cursor[key]
                cursor[keys[-1]] = value
                result = run(r=bad)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(result.stdout, '')
        for label, s, b, extra in [
            ('image mismatch', dict(snapshot, spec=dict(snapshot['spec'], components=[{'name': 'submariner-fbc-4-19', 'containerImage': image + 'bad'}])), bundle, ''),
            ('missing completed tests', dict(snapshot, status={}), bundle, ''),
            ('wrong CSV', snapshot, dict(bundle, name='submariner.v0.23.3'), ''),
            ('wrong digest', snapshot, dict(bundle, image='quay.io/example/bundle@sha256:' + 'c' * 64), ''),
            ('extraction failed', snapshot, bundle, 'EXTRACT_FAIL=yes'),
            ('partial scope', snapshot, bundle, "OCP_FILTER=''; ALL_OCP_VERSIONS=(4-19 4-20)"),
        ]:
            with self.subTest(label=label):
                result = run(s=s, b=b, extra=extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_fbc_verifier_requires_literal_catalog_registry(self):
        script = (ROOT / 'scripts/verify-fbc-release.sh').read_text()
        guard = script[script.index('  if [[ ! "${CATALOG_IMAGES'):script.index('  EVENT_TYPES["${VERSION}"]')]
        command = 'VERSION=4-19; declare -A CATALOG_IMAGES; CATALOG_IMAGES[4-19]="$CATALOG"\n' + guard
        for host, expected in [('quay.io', 0), ('quayXio', 1)]:
            with self.subTest(host=host):
                image = host + '/redhat-user-workloads/submariner-tenant/submariner-fbc-4-19@sha256:' + 'a' * 64
                result = subprocess.run(['bash', '-c', command], capture_output=True, text=True,
                                        env=dict(os.environ, CATALOG=image))
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(result.stdout, '')

    def test_exact_snapshot_override_never_falls_back_to_old_push(self):
        script = (ROOT / 'scripts/verify-fbc-release.sh').read_text()
        selection = script[script.index('# Optional FBC_EXPECTED_SNAPSHOTS'):script.index('  FBC_REVISION=$(echo')]
        command = '''APPLICABLE_VERSIONS=(4-19)
ALL_SNAPSHOTS=$(cat "$FIXTURE")
''' + selection + '''  printf '%s\\n' "$SNAPSHOT_DATA"
  break
done
'''
        def snapshot(name, event, timestamp):
            return {'metadata': {'name': name, 'creationTimestamp': timestamp,
                                 'labels': {'pac.test.appstudio.openshift.io/event-type': event}},
                    'spec': {'application': 'submariner-fbc-4-19', 'components': [{'name': 'submariner-fbc-4-19'}]}}
        old = 'submariner-fbc-4-19-old'; replacement = 'submariner-fbc-4-19-replacement'
        (self.root / 'snapshots.json').write_text(json.dumps({'items': [snapshot(old, 'push', '2026-10-01'),
                                                                       snapshot(replacement, 'manual', '2026-10-12')]}))
        for override, expected in [({}, old), ({'4-19': replacement}, replacement)]:
            result = subprocess.run(['bash', '-c', command], capture_output=True, text=True,
                                    env=dict(os.environ, FIXTURE=str(self.root / 'snapshots.json'),
                                             FBC_EXPECTED_SNAPSHOTS=json.dumps(override)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['name'], expected)
        # Exact selection still executes the real push-provenance gate. A manual
        # replacement must fail there rather than pass via the older push.
        guarded = script[script.index('# Optional FBC_EXPECTED_SNAPSHOTS'):script.index('  if [[ ! "$FBC_REVISION"')]
        result = subprocess.run(['bash', '-c', 'APPLICABLE_VERSIONS=(4-19); ALL_SNAPSHOTS=$(cat "$FIXTURE")\n' + guarded + 'break; done'],
                                capture_output=True, text=True,
                                env=dict(os.environ, FIXTURE=str(self.root / 'snapshots.json'),
                                         FBC_EXPECTED_SNAPSHOTS=json.dumps({'4-19': replacement})))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not the push pipeline', result.stderr)
        self.assertEqual(result.stdout, '')
        for override in ['invalid', '[]', '{"4-20":"submariner-fbc-4-20-x"}',
                         '{"4-19":null}', '{"4-19":"submariner-fbc-4-20-x"}',
                         '{"4-19":"submariner-fbc-4-19-missing"}']:
            result = subprocess.run(['bash', '-c', command], capture_output=True, text=True,
                                    env=dict(os.environ, FIXTURE=str(self.root / 'snapshots.json'),
                                             FBC_EXPECTED_SNAPSHOTS=override))
            self.assertNotEqual(result.returncode, 0, override)
            self.assertEqual(result.stdout, '')

    def test_prod_reuses_exact_stage_snapshot_for_five(self):
        # Execute production's actual selection function without commits or network.
        script = (ROOT / "scripts/create-fbc-releases.sh").read_text()
        function = script[
            script.index("verify_release() {") : script.index(
                "\n# ===", script.index("verify_release() {")
            )
        ]
        directory = self.root / "releases/fbc/5-0/stage"
        directory.mkdir(parents=True)
        for version, snapshot in [("0-24-0", "older"), ("0-24-1", "qe-validated")]:
            (
                directory / f"submariner-fbc-5-0-{version}-stage-20260924-01.yaml"
            ).write_text(
                yaml.safe_dump(
                    {
                        "apiVersion": "appstudio.redhat.com/v1alpha1",
                        "kind": "Release",
                        "metadata": {
                            "name": f"submariner-fbc-5-0-{version}-stage-20260924-01",
                            "namespace": "submariner-tenant",
                            "annotations": {"snapshot": "decoy"},
                        },
                        "spec": {
                            "releasePlan": "submariner-fbc-release-plan-stage-5-0",
                            "snapshot": f"submariner-fbc-5-0-{snapshot}",
                        },
                    }
                )
            )
        env = dict(os.environ, GIT_ROOT=str(self.root))
        result = subprocess.run(
            [
                "bash",
                "-euc",
                function
                + '\nVERSION=0.24.1; RELEASE_TYPE=prod; OCP_FILTER=5-0; declare -A SNAPSHOTS; verify_release; echo "SELECTED=${SNAPSHOTS[5-0]}"',
            ],
            env=env,
            text=True,
            capture_output=True,
            check=True,
        )
        self.assertIn("SELECTED=submariner-fbc-5-0-qe-validated", result.stdout)

    def test_prod_index_uses_full_version_and_distinguishes_failure(self):
        executable = self.root / "oc"
        executable.write_text("""#!/bin/bash
printf '%s\n' "$3" > "$PROBE_LOG"
[ "${PROBE_FAIL:-}" != yes ] || exit 1
for arg in "$@"; do
  case "$arg" in /configs/submariner/bundles/:*)
    directory=${arg#*:}
    [ "${PROBE_ABSENT:-}" = yes ] || touch "$directory/bundle-v0.24.1.yaml" ;;
  esac
done
""")
        executable.chmod(0o755)
        environment = dict(
            os.environ,
            PATH=str(self.root) + ":" + os.environ["PATH"],
            PROBE_LOG=str(self.root / "image"),
        )
        command = f'source "{ROOT}/scripts/lib/prod-bundle.sh"; prod_index_has_bundle 5.0 0.24.1'
        for options, expected in [
            ({}, "present"),
            ({"PROBE_ABSENT": "yes"}, "absent"),
            ({"PROBE_FAIL": "yes"}, "unreachable"),
        ]:
            result = subprocess.run(
                ["bash", "-c", command],
                env=dict(environment, **options),
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertEqual(result.stdout.strip(), expected)
            self.assertTrue((self.root / "image").read_text().strip().endswith(":v5.0"))


if __name__ == "__main__":
    unittest.main()
