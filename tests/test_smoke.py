import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SmokeRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copy(ROOT / "scripts/smoke-test.sh", self.root / "scripts")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # 限定 PATH, 不受测试机预装的 qemu/binfmt 影响。
        for cmd in ("bash", "dirname", "grep", "head", "cut", "mktemp", "rm", "ls", "basename", "cat", "chmod"):
            (self.bin / cmd).symlink_to(shutil.which(cmd))
        self.env = dict(os.environ, PATH=str(self.bin), XTOOLS_DIR=str(self.root / "x-tools"), REQUIRE_EXECUTION="1")
        self.write_command("uname", 'if [ "$1" = -s ]; then echo Linux; else echo x86_64; fi')
        self.write_command("riscv64-linux-musl-gcc", '''case "$1" in
  --version) echo "fixture gcc"; exit 0 ;;
  -print-sysroot) echo "/fixture/sysroot with spaces"; exit 0 ;;
esac
while [ "$1" != -o ]; do shift; done
printf '#!/usr/bin/env bash\\necho "hello from C, 3"\\n' > "$2"
chmod +x "$2"
''')
        self.write_command("riscv64-linux-musl-readelf", '''cat <<'EOF'
  Class: ELF64
  Data: 2's complement, little endian
  Machine: RISC-V
  Flags: double-float ABI
EOF
''')
        (self.root / ".config").write_text('CT_ARCH="riscv"\nCT_ARCH_BITNESS=64\nCT_ARCH_ENDIAN="little"\n'
                                         'CT_ARCH_FLOAT="hard"\nCT_ARCH_ABI="lp64d"\n')

    def write_command(self, name, body):
        script = self.bin / name
        script.write_text("#!/usr/bin/env bash\nset -eu\n" + body + "\n")
        script.chmod(0o755)

    def run_smoke(self, *args):
        return subprocess.run([str(self.root / "scripts/smoke-test.sh"), "riscv64-linux-musl", *args],
                              env=self.env, capture_output=True, text=True)

    def test_ci_fails_when_execution_unavailable(self):
        result = self.run_smoke()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FAIL no qemu-user binary", result.stdout)

    def test_optional_execution_still_warns(self):
        self.env["REQUIRE_EXECUTION"] = "0"
        result = self.run_smoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("skipping execution test", result.stdout)

    def test_static_binary_runs_natively_on_matching_linux_cpu(self):
        self.write_command("uname", 'if [ "$1" = -s ]; then echo Linux; else echo riscv64; fi')
        (self.bin / "env").symlink_to(shutil.which("env"))
        result = self.run_smoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("via env: hello from", result.stdout)

    def test_dynamic_binary_requires_qemu_even_on_matching_cpu(self):
        self.write_command("uname", 'if [ "$1" = -s ]; then echo Linux; else echo riscv64; fi')
        result = self.run_smoke("--dynamic")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_dynamic_qemu_gets_target_sysroot(self):
        self.write_command("qemu-riscv64", '[ "$1" = -L ]\n[ "$2" = "/fixture/sysroot with spaces" ]\nshift 2\nexec "$@"')
        result = self.run_smoke("--dynamic")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("via qemu-riscv64: hello from", result.stdout)

    def test_static_qemu_and_runtime_failure(self):
        self.write_command("qemu-riscv64", 'exec "$@"')
        result = self.run_smoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.write_command("qemu-riscv64", 'exit 7')
        result = self.run_smoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exited non-zero", result.stdout)


if __name__ == "__main__":
    unittest.main()
