import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("hosts", ROOT / "scripts/hosts.py")
hosts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hosts)


class HostTests(unittest.TestCase):
    def setUp(self):
        self.registry = hosts.load_hosts()

    def test_all_and_default_hosts(self):
        for selection in ("", "all", " all "):
            self.assertEqual(len(hosts.select_hosts(self.registry, selection)), 2)

    def test_selection_order_whitespace_and_duplicates(self):
        selected = hosts.select_hosts(self.registry, " aarch64-ubuntu22.04, x86_64-archlinux,aarch64-ubuntu22.04, ")
        self.assertEqual([h["name"] for h in selected], ["aarch64-ubuntu22.04", "x86_64-archlinux"])

    def test_empty_and_unknown_selection_fail(self):
        for selection in (", ,", "missing", "../common", 'bad"name'):
            with self.subTest(selection=selection), self.assertRaises(ValueError):
                hosts.select_hosts(self.registry, selection)

    def test_runner_and_container_architecture(self):
        selected = hosts.select_hosts(self.registry, "all")
        for host in selected:
            self.assertEqual(host["runner"].endswith("-arm"), host["arch"] == "aarch64")
            if host["os_id"] == "ubuntu":
                self.assertEqual(host["container"], "ubuntu:" + host["version_id"])

    def test_detect_and_validate_every_profile(self):
        for name, host in self.registry.items():
            actual = host["arch"], host["os_id"], host["version_id"]
            self.assertEqual(hosts.check_host(self.registry, name, actual), (name, host["label"]))
            self.assertEqual(hosts.check_host(self.registry, "", actual)[0], name)

    def test_wrong_cpu_distribution_or_version_cannot_label_artifact(self):
        for actual in (("x86_64", "ubuntu", "22.04"), ("aarch64", "debian", "12"),
                       ("aarch64", "ubuntu", "24.04")):
            with self.subTest(actual=actual), self.assertRaisesRegex(ValueError, "does not match"):
                hosts.check_host(self.registry, "aarch64-ubuntu22.04", actual)
        with self.assertRaisesRegex(ValueError, "unsupported host"):
            hosts.check_host(self.registry, "", ("riscv64", "ubuntu", "22.04"))

    def test_os_and_cpu_detection(self):
        with patch.object(hosts.platform, "system", return_value="Linux"), \
                patch.object(hosts.platform, "machine", return_value="arm64"), \
                patch.object(hosts.platform, "freedesktop_os_release", return_value={"ID": "ubuntu", "VERSION_ID": "22.04"}):
            self.assertEqual(hosts.current_host(), ("aarch64", "ubuntu", "22.04"))
        with patch.object(hosts.platform, "system", return_value="Darwin"), self.assertRaisesRegex(ValueError, "only Linux"):
            hosts.current_host()

    def test_invalid_registry_reports_error(self):
        with patch.object(hosts.REGISTRY.__class__, "read_text", return_value='{"bad/name": {}}'), \
                self.assertRaisesRegex(ValueError, "invalid host name"):
            hosts.load_hosts()

    def test_cli_errors_go_to_stderr(self):
        out, err = io.StringIO(), io.StringIO()
        with patch("sys.argv", ["hosts.py", "list", "missing"]), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(hosts.main(), 1)
        self.assertEqual(out.getvalue(), "")
        self.assertIn("unknown host", err.getvalue())

    def test_target_duplicates_do_not_duplicate_matrix_jobs(self):
        result = subprocess.run([str(ROOT / "scripts/list-targets.sh"), "mips-linux-musl, mips-linux-musl,aarch64-linux-musl"],
                                check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(result.stdout), ["mips-linux-musl", "aarch64-linux-musl"])


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / "scripts", self.root / "scripts")
        arch, os_id, version_id = hosts.current_host()
        profile = dict(runner="test", container="test", package_manager="apt", arch=arch,
                       os_id=os_id, version_id=version_id, label="Test host")
        # 两个原生 fixture host, 用真实 tar/sha256 验证同一 target 合并时不丢产物。
        (self.root / "hosts.json").write_text(json.dumps({"host-a": profile, "host-b": profile,
                                                        "wrong-host": dict(profile, arch="wrong-arch")}))
        self.tuple = "aarch64-linux-musl"
        self.xtools = self.root / "x-tools"
        binary = self.xtools / self.tuple / "bin" / (self.tuple + "-gcc")
        binary.parent.mkdir(parents=True)
        binary.write_text("fixture compiler\n")
        (self.root / ".config").write_text('CT_TOOLCHAIN_TYPE="cross"\nCT_ARCH="arm"\nCT_ARCH_BITNESS=64\n'
                                         'CT_ARCH_ENDIAN="little"\nCT_LIBC="musl"\nCT_MUSL_VERSION="1.2.6"\n'
                                         'CT_GCC_VERSION="16.2.0"\nCT_BINUTILS_VERSION="2.47"\nCT_LINUX_VERSION="6.12"\n')
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GITHUB_") and k != "HOST_NAME"}
        self.env.update(XTOOLS_DIR=str(self.xtools), CT_NG_VERSION="1.29.0", XZ_OPT="-0")

    def run_script(self, script, *args, check=True):
        return subprocess.run([str(self.root / "scripts" / script), *args], cwd=self.root,
                              env=self.env, check=check, capture_output=True, text=True)

    def test_multiple_hosts_survive_release_merge_with_checksums(self):
        self.env.update(GITHUB_REF="refs/tags/v2.0.0", GITHUB_REF_NAME="v2.0.0", GITHUB_ENV=str(self.root / "env"))
        for host in ("host-a", "host-b"):
            self.run_script("package.sh", self.tuple, self.tuple, host)
        dist = self.root / "dist"
        self.assertEqual(len(list(dist.glob("notes-*.md"))), 2)
        notes = self.run_script("release-notes.sh", str(dist)).stdout
        self.assertIn("multiple Linux hosts", notes)
        for host in ("host-a", "host-b"):
            name = f"{self.tuple}-toolchain-{host}-v2.0.0.tar.xz"
            self.assertIn(f"## {self.tuple} / {host}", notes)
            self.assertIn(name, notes)
            with tarfile.open(dist / name) as archive:
                self.assertIn(f"{self.tuple}/bin/{self.tuple}-gcc", archive.getnames())
        sums = (dist / "SHA256SUMS").read_text().splitlines()
        self.assertEqual(len(sums), 2)
        for entry in sums:
            digest, filename = entry.split()
            self.assertEqual(digest, hashlib.sha256((dist / filename).read_bytes()).hexdigest())
        self.assertEqual(len((self.root / "env").read_text().splitlines()), 2)

    def test_default_detection_and_environment_host(self):
        self.run_script("package.sh", self.tuple, self.tuple)
        self.assertTrue((self.root / "dist" / f"{self.tuple}-toolchain-host-a.tar.xz").exists())
        self.env["HOST_NAME"] = "host-b"
        self.run_script("package.sh", self.tuple, self.tuple)
        self.assertTrue((self.root / "dist" / f"{self.tuple}-toolchain-host-b.tar.xz").exists())

    def test_wrong_host_and_canadian_cross_fail_before_packaging(self):
        result = self.run_script("package.sh", self.tuple, self.tuple, "wrong-host", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)
        (self.root / ".config").write_text('CT_TOOLCHAIN_TYPE="canadian"\n')
        result = self.run_script("package.sh", self.tuple, self.tuple, "host-a", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CT_CROSS", result.stderr)
        self.assertFalse((self.root / "dist").exists())


if __name__ == "__main__":
    unittest.main()
