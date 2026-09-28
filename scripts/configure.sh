#!/usr/bin/env bash
# 用法: configure.sh <target> [extra-defconfig-file]
# 把 common/defconfig + targets/<target>/defconfig (+ 额外覆盖文件) 拼接成仓库根目录的 defconfig,
# 运行 ct-ng defconfig, 打印三元组、关键设置和组件版本。
# 在 GitHub Actions 中运行时把 CT_TARGET / TARGET_NAME 写入 $GITHUB_ENV。
set -euo pipefail
cd "$(dirname "$0")/.."

target="${1:?usage: configure.sh <target> [extra-defconfig-file]}"
extra="${2:-}"
[[ "${target}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "::error::invalid target name '${target}'" >&2; exit 1; }
[ -f "targets/${target}/defconfig" ] || { echo "::error::unknown target '${target}' (no targets/${target}/defconfig)"; exit 1; }

{
  echo "# 由 scripts/configure.sh 生成: common/defconfig + targets/${target}/defconfig"
  cat common/defconfig
  echo
  echo "# ---- targets/${target}/defconfig ----"
  cat "targets/${target}/defconfig"
  if [ -n "${extra}" ] && [ -s "${extra}" ] && grep -q '[^[:space:]]' "${extra}"; then
    echo
    echo "# ---- extra overrides (${extra}) ----"
    cat "${extra}"
  fi
} > defconfig

ct-ng defconfig 2>&1 | tee defconfig.log
if grep -q 'warning: override' defconfig.log; then
  echo "note: 'override' warnings above mean a later line replaced an earlier one; expected when extra overrides are given"
fi

# 多 host CI 在对应 runner 上原生构建, 不使用 Canadian cross。
if [ -n "${HOST_NAME:-}" ]; then
  python3 scripts/hosts.py check "${HOST_NAME}"
  grep -qx 'CT_TOOLCHAIN_TYPE="cross"' .config || { echo "::error::HOST_NAME requires CT_CROSS=y" >&2; exit 1; }
fi

if ! tuple_out="$(ct-ng show-tuple 2>&1)"; then
  printf '%s\n' "${tuple_out}"
  echo "::error::ct-ng show-tuple failed for target '${target}' (see the [ERROR] lines above)"
  exit 1
fi
CT_TARGET="$(printf '%s\n' "${tuple_out}" | tail -n1)"
echo "Target name : ${target}"
echo "Target tuple: ${CT_TARGET}"
echo "Key settings:"
grep -E '^CT_(ARCH|ARCH_BITNESS|ARCH_ENDIAN|ARCH_FLOAT|ARCH_ARCH|ARCH_CPU|ARCH_TUNE|ARCH_FPU|ARCH_ABI|ARCH_mips_ABI|LIBC|KERNEL|TARGET_CFLAGS|CC_LANG_CXX)=' .config | sort
echo "Component versions:"
grep -E '^CT_[A-Z0-9_]+_VERSION="' .config | grep -v '^CT_CONFIG_VERSION=' | sort

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "CT_TARGET=${CT_TARGET}"
    echo "TARGET_NAME=${target}"
  } >> "${GITHUB_ENV}"
fi
