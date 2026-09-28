#!/usr/bin/env bash
# 用法: release-notes.sh <dist-dir>
# 合并各 host/target 的 notes-*.md 和 *.tar.xz.sha256, 生成 SHA256SUMS 和完整发布说明。
set -euo pipefail
dist="${1:?usage: release-notes.sh <dist-dir>}"

cat "${dist}"/*.tar.xz.sha256 > "${dist}/SHA256SUMS"

echo "Cross toolchains ${GITHUB_REF_NAME:-}, built with crosstool-NG ${CT_NG_VERSION:-} for multiple Linux hosts."
echo "Choose an asset matching the machine that will run the compiler (host) and the device that will run the compiled programs (target). See each asset's host and build libc below; target musl does not make the compiler itself static."
echo
echo "Every CI toolchain passed the smoke test: static C (and C++ when enabled) hello-world programs were compiled, the ELF class, endianness, machine and applicable float ABI were checked with readelf, and the programs were executed under qemu-user or natively on a matching Linux CPU."
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
