#!/usr/bin/env bash
# 用法: package.sh <target-name> <tuple>
# 把 /opt/x-tools/<tuple> 打包为 dist/<name>-toolchain-x86_64-archlinux[-<tag>].tar.xz,
# 生成同名 .sha256 和发布说明片段 dist/notes-<name>.md; 在 GitHub Actions 中把 OUT 写入 $GITHUB_ENV。
# 环境变量: XTOOLS_DIR (默认 /opt/x-tools)
set -euo pipefail
cd "$(dirname "$0")/.."

name="${1:?usage: package.sh <target-name> <tuple>}"
tuple="${2:?usage: package.sh <target-name> <tuple>}"
XTOOLS_DIR="${XTOOLS_DIR:-/opt/x-tools}"
[ -d "${XTOOLS_DIR}/${tuple}" ] || { echo "::error::${XTOOLS_DIR}/${tuple} does not exist"; exit 1; }

out="${name}-toolchain-x86_64-archlinux"
case "${GITHUB_REF:-}" in refs/tags/v*) out="${out}-${GITHUB_REF_NAME}" ;; esac

mkdir -p dist
tar -C "${XTOOLS_DIR}" -cJf "$(pwd)/dist/${out}.tar.xz" "${tuple}"
( cd dist && sha256sum "${out}.tar.xz" > "${out}.tar.xz.sha256" )
ls -lh "dist/${out}.tar.xz"

cfg() {
  local v
  v="$( (grep -E "^CT_${1}=" .config || true) | head -n1 | cut -d= -f2-)"
  v="${v#\"}"; v="${v%\"}"
  printf '%s' "${v}"
}
ver() { cfg "${1}_VERSION"; }
arch="$(cfg ARCH)"; bits="$(cfg ARCH_BITNESS)"; endian="$(cfg ARCH_ENDIAN)"; float="$(cfg ARCH_FLOAT)"
march="$(cfg ARCH_ARCH)"; mcpu="$(cfg ARCH_CPU)"; mtune="$(cfg ARCH_TUNE)"; fpu="$(cfg ARCH_FPU)"
abi="$(cfg ARCH_ABI)"
if [ -z "${abi}" ] && [ "${arch}" = mips ]; then
  case "$(cfg ARCH_mips_ABI)" in 32) abi="o32" ;; n32) abi="n32" ;; 64) abi="n64" ;; esac
fi
if [ "${arch}" = arm ] && [ "${bits}" = 64 ]; then archname="aarch64"; else archname="${arch}"; fi
libc="$(cfg LIBC)"
libc_ver="$(ver "$(printf '%s' "${libc}" | tr 'a-z-' 'A-Z_')")"
if [ "$(cfg CC_LANG_CXX)" = y ]; then langs="C, C++"; else langs="C"; fi

desc="${archname} ${bits}-bit"
[ -n "${endian}" ] && desc="${desc}, ${endian}-endian"
[ -n "${march}" ]  && desc="${desc}, -march=${march}"
[ -n "${mcpu}" ]   && desc="${desc}, -mcpu=${mcpu}"
[ -n "${mtune}" ]  && desc="${desc}, -mtune=${mtune}"
[ -n "${fpu}" ]    && desc="${desc}, -mfpu=${fpu}"
[ -n "${float}" ]  && desc="${desc}, float: ${float}"
[ -n "${abi}" ]    && desc="${desc}, ABI: ${abi}"

{
  echo "## ${name}"
  echo
  echo "| Item | Value |"
  echo "|---|---|"
  echo "| Tuple | \`${tuple}\` |"
  echo "| Target | ${desc} |"
  echo "| C library | ${libc} ${libc_ver} |"
  echo "| GCC | $(ver GCC) (${langs}) |"
  echo "| binutils | $(ver BINUTILS) |"
  echo "| Linux headers | $(ver LINUX) |"
  echo "| Asset | \`${out}.tar.xz\` |"
  echo "| Install | \`sudo tar -C /opt -xJf ${out}.tar.xz\` then \`export PATH=/opt/${tuple}/bin:\$PATH\` |"
  echo
  echo "<details><summary>All component versions</summary>"
  echo
  echo '```'
  grep -E '^CT_[A-Z0-9_]+_VERSION="' .config | grep -v '^CT_CONFIG_VERSION=' | sort
  echo '```'
  echo "</details>"
} > "dist/notes-${name}.md"
cat "dist/notes-${name}.md"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "OUT=${out}" >> "${GITHUB_ENV}"
fi
