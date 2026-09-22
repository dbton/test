#!/usr/bin/env bash
# 用法: list-targets.sh [all | name1,name2,...]
# 输出 JSON 数组形式的目标名列表 (targets/ 下的目录名), 供 GitHub Actions 矩阵使用。
set -euo pipefail
cd "$(dirname "$0")/.."

sel="${1:-all}"
names=()
if [ -z "${sel}" ] || [ "${sel}" = "all" ]; then
  for d in targets/*/defconfig; do
    names+=("$(basename "$(dirname "${d}")")")
  done
else
  IFS=',' read -r -a parts <<<"${sel}"
  for p in "${parts[@]}"; do
    p="$(printf '%s' "${p}" | tr -d '[:space:]')"
    [ -n "${p}" ] || continue
    [ -f "targets/${p}/defconfig" ] || { echo "::error::unknown target '${p}' (no targets/${p}/defconfig)" >&2; exit 1; }
    names+=("${p}")
  done
fi
[ "${#names[@]}" -gt 0 ] || { echo "::error::no targets selected" >&2; exit 1; }

json="["
sep=""
for n in "${names[@]}"; do
  [[ "${n}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "::error::invalid target name '${n}'" >&2; exit 1; }
  json+="${sep}\"${n}\""
  sep=","
done
echo "${json}]"
