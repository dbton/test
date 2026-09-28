#!/usr/bin/env bash
# 构建失败时打印定位信息: build.log 中所有 [ERROR] 行、第一处 [ERROR] 之前的上下文、最近一次 configure 的 config.log 错误行。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

if [ ! -f build.log ]; then
  echo "::error::no build.log was produced; the failure is in an earlier step, check its output"
  exit 0
fi
echo "::group::All [ERROR] lines in build.log"
grep -n '\[ERROR\]' build.log | head -60 || true
echo "::endgroup::"

# ct-ng 在 build.log 末尾追加 [ERROR] 摘要; 真正的编译/配置错误在第一处 [ERROR] 之前的几百行里
n="$(grep -n -m1 '\[ERROR\]' build.log | cut -d: -f1 || true)"
if [ -n "${n}" ]; then
  start=$(( n > 300 ? n - 300 : 1 ))
  end=$(( n + 60 ))
  echo "::group::build.log lines ${start}-${end} (context before the first [ERROR])"
  sed -n "${start},${end}p" build.log
  echo "::endgroup::"
  echo "::error::ct-ng build failed, see the 'context before the first [ERROR]' group above; full log in the build-log artifact"
else
  echo "::group::Last 200 lines of build.log"
  tail -n 200 build.log
  echo "::endgroup::"
fi

# configure 阶段失败时 (如 "could not find a working compiler"), 真正原因只在 config.log 里
latest="$(find .build -name config.log -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
if [ -n "${latest}" ]; then
  echo "::group::Most recently written config.log: ${latest} (error lines)"
  grep -n -E 'error:|Error [0-9]|undefined reference|cannot find|not found' "${latest}" | head -40 || true
  echo "::endgroup::"
fi
