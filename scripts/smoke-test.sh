#!/usr/bin/env bash
# 通用冒烟测试。用法: smoke-test.sh <tuple> [--dynamic]
#
# 1. 用新工具链编译一个 C 测试程序 (启用 C++ 时再编译一个 C++ 程序), 默认静态链接;
# 2. 用 readelf 核对 ELF 位宽 / 端序 / 机器类型 / 浮点 ABI 是否与 .config 一致
#    (浮点 ABI 只有 MIPS、32 位 ARM、RISC-V、PowerPC 记录在 ELF 中, 其他架构跳过该项);
# 3. 在 qemu-user 下运行测试程序 (目标与宿主机同架构时直接运行; 没有对应 qemu 时告警并跳过)。
#
# 环境变量: XTOOLS_DIR (默认 /opt/x-tools)
set -euo pipefail
cd "$(dirname "$0")/.."

tuple="${1:?usage: smoke-test.sh <tuple> [--dynamic]}"
link_static=1
[ "${2:-}" = "--dynamic" ] && link_static=0
XTOOLS_DIR="${XTOOLS_DIR:-/opt/x-tools}"

cfg() {
  local v
  v="$( (grep -E "^CT_${1}=" .config || true) | head -n1 | cut -d= -f2-)"
  v="${v#\"}"; v="${v%\"}"
  printf '%s' "${v}"
}
arch="$(cfg ARCH)"            # mips / arm / riscv / x86 / powerpc ... (aarch64 在 ct-ng 里是 arm + 64 位)
bits="$(cfg ARCH_BITNESS)"    # 32 / 64
endian="$(cfg ARCH_ENDIAN)"   # big / little / 空 (架构不可选端序)
float="$(cfg ARCH_FLOAT)"     # soft / hard / softfp / auto / 空
abi="$(cfg ARCH_ABI)"
mipsabi="$(cfg ARCH_mips_ABI)"
cxx="$(cfg CC_LANG_CXX)"
cpu="${tuple%%-*}"            # 三元组首段: mips / mipsel / arm / aarch64 / riscv64 ...

export PATH="${XTOOLS_DIR}/${tuple}/bin:${PATH}"
CC="${tuple}-gcc"; CXX="${tuple}-g++"; READELF="${tuple}-readelf"
command -v "${CC}" >/dev/null || { echo "::error::${CC} not found in PATH"; exit 1; }
"${CC}" --version | head -n1

flags="-Os -s"
[ "${link_static}" = 1 ] && flags="${flags} -static"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

cat > "${work}/hello.c" <<'SRC'
#include <stdio.h>
int main(void) {
    volatile double x = 1.5;
    printf("hello from C, %g\n", x * 2);
    return 0;
}
SRC
# shellcheck disable=SC2086
"${CC}" ${flags} -o "${work}/hello_c" "${work}/hello.c"
bins=("${work}/hello_c")

if [ "${cxx}" = "y" ]; then
  cat > "${work}/hello.cpp" <<'SRC'
#include <iostream>
#include <string>
int main() {
    std::string s = "hello from C++";
    std::cout << s << ", " << 2.5 * 2 << std::endl;
    return 0;
}
SRC
  # shellcheck disable=SC2086
  "${CXX}" ${flags} -o "${work}/hello_cxx" "${work}/hello.cpp"
  bins+=("${work}/hello_cxx")
fi

hdr="$("${READELF}" -h "${work}/hello_c")"
attr="$("${READELF}" -A "${work}/hello_c" 2>/dev/null || true)"
echo "${hdr}" | grep -E 'Class|Data|Machine|Flags'
echo "${attr}" | grep -iE 'FP|float|VFP' || true
ls -l "${bins[@]}"

fail=0
check()     { if grep -qiE "$2" <<<"$3"; then echo "ok   $1"; else echo "FAIL $1 (expected /$2/)"; fail=1; fi; }
check_not() { if grep -qiE "$2" <<<"$3"; then echo "FAIL $1 (unexpected /$2/)"; fail=1; else echo "ok   $1"; fi; }
warn_if_missing() { if grep -qiE "$2" <<<"$3"; then echo "ok   $1"; else echo "::warning::$1: marker /$2/ not found, cannot confirm"; fi; }

# 位宽
if [ -n "${bits}" ]; then check "ELF class is ELF${bits}" "Class:\s+ELF${bits}" "${hdr}"; fi

