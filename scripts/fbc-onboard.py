#!/usr/bin/env python3
"""Prepare and inspect FBC onboarding without changing a caller's checkout."""

import argparse
import copy
import hashlib
import os
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

TENANT = Path("tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant")
OVERLAYS = TENANT / "overlay/application-submariner-fbc"
RPA = Path("config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/submariner")
GENERATED = Path(
    "tenants-config/auto-generated/cluster/kflux-prd-rh02/tenants/submariner-tenant"
)
PLATFORMS = ["linux/x86_64", "linux/arm64", "linux/ppc64le", "linux/s390x"]

OPERATOR_ITS_5 = "pipelineruns/deploy-fbc-operator/0.2/deploy-fbc-operator-run.yaml"


def run(*args, cwd=None, capture=True, env=None):
    return subprocess.run(
        args,
        cwd=cwd,
        env=env,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else sys.stderr,
    ).stdout


def ocp(value):
    if not re.fullmatch(r"[1-9][0-9]*[.-](?:0|[1-9][0-9]*)", value):
        raise argparse.ArgumentTypeError("OCP must be major.minor or major-minor")
    return value.replace(".", "-")


def stream(value):
    if not re.fullmatch(r"0\.(?:0|[1-9][0-9]*)", value):
        raise argparse.ArgumentTypeError("Submariner stream must be 0.Y")
    return value


def load(path):
    return yaml.safe_load(path.read_text())


def save(path, data):
    path.write_text(yaml.safe_dump(data, sort_keys=False, explicit_start=True))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def named_values(items, description):
    require(isinstance(items, list), f"{description} must be a list")
    require(
        all(
            isinstance(item, dict)
            and isinstance(item.get("name"), str)
            and "value" in item
            for item in items
        ),
        f"Malformed {description}",
    )
    values = {item["name"]: item["value"] for item in items}
    require(len(values) == len(items), f"Duplicate {description}")
    return values


def base_commit(root, ref):
    return run("git", "rev-parse", "--verify", f"{ref}^{{commit}}", cwd=root).strip()


def predecessor_at_ref(root, version, ref, pipelines=False):
    entries = run(
        "git",
        "ls-tree",
        "--name-only",
        f"{ref}:{'.tekton' if pipelines else OVERLAYS}",
        cwd=root,
    ).splitlines()
    if pipelines:
        candidates = [
            name.removeprefix("submariner-fbc-").removesuffix("-push.yaml")
            for name in entries
            if re.fullmatch(
                r"submariner-fbc-[1-9][0-9]*-(?:0|[1-9][0-9]*)-push.yaml", name
            )
            and name.replace("-push.yaml", "-pull-request.yaml") in entries
        ]
    else:
        candidates = [
            ocp(name.removesuffix("-overlay"))
            for name in entries
            if re.fullmatch(r"[1-9][0-9]*-(?:0|[1-9][0-9]*)-overlay", name)
        ]
    prior = [
        candidate
        for candidate in candidates
        if tuple(map(int, candidate.split("-"))) < tuple(map(int, version.split("-")))
    ]
    require(
        prior,
        "No preceding OCP pipeline pair"
        if pipelines
        else "No preceding OCP overlay in the selected base",
    )
    return max(prior, key=lambda value: tuple(map(int, value.split("-"))))


def repo(path, marker):
    path = path.expanduser().resolve()
    require((path / marker).is_file(), f"Wrong repository or missing {marker}: {path}")
    require(
        Path(run("git", "rev-parse", "--show-toplevel", cwd=path).strip()) == path,
        f"Expected repository root: {path}",
    )
    return path


def worktree(source, target, base, branch, check_only=False):
    """Never reset branches, switch a checkout, or overwrite an unrelated directory."""
    if target.exists():
        require(
            (target / ".git").is_file(), f"Existing path is not a worktree: {target}"
        )
        common = run(
            "git", "rev-parse", "--path-format=absolute", "--git-common-dir", cwd=source
        ).strip()
        require(
            run(
                "git",
                "rev-parse",
                "--path-format=absolute",
                "--git-common-dir",
                cwd=target,
            ).strip()
            == common,
            f"Worktree belongs to another repository: {target}",
        )
        require(
            run("git", "branch", "--show-current", cwd=target).strip() == branch,
            f"Worktree branch differs: {target}",
        )
        try:
            run("git", "merge-base", "--is-ancestor", base, "HEAD", cwd=target)
        except subprocess.CalledProcessError as error:
            raise ValueError(
                f"{target} does not contain {base}; review and rebase its changes or choose a fresh --workspace"
            ) from error
        return target
    # An existing branch can contain unique work: leave it for explicit reconciliation.
    refs = run(
        "git", "for-each-ref", "--format=%(refname)", f"refs/heads/{branch}", cwd=source
    )
    require(
        not refs.strip(), f"Branch {branch} already exists; select another --workspace"
    )
    if check_only:
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    run(
        "git",
        "worktree",
        "add",
        "-b",
        branch,
        str(target),
        base,
        cwd=source,
        capture=False,
    )
    return target


