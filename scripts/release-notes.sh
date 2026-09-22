#!/usr/bin/env bash
# 用法: release-notes.sh <dist-dir>
# 合并各目标的 notes-*.md 和 *.tar.xz.sha256, 在 dist 目录生成 SHA256SUMS, 把完整发布说明输出到 stdout。
set -euo pipefail
dist="${1:?usage: release-notes.sh <dist-dir>}"

cat "${dist}"/*.tar.xz.sha256 > "${dist}/SHA256SUMS"

echo "Cross toolchains ${GITHUB_REF_NAME:-}, built with crosstool-NG ${CT_NG_VERSION:-} on x86_64 Arch Linux (host binaries link against Arch's glibc)."
echo
echo "Every toolchain passed the smoke test: static C and C++ hello-world programs were compiled, the ELF class, endianness, machine and float ABI were verified with readelf, and the programs were executed under qemu-user where available."
echo "Target-side libraries are built with -Os; host and target binaries are stripped."
echo
for f in "${dist}"/notes-*.md; do
  cat "${f}"
  echo
done
echo "## SHA256"
echo '```'
cat "${dist}/SHA256SUMS"
echo '```'
