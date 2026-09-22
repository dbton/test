#!/usr/bin/env bash
# 用法: configure.sh <target> [extra-defconfig-file]
# 把 common/defconfig + targets/<target>/defconfig (+ 额外覆盖文件) 拼接成仓库根目录的 defconfig,
# 运行 ct-ng defconfig, 打印三元组、关键设置���组件版本。
# 在 GitHub Actions 中运行时把 CT_TARGET / TARGET_NAME 写入 $GITHUB_ENV。
set -euo pipefail
cd "$(dirname "$0")/.."

target="${1:?usage: configure.sh <target> [extra-defconfig-file]}"
extra="${2:-}"
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
