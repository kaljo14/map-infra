"""Exercise the real backup entrypoint with disposable command stubs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "backup/backup.sh"
STUB = r'''
import hashlib, json, os, pathlib, shutil, sys
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
databases = json.loads(os.environ["TEST_DATABASES"])
if command == "psql":
    query = args[-1]
    if "pg_control_system" in query:
        print(json.dumps(dict(version_num=180006, version="18.6", system_identifier="123")))
    elif "rolsuper" in query:
        print("t")
    elif "datallowconn" in query:
        print(json.dumps(databases))
    elif "json_agg(datname)" in query:
        print(json.dumps([db["name"] for db in databases]))
    elif "pg_roles" in query:
        print('["postgres"]')
    elif "pg_extension" in query:
        print('[{"name":"plpgsql","version":"1.0"}]')
    else:
        raise SystemExit("Unexpected SQL: " + query)
elif command == "pg_dump" and args == ["--version"]:
    print("pg_dump (PostgreSQL) 18.6")
elif command in ("pg_dump", "pg_dumpall"):
    dest = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--file="))
    pathlib.Path(dest).write_text(os.environ.get("PGDATABASE", "roles"))
elif command == "pg_restore":
    assert args[0] == "--list"
elif command == "sha256sum":
    print(hashlib.sha256(pathlib.Path(args[0]).read_bytes()).hexdigest(), args[0])
elif command == "restic":
    with open(os.environ["TEST_CALLS"], "a") as log:
        log.write(json.dumps(args) + "\n")
    if "backup" in args:
        shutil.copytree(args[args.index("backup") + 1], os.environ["TEST_EXPORT"])
else:
    raise SystemExit("Unexpected command: " + command)
'''


@unittest.skipUnless(shutil.which("jq"), "jq is required")
class BackupTests(unittest.TestCase):
    def run_backup(self, databases):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        bindir = root / "bin"
        bindir.mkdir()
        for command in ("psql", "pg_dump", "pg_dumpall", "pg_restore", "restic", "sha256sum"):
            stub = bindir / command
            stub.write_text(f"#!{sys.executable}\n" + STUB)
            stub.chmod(0o755)
        env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}",
                   BACKUP_WORK_DIR=str(root / "work"), TEST_DATABASES=json.dumps(databases),
                   TEST_EXPORT=str(root / "export"), TEST_CALLS=str(root / "calls"))
        result = subprocess.run(["bash", str(SCRIPT), "backup"], env=env,
                                capture_output=True, text=True)
        return result, root

    def test_database_oid_json_types_and_names(self):
        # oid is a string in PostgreSQL's JSON output; accept numeric fixtures too.
        for oid_type in (str, int):
            with self.subTest(oid_type=oid_type):
                databases = [dict(oid=oid_type(oid), name=name, connect=True)
                             for oid, name in ((5, "postgres"), (16386, "geopulse"),
                                               (16387, "secondary db"))]
                result, root = self.run_backup(databases)
                self.assertEqual(result.returncode, 0, result.stderr)
                manifest = json.loads((root / "export/manifest.json").read_text())
                self.assertEqual([db["name"] for db in manifest["databases"]],
                                 [db["name"] for db in databases])
                for db in manifest["databases"]:
                    self.assertEqual((root / "export" / db["file"]).read_text(), db["name"])

    def test_empty_database_name_cannot_upload_or_prune(self):
        result, root = self.run_backup([dict(oid="16386", name="", connect=True)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing or ambiguous database", result.stderr)
        self.assertFalse((root / "export").exists())
        calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()]
        self.assertTrue(all("backup" not in call and "forget" not in call for call in calls))


if __name__ == "__main__":
    unittest.main()