# 端序
case "${endian}" in
  big)    check "big-endian" "Data:.*big endian" "${hdr}" ;;
  little) check "little-endian" "Data:.*little endian" "${hdr}" ;;
  *)      echo "skip endianness check (not selectable for arch '${arch}')" ;;
esac

# 机器类型
case "${arch}" in
  mips)    machine="MIPS" ;;
  arm)     if [ "${bits}" = 64 ]; then machine="AArch64"; else machine="ARM"; fi ;;
  riscv)   machine="RISC-V" ;;
  powerpc) machine="PowerPC" ;;
  x86)     if [ "${bits}" = 64 ]; then machine="X86-64"; else machine="80386"; fi ;;
  s390)    machine="S/390" ;;
  sh)      machine="SuperH" ;;
  m68k)    machine="68000" ;;
  sparc)   machine="Sparc" ;;
  loongarch) machine="LoongArch" ;;
  xtensa)  machine="Xtensa" ;;
  microblaze) machine="MicroBlaze" ;;
  or1k)    machine="OpenRISC" ;;
  alpha)   machine="Alpha" ;;
  arc)     machine="ARC" ;;
  *)       machine="" ;;
esac
if [ -n "${machine}" ]; then check "machine is ${machine}" "Machine:.*${machine}" "${hdr}"; else echo "skip machine check (unknown arch '${arch}')"; fi

# 浮点 ABI
both="${hdr}"$'\n'"${attr}"
hard_re='hard-float ABI|Hard float|double-float ABI|single-float ABI|VFP registers'
soft_re='soft-float ABI|Soft float'
expect=""
case "${arch}" in
  mips|powerpc) expect="${float}" ;;
  arm)          if [ "${bits}" != 64 ]; then expect="${float}"; fi ;;
  riscv)        case "${abi}" in *d|*f) expect="hard" ;; ilp32|lp64) expect="soft" ;; esac ;;
esac
case "${expect}" in
  soft)   check_not "soft-float: no hard-float ABI markers" "${hard_re}" "${both}"
          warn_if_missing "soft-float marker present" "${soft_re}" "${both}" ;;
  softfp) check_not "softfp: soft-float calling convention" "hard-float ABI|VFP registers" "${both}" ;;
  hard)   check "hard-float ABI" "${hard_re}" "${both}" ;;
  *)      echo "skip float ABI check (arch='${arch}' float='${float:-n/a}' abi='${abi:-n/a}')" ;;
esac

# qemu-user
case "${cpu}" in
  mips)       q=mips ;;
  mipsel)     q=mipsel ;;
  mips64)     if [ "${mipsabi}" = n32 ]; then q=mipsn32; else q=mips64; fi ;;
  mips64el)   if [ "${mipsabi}" = n32 ]; then q=mipsn32el; else q=mips64el; fi ;;
  armeb*)     q=armeb ;;
  arm*)       q=arm ;;
  aarch64_be) q=aarch64_be ;;
  aarch64)    q=aarch64 ;;
  riscv32|riscv64) q="${cpu}" ;;
  powerpc)    q=ppc ;;
  powerpc64)  q=ppc64 ;;
  powerpc64le) q=ppc64le ;;
  x86_64)     q=x86_64 ;;
  i?86)       q=i386 ;;
  s390x|m68k|sh4|sh4eb|sparc|sparc64|or1k|xtensa|microblaze|microblazeel|loongarch64|alpha|hppa) q="${cpu}" ;;
  *)          q="" ;;
esac
runner=""
if [ -n "${q}" ]; then
  for c in "qemu-${q}-static" "qemu-${q}"; do
    if command -v "${c}" >/dev/null; then runner="${c}"; break; fi
  done
fi
if [ -z "${runner}" ] && [ "${cpu}" = "$(uname -m)" ]; then
  runner="env"   # 与宿主机同架构, 直接运行
fi
if [ -z "${runner}" ]; then
  echo "::warning::no qemu-user binary for '${cpu}'; skipping execution test"
else
  for b in "${bins[@]}"; do
    if out="$("${runner}" "${b}" 2>&1)"; then
      echo "run  $(basename "${b}") via ${runner}: ${out}"
      grep -q '^hello from' <<<"${out}" || { echo "FAIL unexpected output from $(basename "${b}")"; fail=1; }
    else
      echo "FAIL $(basename "${b}") exited non-zero via ${runner}: ${out}"; fail=1
    fi
  done
fi

if [ "${fail}" = 0 ]; then
  echo "smoke test passed for ${tuple}"
else
  echo "::error::smoke test failed for ${tuple}"
  exit 1
fi