def atomic_text(path, text):
    """Publish a checked candidate without exposing a truncated YAML file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(text)
            output.flush()
            temporary.chmod(path.stat().st_mode & 0o777 if path.exists() else 0o644)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def sequence_item(text, keys, item):
    """Insert a scalar into block or flow YAML without rewriting comments."""
    original = yaml.safe_load(text)
    data, node = original, yaml.compose(text)
    for key in keys:
        data = data[key]
        require(isinstance(node, yaml.MappingNode), "Expected YAML mapping")
        matches = [value for name, value in node.value if name.value == key]
        require(len(matches) == 1, f"Missing or duplicate YAML key: {key}")
        node = matches[0]
    require(
        isinstance(data, list) and isinstance(node, yaml.SequenceNode),
        "Expected YAML sequence",
    )
    require(data.count(item) <= 1, f"Duplicate list item: {item}")
    if item in data:
        return text
    if node.flow_style:
        start, end = node.start_mark.index, node.end_mark.index
        require(
            text[start] == "[" and text[end - 1] == "]",
            "Unsupported anchored flow sequence",
        )
        insert = json.dumps(item) + (", " if node.value else "")
        candidate = text[: start + 1] + insert + text[start + 1 :]
    else:
        require(node.value, "Unsupported empty block sequence")
        first = node.value[0].start_mark
        start = text.rfind("\n", 0, first.index) + 1
        match = re.match(r"([ ]*)- ", text[start:])
        require(match, "Unsupported YAML sequence layout; use a block or flow list")
        candidate = text[:start] + match[1] + "- " + item + "\n" + text[start:]
    expected = json.loads(json.dumps(original))
    values = expected
    for key in keys:
        values = values[key]
    values.insert(0, item)
    require(
        yaml.safe_load(candidate) == expected, "YAML insertion changed unrelated values"
    )
    return candidate


def add_resource(path, resource, after=None):
    before = path.read_text()
    current = yaml.safe_load(before) or {}
    if resource in (current.get("resources") or []):
        return
    match = after and re.search(
        rf"^([ \t]*)- {re.escape(after)}[ \t]*(#.*)?$", before, re.MULTILINE
    )
    if match:
        end_line = match.end()
        candidate = (
            before[:end_line] + f"\n{match.group(1)}- {resource}" + before[end_line:]
        )
        expected = yaml.safe_load(candidate)
        if expected and resource in expected.get("resources", []):
            atomic_text(path, candidate)
            return
    candidate = sequence_item(before, ["resources"], resource)
    if candidate != before:
        atomic_text(path, candidate)


def target_tenant_objects(documents, version):
    objects = {}
    for data in documents:
        require(
            isinstance(data, dict) and isinstance(data.get("metadata"), dict),
            "Malformed tenant resource",
        )
        name = data["metadata"].get("name", "")
        if name.endswith(f"-{version}") and name.startswith(
            ("submariner-fbc-", "imagerepository-submariner-fbc-")
        ):
            key = (data["kind"], name)
            require(key not in objects, f"Duplicate generated object: {key}")
            objects[key] = data
    return objects


def operator_its_patch(text, base, version):
    """Carry reviewed ITS patches forward once; 5.x needs the 0.3 cluster picker."""
    patches = yaml.safe_load(text)
    require(
        isinstance(patches, list) and all(isinstance(op, dict) for op in patches),
        "Expected JSON patch list",
    )
    additions = []

    def parameter(keys, name, value):
        values = base
        for key in keys:
            values = values[key]
        indices = [i for i, item in enumerate(values) if item.get("name") == name]
        require(len(indices) == 1, f"Expected one base ITS parameter: {name}")
        index = indices[0]
        prefix = "/" + "/".join(keys) + f"/{index}"
        existing = [op for op in patches if op.get("path") == prefix + "/value"]
        if existing:
            require(
                len(existing) == 1
                and existing[0].get("op") == "replace"
                and existing[0].get("value") == value,
                f"Conflicting ITS patch: {name}",
            )
        elif values[index]["value"] != value:
            additions.extend(
                [
                    {"op": "test", "path": prefix + "/name", "value": name},
                    {"op": "replace", "path": prefix + "/value", "value": value},
                ]
            )

    def field(path, current, value):
        # current is None when the base omits the field.
        if current == value:
            return
        op = "add" if current is None else "replace"
        expected = {"op": op, "path": path, "value": value}
        existing = [op for op in patches if op.get("path") == path]
        if existing:
            require(existing == [expected], f"Conflicting ITS patch: {path}")
        else:
            additions.append(expected)

    parameter(["spec", "params"], "CHANNEL_NAME", "")
    if int(version.split("-")[0]) >= 5:
        parameter(["spec", "resolverRef", "params"], "pathInRepo", OPERATOR_ITS_5)
        field(
            "/spec/resolverRef/resourceKind",
            base["spec"].get("resolverRef", {}).get("resourceKind"),
            "pipelinerun",
        )
        key = {"name": "CREDENTIALS_SECRET_KEY", "value": ".dockerconfigjson"}
        if any(item.get("name") == key["name"] for item in base["spec"]["params"]):
            parameter(["spec", "params"], key["name"], key["value"])
        else:
            existing = [
                op
                for op in patches
                if isinstance(op.get("value"), dict)
                and op["value"].get("name") == key["name"]
            ]
            expected = {"op": "add", "path": "/spec/params/-", "value": key}
            if existing:
                require(existing == [expected], "Conflicting ITS credential-key patch")
            else:
                additions.append(expected)
        field(
            "/metadata/labels/test.appstudio.openshift.io~1optional",
            base.get("metadata", {}).get("labels", {}).get(
                "test.appstudio.openshift.io/optional"
            ),
            "true",
        )
    if additions:
        text = (text.rstrip() + "\n" if patches else "---\n") + yaml.safe_dump(
            additions, sort_keys=False
        )
    return text


def prepare_tenant(root, version, previous, kustomize=None):
    binary = kustomize_binary(root, kustomize)
    # The repository builder can inject authors into unrelated changed files and
    # render other applications. Run it on a disposable copy and publish our files.
    with tempfile.TemporaryDirectory(prefix="fbc-tenant-") as temporary:
        stage = Path(temporary)
        for relative in (TENANT, Path("tenants-config/lib")):
            shutil.copytree(root / relative, stage / relative, symlinks=True)
        for name in ("build-manifests.sh", "utils.sh", "ensure-releaseplan-authors.sh"):
            shutil.copy2(
                root / "tenants-config" / name, stage / "tenants-config" / name
            )
        source = stage / OVERLAYS / f"{previous}-overlay"
        dest = stage / OVERLAYS / f"{version}-overlay"
        require(
            len(list(source.glob("*.yaml"))) == 8,
            f"Unexpected predecessor overlay: {source}",
        )
        if not dest.exists():
            dest.mkdir()
            for path in source.glob("*.yaml"):
                (dest / path.name).write_text(
                    path.read_text()
                    .replace(previous, version)
                    .replace(previous.replace("-", "."), version.replace("-", "."))
                )
            base = load(
                stage / OVERLAYS / "base/integration-test-scenario-fbc-operator.yaml"
            )
            path = dest / "integration-test-scenario-fbc-operator-patch.yaml"
            path.write_text(operator_its_patch(path.read_text(), base, version))
        require(
            len(list(dest.glob("*.yaml"))) == 8,
            "Partial target overlay; review it or choose a fresh workspace",
        )
        registration = TENANT / "kustomization.yaml"
        add_resource(
            stage / registration,
            f"overlay/application-submariner-fbc/{version}-overlay",
            after=f"overlay/application-submariner-fbc/{previous}-overlay",
        )
        changed = stage / "changed-tenants"
        changed.write_text("cluster/kflux-prd-rh02/tenants/submariner-tenant\n")
        run(
            "./build-manifests.sh",
            binary,
            str(changed),
            cwd=stage / "tenants-config",
            capture=False,
            env=dict(os.environ, GITLAB_CI="true"),
        )
        validate_tenant(stage, version, binary)
        candidates = {registration: (stage / registration).read_text()}
        for path in dest.glob("*.yaml"):
            candidates[path.relative_to(stage)] = path.read_text()
        for path in (stage / GENERATED).glob("*.yaml"):
            if target_tenant_objects([load(path)], version):
                candidates[path.relative_to(stage)] = path.read_text()
        for relative, text in candidates.items():
            existing = root / relative
            if relative != registration and existing.exists():
                require(
                    existing.read_text() == text,
                    f"Conflicting existing output: {existing}; review/regenerate it explicitly",
                )
        for relative, text in candidates.items():
            path = root / relative
            if not path.exists() or path.read_text() != text:
                atomic_text(path, text)
    validate_tenant(root, version, binary)


def validate_tenant(root, version, kustomize=None):
    objects = target_tenant_objects(
        (load(path) for path in (root / GENERATED).glob("*.yaml")), version
    )
    names = validate_tenant_objects(objects, version)
    registration = load(root / TENANT / "kustomization.yaml")
    require(
        registration["resources"].count(
            f"overlay/application-submariner-fbc/{version}-overlay"
        )
        == 1,
        "Target overlay is missing or duplicated in tenant registration",
    )
    binary = kustomize_binary(root, kustomize)
    rendered = target_tenant_objects(
        yaml.safe_load_all(run(binary, "build", str(root / TENANT))), version
    )
    validate_tenant_objects(rendered, version)
    require(
        rendered == objects,
        "Generated tenant manifests differ from the current source; regenerate and review",
    )
    return names


def validate_tenant_objects(objects, version):
    app = f"submariner-fbc-{version}"
    expected = {
        ("Application", app),
        ("Component", app),
        ("ImageRepository", f"imagerepository-{app}"),
    }
    expected |= {
        ("ReleasePlan", f"submariner-fbc-release-plan-{env}-{version}")
        for env in ("stage", "prod")
    }
    expected |= {
        ("IntegrationTestScenario", f"submariner-fbc-{kind}-{version}")
        for kind in ("operator", "standard")
    }
    require(
        set(objects) == expected,
        f"Generated resource identities differ: {set(objects) ^ expected}",
    )
    for (kind, name), data in objects.items():
        require(
            data["metadata"]["namespace"] == "submariner-tenant",
            f"Wrong namespace: {name}",
        )
        if kind in ("Component", "IntegrationTestScenario", "ReleasePlan"):
            require(data["spec"]["application"] == app, f"Wrong application: {name}")
        if kind == "ReleasePlan":
            labels = data["metadata"]["labels"]
            require(
                labels.get("release.appstudio.openshift.io/standing-attribution")
                != "true"
                or labels.get("release.appstudio.openshift.io/author"),
                f"Standing-attribution ReleasePlan needs an author: {name}",
            )
            require(
                data["metadata"]["labels"].get(
                    "release.appstudio.openshift.io/auto-release"
                )
                == "false",
                f"Autorelease enabled: {name}",
            )
    for env in ("stage", "prod"):
        plan = objects["ReleasePlan", f"submariner-fbc-release-plan-{env}-{version}"]
        require(
            plan["spec"]["target"] == "rhtap-releng-tenant",
            f"Wrong {env} release target",
        )
        require(
            plan["metadata"]["labels"].get(
                "release.appstudio.openshift.io/releasePlanAdmission"
            )
            == f"submariner-fbc-{env}",
            f"Wrong {env} admission label",
        )
    repository = objects["ImageRepository", f"imagerepository-{app}"]
    require(
        repository["spec"]["image"]["name"] == f"submariner-tenant/{app}",
        "Wrong ImageRepository destination",
    )
    for label in ("application", "component"):
        require(
            repository["metadata"]["labels"].get(f"appstudio.redhat.com/{label}")
            == app,
            f"Wrong ImageRepository {label}",
        )
    for scenario in ("standard", "operator"):
        its = objects["IntegrationTestScenario", f"submariner-fbc-{scenario}-{version}"]
        expected_optional = (
            "true"
            if (scenario == "operator" and int(version.split("-")[0]) >= 5)
            else "false"
        )
        require(
            its["metadata"]["labels"].get("test.appstudio.openshift.io/optional")
            == expected_optional,
            f"Wrong {scenario} scenario optional label (expected {expected_optional})",
        )
        require(
            [context["name"] for context in its["spec"]["contexts"]]
            == (["application"] if scenario == "standard" else [f"component_{app}"]),
            f"Wrong {scenario} ITS contexts",
        )
        resolver = its["spec"]["resolverRef"]
        refs = named_values(resolver["params"], f"{scenario} ITS resolver params")
        require(resolver["resolver"] == "git", f"Wrong {scenario} ITS resolver")
        require(
            refs["revision"] == "main"
            or re.fullmatch(r"[0-9a-f]{40}", refs["revision"]),
            f"Unsupported {scenario} ITS revision; review the approved resolver",
        )
        if scenario == "standard":
            require(
                refs["url"].removesuffix(".git")
                == "https://github.com/konflux-ci/build-definitions"
                and refs["pathInRepo"] == "pipelines/enterprise-contract.yaml",
                "Wrong standard ITS pipeline",
            )
        else:
            require(
                refs["url"].removesuffix(".git")
                == "https://github.com/konflux-ci/tekton-integration-catalog"
                and refs["pathInRepo"]
                in (
                    "pipelines/deploy-fbc-operator/0.1/deploy-fbc-operator.yaml",
                    "pipelineruns/deploy-fbc-operator/0.2/deploy-fbc-operator-run.yaml",
                ),
                "Wrong or unreviewed operator ITS pipeline",
            )
    standard = objects["IntegrationTestScenario", f"submariner-fbc-standard-{version}"]
    require(
        named_values(standard["spec"]["params"], "standard ITS params")[
            "POLICY_CONFIGURATION"
        ]
        == "rhtap-releng-tenant/fbc-standard",
        "Wrong standard ITS policy",
    )
    component = objects["Component", app]
    source = component["spec"]["source"]["git"]
    require(
        source["url"].removesuffix(".git")
        == "https://github.com/stolostron/submariner-operator-fbc"
        and source["revision"] == "main"
        and source["dockerfileUrl"] == "catalog.Dockerfile",
        "Wrong Component source",
    )
    image = f"quay.io/redhat-user-workloads/submariner-tenant/{app}"
    require(
        component["spec"]["containerImage"] == image, "Wrong component output image"
    )
    operator = objects["IntegrationTestScenario", f"submariner-fbc-operator-{version}"]
    params = named_values(operator["spec"]["params"], "operator ITS params")
    require(params["PACKAGE_NAME"] == "submariner", "Wrong ITS package")
    require(params["OCI_REF"] == image, "Wrong ITS image")
    require(
        params["CREDENTIALS_SECRET_NAME"] == f"imagerepository-{app}-image-push",
        "Wrong ITS secret",
    )
    require(params["CHANNEL_NAME"] == "", "ITS must use the catalog default channel")
    if int(version.split("-")[0]) >= 5:
        refs = named_values(
            operator["spec"]["resolverRef"]["params"], "operator ITS resolver params"
        )
        require(
            refs["pathInRepo"] == OPERATOR_ITS_5,
            "OCP 5+ requires the reviewed 0.3 install pipeline wrapper",
        )
        require(
            operator["spec"]["resolverRef"].get("resourceKind") == "pipelinerun",
            "OCP 5+ ITS must set resolverRef resourceKind to pipelinerun",
        )
        require(
            params.get("CREDENTIALS_SECRET_KEY") == ".dockerconfigjson",
            "OCP 5+ ITS must select the image-push secret's .dockerconfigjson key",
        )
    require(
        operator["spec"]["contexts"][0]["name"] == f"component_{app}",
        "Wrong ITS component context",
    )
    return sorted(name for _, name in objects)


def prepare_rpas(root, version):
    candidates = {}
    for env in ("stage", "prod"):
        path = root / RPA / f"submariner-fbc-{env}.yaml"
        text = sequence_item(
            path.read_text(), ["spec", "applications"], f"submariner-fbc-{version}"
        )
        validate_rpa(yaml.safe_load(text), version, env)
        candidates[path] = text
    # Validate both environments before modifying either admission.
    for path, text in candidates.items():
        if path.read_text() != text:
            atomic_text(path, text)


def validate_rpa(data, version, env):
    require(
        data["kind"] == "ReleasePlanAdmission"
        and data["metadata"]["name"] == f"submariner-fbc-{env}"
        and data["metadata"]["namespace"] == "rhtap-releng-tenant",
        f"Wrong {env} admission identity",
    )
    require(
        data["metadata"]["labels"].get("release.appstudio.openshift.io/block-releases")
        == "false",
        f"Blocked {env} admission",
    )
    spec = data["spec"]
    require(
        spec["applications"].count(f"submariner-fbc-{version}") == 1,
        f"Missing/duplicate {env} admission application",
    )
    require(spec["origin"] == "submariner-tenant", f"Wrong {env} admission origin")
    require(
        spec["policy"] == ("fbc-stage" if env == "stage" else "fbc-standard"),
        f"Wrong {env} admission policy",
    )
    fbc = spec["data"]["fbc"]
    require(fbc["allowedPackages"] == ["submariner"], f"Wrong {env} allowed packages")
    require(
        fbc["fromIndex"]
        == "registry-proxy.engineering.redhat.com/rh-osbs/"
        + ("iib-pub-pending" if env == "stage" else "iib-pub")
        + ":{{ OCP_VERSION }}",
        f"Wrong {env} source index version or repository",
    )
    if env == "stage":
        require(
            fbc.get("stagedIndex") is True
            and fbc["targetIndex"] == ""
            and spec["data"]["intention"] == "staging",
            "Wrong stage destination",
        )
    else:
        require(
            not fbc.get("stagedIndex", False)
            and fbc["targetIndex"]
            == "quay.io/redhat-prod/redhat----redhat-operator-index:{{ OCP_VERSION }}"
            and spec["data"]["intention"] == "production",
            "Wrong prod destination",
        )
    params = named_values(
        spec["pipeline"]["pipelineRef"]["params"], "admission pipeline params"
    )
    require(
        spec["pipeline"]["pipelineRef"]["resolver"] == "git"
        and params["revision"] == "production"
        and params["url"].removesuffix(".git")
        == "https://github.com/konflux-ci/release-service-catalog"
        and params["pathInRepo"] == "pipelines/managed/fbc-release/fbc-release.yaml",
        f"Wrong {env} admission pipeline",
    )
    require(
        spec["pipeline"]["serviceAccountName"]
        == f"release-index-image-{'staging' if env == 'stage' else 'prod'}",
        f"Wrong {env} release service account",
    )
    require(
        fbc["publishingCredentials"]
        == (
            "staged-index-fbc-publishing-credentials"
            if env == "stage"
            else "fbc-production-publishing-credentials-redhat-prod"
        ),
        f"Wrong {env} publishing credentials",
    )
    require(
        fbc["requestTimeoutSeconds"] == 3000
        and fbc["buildTimeoutSeconds"] == 3000
        and spec["pipeline"]["timeouts"] == {"pipeline": "1h0m0s", "tasks": "1h0m0s"},
        f"Unexpected {env} release timeouts; review approved configuration",
    )


def pipeline_definition(root, data):
    spec = data["spec"]
    require(
        ("pipelineSpec" in spec) != ("pipelineRef" in spec),
        "Expected one pipeline definition",
    )
    if "pipelineSpec" in spec:
        return spec["pipelineSpec"]
    reference = spec["pipelineRef"]
    require(
        set(reference).issubset({"name", "apiVersion", "kind"})
        and reference.get("name"),
        "Unverified pipelineRef: resolve the referenced definition to a reviewed local Pipeline before claiming readiness",
    )
    definitions = []
    for path in (root / ".tekton").glob("*.yaml"):
        for doc in yaml.safe_load_all(path.read_text()):
            if (
                isinstance(doc, dict)
                and doc.get("kind") == "Pipeline"
                and doc.get("metadata", {}).get("name") == reference["name"]
            ):
                definitions.append(doc["spec"])
    require(
        len(definitions) == 1,
        "Unverified pipelineRef: expected exactly one matching local Pipeline definition",
    )
    return definitions[0]


def validate_pipeline_execution(definition, params):
    """Validate the reviewed Submariner OCI-artifact task family, not arbitrary Tekton."""
    defaults = definition.get("params", [])
    require(
        len({param["name"] for param in defaults}) == len(defaults),
        "Duplicate pipeline parameter declarations",
    )
    effective = {
        param["name"]: param["default"] for param in defaults if "default" in param
    }
    effective.update(params)
    for name, expected in {
        "path-context": ".",
        "skip-checks": "false",
        "build-image-index": "true",
        "build-args-file": "",
    }.items():
        require(
            effective.get(name) == expected,
            f"Wrong effective {name}: expected {expected!r}",
        )
    family = {
        "init": "init",
        "clone-repository": "git-clone-oci-ta",
        "fbc-inject-lifecycle": "fbc-inject-lifecycle-oci-ta",
        "run-opm-command": "run-opm-command-oci-ta",
        "prefetch-dependencies": "prefetch-dependencies-oci-ta",
        "build-images": "buildah-remote-oci-ta",
        "build-image-index": "build-image-index",
        "deprecated-base-image-check": "deprecated-image-check",
        "apply-tags": "apply-tags",
        "validate-fbc": "validate-fbc",
        "fbc-target-index-pruning-check": "fbc-target-index-pruning-check",
        "fbc-fips-check-oci-ta": "fbc-fips-check-oci-ta",
    }
    tasks = {task["name"]: task for task in definition.get("tasks", [])}
    require(
        set(tasks) == set(family)
        and len(tasks) == len(definition.get("tasks", []))
        and not definition.get("finally"),
        "Unverified pipeline task family: review missing/extra/duplicate tasks",
    )
    checks = {
        "deprecated-base-image-check",
        "validate-fbc",
        "fbc-target-index-pruning-check",
        "fbc-fips-check-oci-ta",
    }
    for name, task in tasks.items():
        require(
            "taskSpec" not in task
            and "taskRef" in task
            and task.get("onError", "stopAndFail") == "stopAndFail",
            f"Unsupported task execution: {name}",
        )
        ref = task["taskRef"]
        refs = named_values(ref["params"], f"{name} task reference")
        require(
            ref["resolver"] == "bundles"
            and refs.get("name") == family[name]
            and refs.get("kind") == "task"
            and re.fullmatch(
                r"quay\.io/konflux-ci/tekton-catalog/task-"
                + re.escape(family[name])
                + r":[^@]+@sha256:[0-9a-f]{64}",
                refs.get("bundle", ""),
            ),
            f"Unreviewed task reference: {name}",
        )
        allowed_guard = [
            {"input": "$(params.skip-checks)", "operator": "in", "values": ["false"]}
        ]
        require(
            not task.get("when") or (name in checks and task["when"] == allowed_guard),
            f"Task may be skipped: {name}",
        )
        require(
            name == "build-images" or not task.get("matrix"),
            f"Unexpected task matrix: {name}",
        )
    bindings = {
        "clone-repository": {
            "url": "$(params.git-url)",
            "revision": "$(params.revision)",
        },
        "fbc-inject-lifecycle": {
            "SOURCE_ARTIFACT": "$(tasks.clone-repository.results.SOURCE_ARTIFACT)",
            "CONTEXT": "$(params.path-context)",
            "DOCKERFILE": "$(params.dockerfile)",
            "BUILD_ARGS": ["$(params.build-args[*])"],
        },
        "run-opm-command": {
            "SOURCE_ARTIFACT": "$(tasks.fbc-inject-lifecycle.results.SOURCE_ARTIFACT)",
            "OPM_ARGS": [],
            "OPM_OUTPUT_PATH": "",
            "IDMS_PATH": "",
        },
        "prefetch-dependencies": {
            "SOURCE_ARTIFACT": "$(tasks.run-opm-command.results.SOURCE_ARTIFACT)"
        },
        "build-images": {
            "IMAGE": "$(params.output-image)",
            "DOCKERFILE": "$(params.dockerfile)",
            "CONTEXT": "$(params.path-context)",
            "BUILD_ARGS": ["$(params.build-args[*])"],
            "BUILD_ARGS_FILE": "$(params.build-args-file)",
            "SOURCE_ARTIFACT": "$(tasks.prefetch-dependencies.results.SOURCE_ARTIFACT)",
            "COMMIT_SHA": "$(tasks.clone-repository.results.commit)",
            "SOURCE_URL": "$(tasks.clone-repository.results.url)",
            "IMAGE_APPEND_PLATFORM": "true",
            "IMAGE_EXPIRES_AFTER": "$(params.image-expires-after)",
        },
        "build-image-index": {
            "IMAGE": "$(params.output-image)",
            "IMAGES": ["$(tasks.build-images.results.IMAGE_REF[*])"],
            "ALWAYS_BUILD_INDEX": "$(params.build-image-index)",
        },
    }
    for name in (
        "deprecated-base-image-check",
        "apply-tags",
        "validate-fbc",
        "fbc-target-index-pruning-check",
    ):
        bindings[name] = {
            "IMAGE_URL": "$(tasks.build-image-index.results.IMAGE_URL)",
            "IMAGE_DIGEST": "$(tasks.build-image-index.results.IMAGE_DIGEST)",
        }
    bindings["fbc-target-index-pruning-check"].update(
        {
            "TARGET_INDEX": "registry.redhat.io/redhat/redhat-operator-index",
            "RENDERED_CATALOG_DIGEST": "$(tasks.validate-fbc.results.RENDERED_CATALOG_DIGEST)",
        }
    )
    bindings["fbc-fips-check-oci-ta"] = {
        "image-url": "$(tasks.build-image-index.results.IMAGE_URL)",
        "image-digest": "$(tasks.build-image-index.results.IMAGE_DIGEST)",
    }
    for name, expected in bindings.items():
        values = named_values(tasks[name].get("params", []), f"{name} task params")
        require(
            all(values.get(key) == value for key, value in expected.items()),
            f"Incorrect parameter forwarding: {name}",
        )
    require(
        tasks["build-images"].get("matrix")
        in (
            {"params": [{"name": "PLATFORM", "value": ["$(params.build-platforms)"]}]},
            {
                "params": [
                    {"name": "PLATFORM", "value": ["$(params.build-platforms[*])"]}
                ]
            },
        ),
        "Build platforms are not forwarded to the image matrix",
    )
    results = named_values(definition.get("results", []), "pipeline results")
    for key, expected in {
        "IMAGE_URL": "$(tasks.build-image-index.results.IMAGE_URL)",
        "IMAGE_DIGEST": "$(tasks.build-image-index.results.IMAGE_DIGEST)",
        "CHAINS-GIT_URL": "$(tasks.clone-repository.results.url)",
        "CHAINS-GIT_COMMIT": "$(tasks.clone-repository.results.commit)",
    }.items():
        require(results.get(key) == expected, f"Wrong pipeline result: {key}")
    return effective


def pipelines(root, version, previous, base_image):
    candidates = {}
    for event in ("push", "pull-request"):
        path = root / ".tekton" / f"submariner-fbc-{version}-{event}.yaml"
        if path.exists():
            candidates[path] = path.read_text()
            continue
        source = root / ".tekton" / f"submariner-fbc-{previous}-{event}.yaml"
        require(
            source.exists(),
            f"No pipeline template: {source}; supply --pipeline-previous",
        )
        old_data = load(source)
        old_args = named_values(old_data["spec"]["params"], "predecessor params")[
            "build-args"
        ]
        old = [
            arg.removeprefix("OPM_IMAGE=")
            for arg in old_args
            if arg.startswith("OPM_IMAGE=")
        ]
        require(len(old) == 1, "Expected one explicit predecessor OPM_IMAGE")
        text = source.read_text()
        require(text.count(old[0]) == 1, "Ambiguous predecessor base-image reference")
        # Replace the actual argument first; an accepted digest override need not
        # contain the previous version's default registry tag.
        marker = "__FBC_ONBOARDING_BASE_IMAGE__"
        require(marker not in text, "Unexpected base-image placeholder")
        text = (
            text.replace(old[0], marker)
            .replace(previous, version)
            .replace(marker, base_image)
        )
        candidate = yaml.safe_load(text)
        require(
            candidate["spec"].get("pipelineSpec")
            == old_data["spec"].get("pipelineSpec")
            and candidate["spec"].get("pipelineRef")
            == old_data["spec"].get("pipelineRef"),
            "Version replacement changed the pipeline definition; review it explicitly",
        )
        candidates[path] = text
    with tempfile.TemporaryDirectory(prefix="fbc-pipelines-") as temporary:
        stage = Path(temporary)
        shutil.copytree(root / ".tekton", stage / ".tekton")
        for path, text in candidates.items():
            (stage / ".tekton" / path.name).write_text(text)
        validate_pipelines(stage, version, base_image)
    for path, text in candidates.items():
        if not path.exists():
            atomic_text(path, text)


def validate_pipelines(root, version, base_image):
    for event in ("push", "pull-request"):
        path = root / ".tekton" / f"submariner-fbc-{version}-{event}.yaml"
        data = load(path)
        app = f"submariner-fbc-{version}"
        require(data["kind"] == "PipelineRun", f"Not a PipelineRun: {path}")
        require(
            data["metadata"]["name"] == f"{app}-on-{event}",
            f"Wrong pipeline name: {path}",
        )
        for label in ("application", "component"):
            require(
                data["metadata"]["labels"][f"appstudio.openshift.io/{label}"] == app,
                f"Wrong {label}: {path}",
            )
        params = named_values(data["spec"]["params"], "pipeline params")
        definition = pipeline_definition(root, data)
        validate_pipeline_execution(definition, params)
        require(
            data["metadata"].get("namespace") == "submariner-tenant",
            f"Wrong pipeline namespace: {path}",
        )
        require(params.get("revision") == "{{revision}}", f"Wrong revision: {path}")
        require(
            params.get("git-url")
            in (
                "{{source_url}}",
                "https://github.com/stolostron/submariner-operator-fbc",
                "https://github.com/stolostron/submariner-operator-fbc.git",
            ),
            f"Wrong Git source: {path}",
        )
        require(
            len(params) == len(data["spec"]["params"]),
            f"Duplicate pipeline params: {path}",
        )
        require(
            sorted(params["build-platforms"]) == sorted(PLATFORMS),
            f"Wrong platforms: {path}",
        )
        require(
            params["dockerfile"] == "catalog.Dockerfile", f"Wrong Dockerfile: {path}"
        )
        arguments = params["build-args"]
        require(
            isinstance(arguments, list)
            and all(isinstance(arg, str) and "=" in arg for arg in arguments),
            f"Malformed build arguments: {path}",
        )
        build_args = dict(arg.split("=", 1) for arg in arguments)
        require(
            len(build_args) == len(arguments), f"Duplicate build argument keys: {path}"
        )
        require(
            build_args.get("INPUT_DIR") == f"catalog-{version}",
            f"Wrong INPUT_DIR: {path}",
        )
        require(build_args.get("OPM_IMAGE") == base_image, f"Wrong OPM_IMAGE: {path}")
        expected = (
            f"quay.io/redhat-user-workloads/submariner-tenant/{app}:"
            + ("on-pr-" if event == "pull-request" else "")
            + "{{revision}}"
        )
        require(params["output-image"] == expected, f"Wrong output image: {path}")
        annotations = data["metadata"]["annotations"]
        require(
            annotations["pipelinesascode.tekton.dev/cancel-in-progress"]
            == ("true" if event == "pull-request" else "false"),
            f"Wrong cancellation policy: {path}",
        )
        if event == "pull-request":
            require(params["image-expires-after"] == "5d", f"Wrong PR expiry: {path}")
        else:
            expiry = params.get("image-expires-after")
            if "image-expires-after" not in params:
                defaults = [
                    parameter.get("default")
                    for parameter in definition.get("params", [])
                    if parameter.get("name") == "image-expires-after"
                ]
                require(
                    len(defaults) == 1, f"Cannot determine push image expiry: {path}"
                )
                expiry = defaults[0]
            require(expiry == "", f"Push images must not expire: {path}")
        cel = annotations["pipelinesascode.tekton.dev/on-cel-expression"]
        # Accept the documented positive path-trigger grammar. Substring checks
        # also accept disabled expressions and the wrong event or target branch.
        expression = re.fullmatch(
            r'event\s*==\s*"'
            + event.replace("-", "_")
            + r'"\s*&&\s*target_branch\s*==\s*"main"\s*&&\s*\((.*)\)',
            cel.strip(),
            re.S,
        )
        require(expression, f"Wrong/unsupported event or branch expression: {path}")
        triggers = [
            re.fullmatch(r'"([^"\n]+)"\.pathChanged\(\)', term.strip())
            for term in expression[1].split("||")
        ]
        require(all(triggers), f"Unsupported path trigger expression: {path}")
        paths = [trigger[1] for trigger in triggers]
        expected_paths = [
            f"catalog-{version}/***",
            ".tekton/images-mirror-set.yaml",
            "catalog.Dockerfile",
        ] + [f".tekton/{app}-{mode}.yaml" for mode in ("push", "pull-request")]
        require(
            sorted(paths) == sorted(expected_paths),
            f"Missing, duplicate, or unexpected CEL paths: {path}",
        )
        require(
            ("pipelineSpec" in data["spec"]) != ("pipelineRef" in data["spec"]),
            f"Expected one pipeline definition: {path}",
        )
        require(
            data["spec"]["taskRunTemplate"]["serviceAccountName"]
            == f"build-pipeline-{app}",
            f"Wrong service account: {path}",
        )


def prepare_catalog(root, args, previous, base_image):
    require(
        (root / "test/lib/isolate.sh").is_file(),
        "Selected FBC base lacks isolated tests; land the safety changes first",
    )
    mapping = json.loads((root / "drop-versions.json").read_text())
    cutoff = catalog_inputs(
        load(root / "catalog-template.yaml"), mapping, args.ocp, args.min_supported_sub
    )
    dotted = args.ocp.replace("-", ".")
    with tempfile.TemporaryDirectory(prefix="fbc-catalog-") as temporary:
        stage = Path(temporary) / "candidate"
        shutil.copytree(
            root,
            stage,
            symlinks=True,
            ignore=shutil.ignore_patterns(".git", ".catalog-build*", "__pycache__"),
        )
        staged_mapping = dict(mapping, **{dotted: cutoff})
        # Render only this addition; validate the full candidate map afterward.
        (stage / "drop-versions.json").write_text(json.dumps({dotted: cutoff}) + "\n")
        pipelines(stage, args.ocp, previous, base_image)
        run("make", "build-catalogs", cwd=stage, capture=False)
        (stage / "drop-versions.json").write_text(
            json.dumps(staged_mapping, indent=2) + "\n"
        )
        run("make", "validate-catalogs", cwd=stage, capture=False)
        run("make", "test", cwd=stage, capture=False)
        validate_catalog(stage, args.ocp, args.min_supported_sub)
        candidates = {
            Path(".tekton") / f"submariner-fbc-{args.ocp}-{event}.yaml": (
                stage / ".tekton" / f"submariner-fbc-{args.ocp}-{event}.yaml"
            ).read_text()
            for event in ("push", "pull-request")
        }
        catalog = Path(f"catalog-{args.ocp}")
        for path in (stage / catalog).rglob("*"):
            if path.is_file():
                candidates[path.relative_to(stage)] = path.read_text()
        if (root / catalog).exists():
            actual = {
                path.relative_to(root)
                for path in (root / catalog).rglob("*")
                if path.is_file()
            }
            expected = {path for path in candidates if path.parts[0] == str(catalog)}
            require(
                actual == expected,
                "Existing target catalog file set differs; review conflicting output",
            )
        for relative, text in candidates.items():
            path = root / relative
            require(
                not path.exists() or path.read_text() == text,
                f"Conflicting existing catalog/pipeline: {path}; review it explicitly",
            )
        for relative, text in candidates.items():
            if not (root / relative).exists():
                atomic_text(root / relative, text)
        if dotted not in mapping:
            atomic_text(
                root / "drop-versions.json", json.dumps(staged_mapping, indent=2) + "\n"
            )
        (root / "bin").mkdir(exist_ok=True)
        for name in ("opm", "grpcurl"):
            source = stage / "bin" / name
            if source.is_file() and not (root / "bin" / name).exists():
                shutil.copy2(source, root / "bin" / name)
    validate_catalog(root, args.ocp, args.min_supported_sub)


def bundle_stream(name):
    match = re.fullmatch(
        r"submariner\.v([0-9]+)\.([0-9]+)\.[0-9]+(?:[+-][0-9A-Za-z.-]+)?", name
    )
    require(match, f"Unsupported Submariner bundle name: {name}")
    return tuple(map(int, match.groups()))


def catalog_contract(root, version, minimum=None):
    mapping = json.loads((root / "drop-versions.json").read_text())
    dotted = version.replace("-", ".")
    require(dotted in mapping, f"Catalog {dotted} is not registered in the build map")
    cutoff = stream(mapping[dotted])
    retained = f"0.{int(cutoff.split('.')[1]) + 1}"
    require(
        not minimum or minimum == retained,
        "Catalog build map conflicts with the requested minimum",
    )
    threshold = tuple(map(int, retained.split(".")))
    template = load(root / "catalog-template.yaml")
    catalog_inputs(template, mapping, version, retained)
    packages = [
        entry for entry in template["entries"] if entry.get("schema") == "olm.package"
    ]
    channels, bundles = {}, {}
    for entry in template["entries"]:
        if entry.get("schema") == "olm.channel":
            match = re.fullmatch(r"stable-([0-9]+)\.([0-9]+)", entry["name"])
            require(match, f"Unreviewed channel naming: {entry['name']}")
            if tuple(map(int, match.groups())) < threshold:
                continue
            channel = copy.deepcopy(entry)
            channel["entries"] = [
                item
                for item in channel["entries"]
                if bundle_stream(item["name"]) >= threshold
            ]
            require(channel["entries"], f"Empty retained channel: {channel['name']}")
            if len(channel["entries"]) == 1:
                channel["entries"][0].pop("replaces", None)
            require(channel["name"] not in channels, "Duplicate template channel")
            channels[channel["name"]] = channel
        elif entry.get("schema") == "olm.bundle":
            require(entry["name"] not in bundles, "Duplicate template bundle")
            bundles[entry["name"]] = entry
    referenced = {
        entry["name"] for channel in channels.values() for entry in channel["entries"]
    }
    require(
        referenced and referenced.issubset(bundles),
        "Template graph references missing bundles",
    )
    images = {}
    for name in referenced:
        image = re.sub(
            r"^quay\.io/redhat-user-workloads/[^:@]+",
            "registry.redhat.io/rhacm2/submariner-operator-bundle",
            bundles[name]["image"],
        )
        require(
            re.fullmatch(r"[^@]+@sha256:[0-9a-f]{64}", image),
            f"Unpinned template bundle: {name}",
        )
        images[name] = image
    return packages[0], channels, images


def validate_catalog_contents(
    directory, expected_package, expected_channels, expected_images
):
    require(
        load(directory / "package.yaml") == expected_package,
        "Catalog package differs from the selected template",
    )
    channels = {}
    for path in (directory / "channels").glob("*.yaml"):
        channel = load(path)
        require(channel["name"] not in channels, "Duplicate rendered channel")
        channels[channel["name"]] = channel
    require(
        channels == expected_channels,
        "Catalog channels or upgrade graph differ from the cutoff/template",
    )
    images = {}
    for path in (directory / "bundles").glob("*.yaml"):
        data = load(path)
        require(
            data["schema"] == "olm.bundle" and data["package"] == "submariner",
            f"Wrong bundle package: {path}",
        )
        name = data["name"]
        require(name not in images, "Duplicate rendered bundle")
        properties = [
            item["value"]
            for item in data["properties"]
            if item["type"] == "olm.package"
        ]
        require(
            len(properties) == 1
            and properties[0]["packageName"] == "submariner"
            and properties[0]["version"] == name.removeprefix("submariner.v"),
            f"Bundle name/package/version mismatch: {path}",
        )
        images[name] = data["image"]
    require(
        images == expected_images,
        "Rendered bundle names/digests differ from the selected template and cutoff",
    )
    return len(images)


def validate_catalog(root, version, minimum):
    directory = root / f"catalog-{version}"
    count = validate_catalog_contents(
        directory, *catalog_contract(root, version, minimum)
    )
    run(str(root / "bin/opm"), "validate", str(directory), capture=False)
    return count


def require_merged_commit(commit):
    helper = Path(__file__).resolve().parent / "lib/fbc-snapshot.sh"
    run(
        "bash",
        "-c",
        'source "$1"; fbc_revision_on_main "$2"',
        "fbc-onboarding",
        str(helper),
        commit,
    )


def catalog_git_files(commit, version):
    tree = json.loads(
        run(
            "gh",
            "api",
            f"repos/stolostron/submariner-operator-fbc/git/trees/{commit}?recursive=1",
        )
    )
    require(
        tree.get("truncated") is False,
        "GitHub tree is incomplete; cannot verify catalog contents",
    )
    prefix = f"catalog-{version}/"
    expected = {}
    for item in tree["tree"]:
        if item["path"].startswith(prefix) and item["type"] == "blob":
            require(
                item["mode"] == "100644", "Catalog source must contain regular files"
            )
            expected[item["path"][len(prefix) :]] = item["sha"]
    require(
        "package.yaml" in expected
        and any(name.startswith("bundles/") for name in expected)
        and any(name.startswith("channels/") for name in expected),
        "Merged commit has no complete requested catalog",
    )
    return expected


def git_blob(data):
    return hashlib.sha1(
        f"blob {len(data)}\0".encode() + data, usedforsecurity=False
    ).hexdigest()


def merged_catalog_contract(commit, version, minimum=None):
    with tempfile.TemporaryDirectory(prefix="fbc-source-contract-") as temporary:
        root = Path(temporary)
        for name in ("drop-versions.json", "catalog-template.yaml"):
            text = run(
                "gh",
                "api",
                "-H",
                "Accept: application/vnd.github.raw+json",
                f"repos/stolostron/submariner-operator-fbc/contents/{name}?ref={commit}",
            )
            (root / name).write_text(text)
        return catalog_contract(root, version, minimum)


def verify_catalog_images(image, manifests, expected, contract):
    """Reuse oc image extraction, comparing every platform's complete catalog to Git."""
    checked = []
    with tempfile.TemporaryDirectory(prefix="fbc-live-content-") as temporary:
        for manifest in manifests:
            architecture = manifest["platform"]["architecture"]
            directory = Path(temporary) / architecture
            directory.mkdir()
            reference = image.split("@")[0] + "@" + manifest["digest"]
            run(
                "oc",
                "image",
                "extract",
                reference,
                f"--filter-by-os=linux/{architecture}",
                "--path",
                f"/configs/submariner/:{directory}/",
                "--confirm",
                capture=False,
            )
            paths = list(directory.rglob("*"))
            require(
                not any(path.is_symlink() for path in paths),
                "Image catalog contains symbolic links",
            )
            actual = {
                str(path.relative_to(directory)): git_blob(path.read_bytes())
                for path in paths
                if path.is_file()
            }
            require(
                actual == expected,
                f"Published {architecture} catalog differs from the expected merged source",
            )
            validate_catalog_contents(directory, *contract)
            checked.append(architecture)
    return checked


