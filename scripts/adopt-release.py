#!/usr/bin/env python3
"""Select a published semantic image and its verified multi-platform digest."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
APPLICATIONS = {
    "frontend": ("kaljo14/my-map", "apps/frontend/deployment.yaml"),
    "docs": ("kaljo14/docs", "apps/docs/deployment.yaml"),
    "places-scraper": ("kaljo14/places-scraper", "apps/places-scraper/deployment.yaml"),
}
VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def adopt_release(application, version, root=ROOT):
    if not re.fullmatch(VERSION, version):
        raise ValueError("Use a stable image version without v, for example 1.2.3")
    image, filename = APPLICATIONS[application]
    reference = f"{image}:{version}"
    manifest = json.loads(subprocess.check_output([
        "docker", "buildx", "imagetools", "inspect", reference,
        "--format", "{{json .Manifest}}",
    ], text=True))
    digest = manifest.get("digest", "")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("Registry did not return a valid image-index digest")
    platforms = {
        (item.get("platform", {}).get("os"), item.get("platform", {}).get("architecture"))
        for item in manifest.get("manifests", [])
    }
    if not {("linux", "amd64"), ("linux", "arm64")} <= platforms:
        raise ValueError("Release must contain both linux/amd64 and linux/arm64 images")
    path = root / filename
    original = path.read_text()
    replacement = f"{reference}@{digest}"
    updated, count = re.subn(
        rf"(?m)^(\s*image:\s*){re.escape(image)}:[^\s]+(\s*)$",
        lambda match: match[1] + replacement + match[2], original,
    )
    if count != 1:
        raise ValueError(f"Expected exactly one {image} image in {filename}")
    path.write_text(updated)
    return replacement


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("application", choices=APPLICATIONS)
    parser.add_argument("version", help="Published image version, e.g. 1.2.3 (without v)")
    args = parser.parse_args()
    try:
        selected = adopt_release(args.application, args.version)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release adoption failed: {error}\n")
    print(f"Selected {selected}. Review the manifest diff and merge it through a PR.")


if __name__ == "__main__":
    main()
