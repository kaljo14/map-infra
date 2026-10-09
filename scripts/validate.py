#!/usr/bin/env python3
"""Build the Flux graph offline and reject missing or multiply owned workloads."""
from pathlib import Path
import subprocess

import jsonschema
import yaml

ROOT = Path(__file__).resolve().parents[1]


def documents(text):
    return [doc for doc in yaml.safe_load_all(text) if doc]


def build(path):
    return documents(subprocess.check_output(
        ["kubectl", "kustomize", str(path)], cwd=ROOT, text=True
    ))


def identity(doc):
    meta = doc["metadata"]
    return (doc["apiVersion"], doc["kind"], meta.get("namespace", ""), meta["name"])


def main():
    # Parse even excluded examples, so malformed YAML cannot hide outside a bundle.
    for parent in ("apps", "infrastructure", "clusters", "operations", ".github/workflows"):
        for path in (ROOT / parent).rglob("*.yaml"):
            documents(path.read_text())

    cluster = build(ROOT / "clusters/production")
    schemas = {}
    for doc in cluster:
        if doc["kind"] == "CustomResourceDefinition":
            spec = doc["spec"]
            for version in spec["versions"]:
                schemas[(spec["group"] + "/" + version["name"], spec["names"]["kind"])] = (
                    version["schema"]["openAPIV3Schema"]
                )
    for doc in cluster:
        key = (doc["apiVersion"], doc["kind"])
        if key in schemas:
            jsonschema.Draft7Validator(schemas[key]).validate(doc)

    bundles = documents((ROOT / "clusters/production/workloads.yaml").read_text())
    by_name = {doc["metadata"]["name"]: doc for doc in bundles}
    visited, visiting = set(), set()

    def visit(name):
        assert name in by_name, f"Unknown dependency: {name}"
        assert name not in visiting, f"Dependency cycle: {name}"
        if name in visited:
            return
        visiting.add(name)
        for dependency in by_name[name]["spec"].get("dependsOn", []):
            visit(dependency["name"])
        visiting.remove(name)
        visited.add(name)

    owners = {}
    for name, bundle in by_name.items():
        visit(name)
        path = ROOT / bundle["spec"]["path"]
        # Use Flux's own build pipeline as well as the root Kustomize preview.
        rendered = documents(subprocess.check_output([
            "flux", "build", "kustomization", name, "--dry-run",
            "--path", str(path), "--kustomization-file",
            str(ROOT / "clusters/production/workloads.yaml"),
        ], cwd=ROOT, text=True))
        for doc in rendered:
            key = identity(doc)
            assert key not in owners, f"Multiple Flux owners for {key}"
            owners[key] = name

    workloads = build(ROOT)
    keys = [identity(doc) for doc in workloads]
    assert len(keys) == len(set(keys)), "Duplicate workload identities"
    assert set(keys) == set(owners), "Root preview and Flux resource coverage differ"
    namespaces = {doc["metadata"]["name"] for doc in workloads if doc["kind"] == "Namespace"}
    for doc in workloads:
        kind, meta = doc["kind"], doc["metadata"]
        schema = schemas.get((doc["apiVersion"], kind))
        if schema:
            jsonschema.Draft7Validator(schema).validate(doc)
        assert kind != "Secret", "Plaintext Secret included in reconciliation"
        if kind not in ("Namespace", "ClusterRole", "ClusterRoleBinding"):
            assert meta.get("namespace") in namespaces, f"Missing namespace: {identity(doc)}"
        if kind in ("Namespace", "PersistentVolumeClaim"):
            assert meta.get("annotations", {}).get("kustomize.toolkit.fluxcd.io/prune") == "disabled", (
                f"Unprotected persistent resource: {identity(doc)}"
            )
        if kind == "HelmRelease" and meta["name"] == "postgres":
            spec = doc["spec"]
            assert spec["releaseName"] == "postgres"
            assert spec["targetNamespace"] == spec["storageNamespace"] == "database"
            assert spec["values"]["image"]["digest"].startswith("sha256:")
            assert meta["annotations"]["kustomize.toolkit.fluxcd.io/prune"] == "disabled"
            assert spec["upgrade"]["remediation"]["retries"] == 0
            if not spec.get("suspend", False):
                assert meta["annotations"].get("database.lonctus.com/postgis-image-verified") == "true", (
                    "Test the permanent PostGIS image before enabling PostgreSQL reconciliation"
                )
                assert spec["values"]["image"]["repository"] != "bitnami/postgresql", (
                    "The original Bitnami image does not contain the manually installed PostGIS"
                )
        if kind == "CronJob" and meta["name"] == "postgres-backup":
            spec = doc["spec"]
            image = spec["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["image"]
            assert spec["suspend"] or "adoption-required" not in image, "Publish backup image before enabling"
    print(f"Validated {len(bundles)} Flux bundles and {len(workloads)} workloads; "
          "schemas, dependencies, namespaces, ownership and storage protection passed.")


if __name__ == "__main__":
    main()