def snapshot_tests_complete(snapshot, tests):
    """Match fbc_tests_passed: retained BuildPLRInProgress markers need completion evidence."""

    def condition(kind, reason):
        matches = [
            c
            for c in snapshot.get("status", {}).get("conditions", [])
            if c.get("type") == kind
        ]
        return (
            len(matches) == 1
            and matches[0].get("status") == "True"
            and matches[0].get("reason") == reason
        )

    return (
        condition("AppStudioIntegrationStatus", "Finished")
        and condition("AppStudioTestSucceeded", "Passed")
        and all(
            isinstance(test.get("completionTime"), str)
            and test["completionTime"]
            and test.get("status") in ("TestPassed", "TestWarning", "BuildPLRInProgress")
            for test in tests
        )
    )


def verify_live(args, base_image):
    """Keep configuration, build/content, and actual runtime evidence separate."""
    require(
        args.expected_commit and re.fullmatch(r"[0-9a-f]{40}", args.expected_commit),
        "verify-live requires --expected-commit with the merged 40-character SHA",
    )
    app, namespace = f"submariner-fbc-{args.ocp}", "submariner-tenant"
    result = {
        "ocp": args.ocp,
        "expected_commit": args.expected_commit,
        "errors": [],
        "configuration_ready": False,
        "build_ready": False,
        "runtime_on_requested_ocp": "unverified; inspect install task execution, selected bundle and actual cluster version",
    }

    def get(kind, name, target=namespace):
        return json.loads(run("oc", "get", kind, name, "-n", target, "-o", "json"))

    try:
        identities = [
            ("Application", app),
            ("Component", app),
            ("ImageRepository", f"imagerepository-{app}"),
        ]
        identities += [
            ("IntegrationTestScenario", f"submariner-fbc-{kind}-{args.ocp}")
            for kind in ("standard", "operator")
        ]
        identities += [
            ("ReleasePlan", f"submariner-fbc-release-plan-{env}-{args.ocp}")
            for env in ("stage", "prod")
        ]
        objects = {
            identity: get(identity[0].lower(), identity[1]) for identity in identities
        }
        for (kind, name), obj in objects.items():
            require(
                obj["kind"] == kind and obj["metadata"]["name"] == name,
                f"Unexpected live resource: {kind}/{name}",
            )
        validate_tenant_objects(objects, args.ocp)
        for env in ("stage", "prod"):
            plan_name = f"submariner-fbc-release-plan-{env}-{args.ocp}"
            plan = objects["ReleasePlan", plan_name]
            matched = plan["status"]["releasePlanAdmission"]
            require(
                matched.get("active") is True
                and matched.get("name") == f"rhtap-releng-tenant/submariner-fbc-{env}",
                f"Wrong/inactive {env} admission",
            )
            require(
                any(
                    c["type"] == "Matched" and c["status"] == "True"
                    for c in plan["status"]["conditions"]
                ),
                f"Unmatched {env} ReleasePlan",
            )
            admission = get(
                "releaseplanadmission", f"submariner-fbc-{env}", "rhtap-releng-tenant"
            )
            validate_rpa(admission, args.ocp, env)
            require(
                any(
                    plan.get("name") == f"{namespace}/{plan_name}"
                    for plan in admission["status"]["releasePlans"]
                ),
                f"{env} admission has not matched this ReleasePlan",
            )
        account = get("serviceaccount", f"build-pipeline-{app}")
        require(
            any(
                owner.get("kind") == "Component" and owner.get("name") == app
                for owner in account["metadata"].get("ownerReferences", [])
            ),
            "Build account is not owned by this Component",
        )
        secret = f"imagerepository-{app}-image-push"
        require(
            secret in {item["name"] for item in account.get("secrets", [])},
            "Image-push secret is not bound to the build account",
        )
        # Return only the secret type and key names, never credential values.
        template = (
            r'{{.type}}{{"\n"}}{{range $key, $value := .data}}{{$key}}{{"\n"}}{{end}}'
        )
        keys = run(
            "oc",
            "get",
            "secret",
            secret,
            "-n",
            namespace,
            "-o",
            "go-template=" + template,
        ).splitlines()
        require(
            keys and keys[0] in ("kubernetes.io/dockerconfigjson", "Opaque"),
            "Unexpected image-push secret type",
        )
        operator = objects[
            "IntegrationTestScenario", f"submariner-fbc-operator-{args.ocp}"
        ]
        params = named_values(operator["spec"]["params"], "operator ITS params")
        credential_key = params.get("CREDENTIALS_SECRET_KEY", ".dockerconfigjson")
        require(
            credential_key in keys[1:],
            "Operator ITS credential key is absent from its image-push secret",
        )
        result["configuration_ready"] = True
    except (
        ValueError,
        KeyError,
        TypeError,
        OSError,
        subprocess.CalledProcessError,
    ) as error:
        result["errors"].append("Configuration could not be verified: " + str(error))

    try:
        validate_base_reference(base_image, args.ocp)
        require_merged_commit(args.expected_commit)
        result["merged_on_main"] = True
        expected_files = catalog_git_files(args.expected_commit, args.ocp)
        contract = merged_catalog_contract(
            args.expected_commit, args.ocp, getattr(args, "min_supported_sub", None)
        )
        snapshots = json.loads(
            run(
                "oc",
                "get",
                "snapshots",
                "-n",
                namespace,
                "-l",
                f"appstudio.openshift.io/application={app}",
                "-o",
                "json",
            )
        )["items"]
        candidates = [
            snapshot
            for snapshot in snapshots
            if snapshot["spec"]["application"] == app
            and snapshot["metadata"]
            .get("labels", {})
            .get("pac.test.appstudio.openshift.io/event-type")
            == "push"
            and snapshot["metadata"]
            .get("labels", {})
            .get("pac.test.appstudio.openshift.io/original-prname")
            == f"{app}-on-push"
            and len(snapshot["spec"]["components"]) == 1
            and snapshot["spec"]["components"][0].get("name") == app
            and snapshot["spec"]["components"][0]
            .get("source", {})
            .get("git", {})
            .get("revision")
            == args.expected_commit
        ]
        require(candidates, "No original push snapshot for the expected merged commit")
        snapshot = max(
            candidates, key=lambda snap: snap["metadata"]["creationTimestamp"]
        )
        result["snapshot"] = snapshot["metadata"]["name"]
        tests = json.loads(
            snapshot["metadata"]["annotations"]["test.appstudio.openshift.io/status"]
        )
        names = [test["scenario"] for test in tests]
        required = {
            f"submariner-fbc-{kind}-{args.ocp}" for kind in ("standard", "operator")
        }
        require(
            required.issubset(names)
            and len(names) == len(set(names))
            and snapshot_tests_complete(snapshot, tests),
            "Required snapshot tests are missing or incomplete",
        )
        build = get(
            "pipelinerun",
            snapshot["metadata"]["labels"]["appstudio.openshift.io/build-pipelinerun"],
        )
        require(
            any(
                c["type"] == "Succeeded" and c["status"] == "True"
                for c in build["status"]["conditions"]
            ),
            "Build PipelineRun did not succeed",
        )
        labels, annotations = (
            build["metadata"].get("labels", {}),
            build["metadata"].get("annotations", {}),
        )
        require(
            all(
                labels.get(f"appstudio.openshift.io/{key}") == app
                for key in ("application", "component")
            ),
            "Build application/component differs",
        )
        require(
            annotations.get("pipelinesascode.tekton.dev/event-type") == "push"
            and annotations.get("build.appstudio.redhat.com/target_branch") == "main",
            "Build is not an original push to main",
        )
        require(
            build["spec"]["taskRunTemplate"]["serviceAccountName"]
            == f"build-pipeline-{app}",
            "Wrong live build account",
        )
        params = named_values(build["spec"]["params"], "live build params")
        definition = build["status"].get("pipelineSpec") or build["spec"].get(
            "pipelineSpec"
        )
        require(
            definition,
            "Resolved build pipeline is unavailable; execution is unverified",
        )
        effective = validate_pipeline_execution(definition, params)
        require(
            effective.get("image-expires-after") == "",
            "Live push images must not expire",
        )
        require(
            params["git-url"].removesuffix(".git")
            == "https://github.com/stolostron/submariner-operator-fbc",
            "Wrong build source URL",
        )
        require(
            params["revision"] == args.expected_commit,
            "Build revision differs from expected commit",
        )
        require(
            sorted(params["build-platforms"]) == sorted(PLATFORMS),
            "Build did not request all four platforms",
        )
        require(params["dockerfile"] == "catalog.Dockerfile", "Wrong live Dockerfile")
        arguments = params["build-args"]
        require(
            isinstance(arguments, list)
            and all(isinstance(arg, str) and "=" in arg for arg in arguments),
            "Malformed live build arguments",
        )
        build_args = dict(arg.split("=", 1) for arg in arguments)
        require(
            len(build_args) == len(arguments)
            and build_args.get("INPUT_DIR") == f"catalog-{args.ocp}"
            and build_args.get("OPM_IMAGE") == base_image,
            "Wrong/duplicate live catalog or base-image arguments",
        )
        image = snapshot["spec"]["components"][0]["containerImage"]
        expected_repo = f"quay.io/redhat-user-workloads/submariner-tenant/{app}"
        require(
            re.fullmatch(re.escape(expected_repo) + r"@sha256:[0-9a-f]{64}", image),
            "Snapshot image must have the expected repository and a SHA256 digest",
        )
        require(
            params["output-image"] == f"{expected_repo}:{args.expected_commit}",
            "Wrong live push image tag",
        )
        source = snapshot["spec"]["components"][0]["source"]["git"]
        require(
            source["url"].removesuffix(".git")
            == "https://github.com/stolostron/submariner-operator-fbc",
            "Wrong snapshot source URL",
        )
        results = named_values(build["status"]["results"], "build results")
        require(
            results.get("IMAGE_DIGEST") == image.split("@")[1]
            and results.get("IMAGE_URL", "").split(":")[0] == expected_repo,
            "Build image results do not match the snapshot",
        )
        manifest = json.loads(run("skopeo", "inspect", "--raw", f"docker://{image}"))
        children = [
            item
            for item in manifest["manifests"]
            if item.get("platform", {}).get("os") == "linux"
        ]
        arches = [item["platform"]["architecture"] for item in children]
        require(
            len(manifest["manifests"]) == 4
            and sorted(arches) == ["amd64", "arm64", "ppc64le", "s390x"],
            "Published image has missing/duplicate/unexpected build platforms",
        )
        for item in children:
            require(
                re.fullmatch(r"sha256:[0-9a-f]{64}", item["digest"]),
                "Malformed child-image digest",
            )
            child = json.loads(
                run(
                    "skopeo",
                    "inspect",
                    "--raw",
                    "docker://" + expected_repo + "@" + item["digest"],
                )
            )
            require(
                child.get("annotations", {}).get("org.opencontainers.image.base.name")
                == base_image,
                f"Wrong/missing base annotation for {item['platform']['architecture']}",
            )
            validate_image_target(
                json.loads(
                    run(
                        "skopeo",
                        "inspect",
                        "--config",
                        "docker://" + expected_repo + "@" + item["digest"],
                    )
                )
            )
        result["catalog_content_verified"] = verify_catalog_images(
            image, children, expected_files, contract
        )
        result.update(build_ready=True, image=image, platforms=sorted(arches))
    except (
        ValueError,
        KeyError,
        TypeError,
        OSError,
        subprocess.CalledProcessError,
    ) as error:
        result["errors"].append("Build/content could not be verified: " + str(error))
    print(json.dumps(result, indent=2))
    return not result["errors"]


