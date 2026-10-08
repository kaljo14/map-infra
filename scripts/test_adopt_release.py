import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("adopt_release", Path(__file__).with_name("adopt-release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class AdoptReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.path = self.root / "apps/frontend/deployment.yaml"
        self.path.parent.mkdir(parents=True)
        self.original = "    image: kaljo14/my-map:latest@sha256:" + "a" * 64 + "\n    name: frontend\n"
        self.path.write_text(self.original)
        self.manifest = {
            "digest": "sha256:" + "b" * 64,
            "manifests": [{"platform": {"os": "linux", "architecture": arch}}
                          for arch in ("amd64", "arm64")],
        }

    def test_adopts_verified_version_and_index_digest(self):
        with patch.object(release.subprocess, "check_output", return_value=json.dumps(self.manifest)) as inspect:
            result = release.adopt_release("frontend", "1.2.3", self.root)
        self.assertEqual(result, "kaljo14/my-map:1.2.3@sha256:" + "b" * 64)
        self.assertIn("kaljo14/my-map:1.2.3", inspect.call_args.args[0])
        self.assertEqual(self.path.read_text(), f"    image: {result}\n    name: frontend\n")

    def test_invalid_versions_never_query_registry(self):
        for version in ("latest", "v1.2.3", "01.2.3", "1.2", "1.2.3-rc.1", "1.2.3+build"):
            with self.subTest(version=version), patch.object(release.subprocess, "check_output") as inspect:
                with self.assertRaises(ValueError):
                    release.adopt_release("frontend", version, self.root)
                inspect.assert_not_called()

    def test_failed_registry_lookup_leaves_manifest_unchanged(self):
        with patch.object(release.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, "docker")):
            with self.assertRaises(subprocess.CalledProcessError):
                release.adopt_release("frontend", "1.2.3", self.root)
        self.assertEqual(self.path.read_text(), self.original)

    def test_invalid_digest_or_missing_architecture_leaves_manifest_unchanged(self):
        for manifest in ({**self.manifest, "digest": "invalid"},
                         {**self.manifest, "manifests": self.manifest["manifests"][:1]}):
            with self.subTest(manifest=manifest), patch.object(release.subprocess, "check_output", return_value=json.dumps(manifest)):
                with self.assertRaises(ValueError):
                    release.adopt_release("frontend", "1.2.3", self.root)
                self.assertEqual(self.path.read_text(), self.original)


if __name__ == "__main__":
    unittest.main()