def git_text(root, ref, path):
    return run("git", "show", f"{ref}:{path}", cwd=root)


def require_tools(*names):
    missing = [name for name in names if not shutil.which(name)]
    require(not missing, "Missing required tools: " + ", ".join(missing))


def kustomize_binary(root, requested=None, ref=None):
    binary = str(requested) if requested else shutil.which("kustomize")
    require(
        binary and shutil.which(binary),
        "Kustomize is required; select it with --kustomize",
    )
    source = (
        git_text(root, ref, "tenants-config/utils.sh")
        if ref
        else (root / "tenants-config/utils.sh").read_text()
    )
    required = re.search(r"KUSTOMIZE_VERSION=['\"]?(v[0-9]+\.[0-9]+\.[0-9]+)", source)
    require(
        required, "Cannot determine the selected repository's Kustomize requirement"
    )
    actual = re.search(r"v([0-9]+\.[0-9]+\.[0-9]+)", run(binary, "version"))
    require(
        actual
        and tuple(map(int, actual[1].split(".")))
        >= tuple(map(int, required[1][1:].split("."))),
        f"Kustomize {required[1]} or newer required; use --kustomize /path/to/kustomize",
    )
    return str(Path(shutil.which(binary)).resolve())


def catalog_inputs(template, mapping, version, minimum):
    require(minimum, "Choose --min-supported-sub before catalog preparation")
    cutoff = f"0.{int(minimum.split('.')[1]) - 1}"
    dotted = version.replace("-", ".")
    require(
        dotted not in mapping or mapping[dotted] == cutoff,
        f"Existing {dotted} cutoff conflicts with requested minimum",
    )
    channels = [
        entry for entry in template["entries"] if entry.get("schema") == "olm.channel"
    ]
    require(
        any(
            entry["name"] == f"stable-{minimum}" and entry.get("entries")
            for entry in channels
        ),
        f"No populated stable-{minimum} channel in template; add its bundles first",
    )
    packages = [
        entry for entry in template["entries"] if entry.get("schema") == "olm.package"
    ]
    require(
        len(packages) == 1 and packages[0]["name"] == "submariner",
        "Expected one Submariner package",
    )
    default = packages[0]["defaultChannel"]
    require(
        any(
            entry["name"] == default
            and entry.get("entries")
            and stream(entry["name"].removeprefix("stable-"))
            and int(entry["name"].split(".")[-1]) >= int(minimum.split(".")[-1])
            for entry in channels
        ),
        "The selected cutoff removes the populated default channel",
    )
    return cutoff


def validate_base_reference(image, version):
    # The deployed release filter derives OCP_VERSION from this exact tag when
    # there is no com.redhat.fbc.openshift.version label (our Dockerfile has none).
    require(
        image.count(":") == 1
        and image.rsplit(":", 1)[-1] == "v" + version.replace("-", "."),
        "OPM base must use the requested :vX.Y tag without a port or digest for the release version filter",
    )


def validate_image_target(config):
    # This reviewed pipeline family uses the base tag. A label takes precedence
    # in release, and its array form is not supported by the pinned pruning task.
    labels = config.get("config", {}).get("Labels") or {}
    require(
        "com.redhat.fbc.openshift.version" not in labels,
        "Unreviewed OCP target label overrides the base; review pipeline and release label support",
    )


def inspect_base_image(image, version=None):
    if version:
        validate_base_reference(image, version)
    require_tools("skopeo")
    manifest = json.loads(run("skopeo", "inspect", "--raw", f"docker://{image}"))
    arches = {
        item.get("platform", {}).get("architecture")
        for item in manifest.get("manifests", [])
        if item.get("platform", {}).get("os") == "linux"
    }
    require(
        {"amd64", "arm64", "ppc64le", "s390x"}.issubset(arches),
        "Selected OPM base must provide amd64, arm64, ppc64le and s390x",
    )
    validate_image_target(
        json.loads(run("skopeo", "inspect", "--config", f"docker://{image}"))
    )
    return sorted(arches)


def verify_workspace(workspace, args, image):
    validate_base_reference(image, args.ocp)
    result = {
        "tenant_resources": validate_tenant(
            workspace / "tenant", args.ocp, args.kustomize
        )
    }
    for env in ("stage", "prod"):
        validate_rpa(
            load(workspace / "admission" / RPA / f"submariner-fbc-{env}.yaml"),
            args.ocp,
            env,
        )
    validate_pipelines(workspace / "fbc", args.ocp, image)
    result["bundles"] = validate_catalog(
        workspace / "fbc", args.ocp, args.min_supported_sub
    )
    result.update(
        local_ready=True,
        deployed="unverified",
        multiarch_build="unverified",
        tested_on_ocp=args.ocp.replace("-", ".") + ": unverified",
    )
    return result


def test_image(root, version, base_image):
    require_tools("make", "podman")
    inspect_base_image(base_image, version)
    with tempfile.TemporaryDirectory(prefix="fbc-image-") as temporary:
        image = "localhost/submariner-fbc-onboarding:" + Path(temporary).name
        try:
            run(
                "make",
                "test-image",
                f"CATALOG=catalog-{version}",
                f"OPM_IMAGE={base_image}",
                f"IMG={image}",
                cwd=root,
                capture=False,
            )
        finally:
            subprocess.run(
                ["podman", "rmi", image],
                stdout=sys.stderr,
                stderr=sys.stderr,
                check=False,
            )
    return {
        "catalog": f"catalog-{version}",
        "base_image": base_image,
        "local_image_test": "passed",
        "multiarch_build": "unverified",
        "runtime": "unverified",
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ocp", type=ocp)
    parser.add_argument(
        "legacy_cutoff",
        nargs="?",
        type=stream,
        help="deprecated exclusive drop-through stream",
    )
    parser.add_argument(
        "--min-supported-sub",
        type=stream,
        help="inclusive first supported stream, e.g. 0.24",
    )
    parser.add_argument(
        "--phase",
        choices=[
            "plan",
            "prepare",
            "prepare-config",
            "prepare-catalog",
            "verify",
            "test-image",
            "verify-live",
        ],
        default="plan",
    )
    parser.add_argument(
        "--release-data-repo",
        type=Path,
        default=Path.home() / "konflux/konflux-release-data",
    )
    parser.add_argument(
        "--fbc-repo", type=Path, default=Path.home() / "konflux/submariner-operator-fbc"
    )
    parser.add_argument(
        "--workspace",
        type=Path,
        help="worktree parent (required outside plan/live mode)",
    )
    parser.add_argument(
        "--base",
        help="compatible shorthand for both repository refs; no implicit fetch",
    )
    parser.add_argument(
        "--release-data-ref", help="release-data ref or SHA (default origin/main)"
    )
    parser.add_argument("--fbc-ref", help="FBC ref or SHA (default origin/main)")
    parser.add_argument(
        "--previous", type=ocp, help="compatible shorthand for both predecessors"
    )
    parser.add_argument("--overlay-previous", type=ocp)
    parser.add_argument("--pipeline-previous", type=ocp)
    parser.add_argument("--base-image", help="operator-registry build image override")
    parser.add_argument(
        "--kustomize",
        type=Path,
        help="Kustomize binary for the selected release-data version",
    )
    parser.add_argument(
        "--expected-commit", help="merged commit required for live verification"
    )
    args = parser.parse_args(argv)
    if args.legacy_cutoff:
        require(
            not args.min_supported_sub,
            "Do not combine the legacy cutoff with --min-supported-sub",
        )
        args.min_supported_sub = f"0.{int(args.legacy_cutoff.split('.')[1]) + 1}"
        print(
            f"WARNING: positional {args.legacy_cutoff} is a drop-through cutoff, NOT a minimum; inclusive minimum is {args.min_supported_sub}",
            file=sys.stderr,
        )
    require(
        not args.min_supported_sub or int(args.min_supported_sub.split(".")[1]) > 0,
        "Inclusive minimum must be above 0.0 for the drop-through map",
    )
    for explicit in (args.release_data_ref, args.fbc_ref):
        require(
            not (args.base and explicit and args.base != explicit),
            "Do not combine conflicting --base and repository refs",
        )
    for explicit in (args.overlay_previous, args.pipeline_previous):
        require(
            not (args.previous and explicit and args.previous != explicit),
            "Do not combine conflicting --previous and predecessor options",
        )
    dotted = args.ocp.replace("-", ".")
    image = (
        args.base_image
        or f"registry.redhat.io/openshift{args.ocp.split('-')[0]}/ose-operator-registry-rhel9:v{dotted}"
    )
    if args.phase == "verify-live":
        if not verify_live(args, image):
            raise ValueError("Live readiness checks failed; see JSON evidence above")
        return
    if args.phase != "plan":
        require(args.workspace, "--workspace is required outside plan mode")
    workspace = args.workspace.expanduser().resolve() if args.workspace else None
    if args.phase == "verify":
        print(json.dumps(verify_workspace(workspace, args, image), indent=2))
        return
    if args.phase == "test-image":
        validate_catalog(workspace / "fbc", args.ocp, args.min_supported_sub)
        print(json.dumps(test_image(workspace / "fbc", args.ocp, image), indent=2))
        return
    sources = {}
    issues = {"configuration": [], "catalog": []}
    configuration = args.phase in ("plan", "prepare", "prepare-config")
    catalog = args.phase in ("plan", "prepare", "prepare-catalog")
    for kind, needed, path, marker, ref, previous in (
        (
            "configuration",
            configuration,
            args.release_data_repo,
            str(OVERLAYS / "base/kustomization.yaml"),
            args.release_data_ref or args.base or "origin/main",
            args.overlay_previous or args.previous,
        ),
        (
            "catalog",
            catalog,
            args.fbc_repo,
            "drop-versions.json",
            args.fbc_ref or args.base or "origin/main",
            args.pipeline_previous or args.previous,
        ),
    ):
        if not needed:
            continue
        try:
            root = repo(path, marker)
            sha = base_commit(root, ref)
            previous = previous or predecessor_at_ref(
                root, args.ocp, sha, pipelines=kind == "catalog"
            )
            require(
                tuple(map(int, previous.split("-")))
                < tuple(map(int, args.ocp.split("-"))),
                "Previous OCP must precede the requested version",
            )
            sources[kind] = {
                "root": str(root),
                "ref": ref,
                "commit": sha,
                "previous": previous,
            }
            if kind == "configuration":
                require_tools("git", "yq")
                sources[kind]["kustomize"] = kustomize_binary(root, args.kustomize, sha)
                names = run(
                    "git",
                    "ls-tree",
                    "--name-only",
                    f"{sha}:{OVERLAYS}/{previous}-overlay",
                    cwd=root,
                ).splitlines()
                require(
                    len([name for name in names if name.endswith(".yaml")]) == 8,
                    "Unexpected predecessor overlay layout",
                )
                for env in ("stage", "prod"):
                    admission = yaml.safe_load(
                        git_text(root, sha, RPA / f"submariner-fbc-{env}.yaml")
                    )
                    app = f"submariner-fbc-{args.ocp}"
                    if app not in admission["spec"]["applications"]:
                        admission["spec"]["applications"].append(app)
                    validate_rpa(admission, args.ocp, env)
            else:
                require_tools("git", "make", "jq", "yq", "podman", "curl", "csplit")
                git_text(root, sha, "test/lib/isolate.sh")
                with tempfile.TemporaryDirectory(prefix="fbc-preflight-") as temporary:
                    stage = Path(temporary)
                    (stage / ".tekton").mkdir()
                    for name in run(
                        "git", "ls-tree", "--name-only", f"{sha}:.tekton", cwd=root
                    ).splitlines():
                        if name.endswith(".yaml"):
                            (stage / ".tekton" / name).write_text(
                                git_text(root, sha, f".tekton/{name}")
                            )
                    pipelines(stage, args.ocp, previous, image)
                template = yaml.safe_load(git_text(root, sha, "catalog-template.yaml"))
                mapping = json.loads(git_text(root, sha, "drop-versions.json"))
                catalog_inputs(template, mapping, args.ocp, args.min_supported_sub)
        except (
            ValueError,
            KeyError,
            TypeError,
            OSError,
            yaml.YAMLError,
            subprocess.CalledProcessError,
        ) as error:
            if args.phase != "plan":
                raise
            issues[kind].append(str(error))
    if args.phase == "plan":
        print(
            json.dumps(
                {
                    "ocp": args.ocp,
                    "minimum_inclusive": args.min_supported_sub,
                    "cutoff_exclusive": f"0.{int(args.min_supported_sub.split('.')[1]) - 1}"
                    if args.min_supported_sub
                    else None,
                    "base_image": image,
                    "sources": sources,
                    "blockers": issues,
                    "previous": sources.get("configuration", {}).get("previous"),
                    "remote_freshness": "not checked; fetch explicitly before preparing",
                    "base_image_availability": "unverified; inspected before catalog preparation",
                    "next_phases": [
                        "prepare (or prepare-config while policy is pending)",
                        "test-image",
                        "review/reconcile configuration and merged push build",
                        "verify-live and actual install/QE",
                    ],
                },
                indent=2,
            )
        )
        return
    prefix = re.sub(r"[^a-zA-Z0-9._-]", "-", workspace.name) + f"-ocp-{args.ocp}"
    targets = []
    if configuration:
        targets += [
            ("configuration", "tenant", "tenant"),
            ("configuration", "admission", "admission"),
        ]
    if catalog:
        inspect_base_image(image, args.ocp)
        targets.append(("catalog", "fbc", "catalog"))
    # Check all existing targets/branches before creating the first worktree.
    for kind, directory, suffix in targets:
        source = sources[kind]
        worktree(
            Path(source["root"]),
            workspace / directory,
            source["commit"],
            prefix + "-" + suffix,
            check_only=True,
        )
    for kind, directory, suffix in targets:
        source = sources[kind]
        worktree(
            Path(source["root"]),
            workspace / directory,
            source["commit"],
            prefix + "-" + suffix,
        )
    if configuration:
        prepare_tenant(
            workspace / "tenant",
            args.ocp,
            sources["configuration"]["previous"],
            sources["configuration"]["kustomize"],
        )
        prepare_rpas(workspace / "admission", args.ocp)
    if catalog:
        prepare_catalog(workspace / "fbc", args, sources["catalog"]["previous"], image)
    result = {
        "ocp": args.ocp,
        "workspace": str(workspace),
        "sources": sources,
        "prepared": [directory for _, directory, _ in targets],
        "deployed": "unverified",
    }
    if args.phase == "prepare":
        result.update(verify_workspace(workspace, args, image))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (
        argparse.ArgumentTypeError,
        ValueError,
        KeyError,
        TypeError,
        yaml.YAMLError,
        StopIteration,
        OSError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
