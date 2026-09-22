#!/usr/bin/env bash
# 预先从可靠镜像下载源码包并校验 ct-ng 自带的 SHA256, 放入 tarballs/; ct-ng 发现本地已有就不再联网。
# 目前只处理 musl (官方站点从 CI 网络经常超时), 其他包由 ct-ng 自己下载。
# 环境变量: CT_PACKAGES_DIR (默认根据 ct-ng 的安装位置推导)
set -euo pipefail
cd "$(dirname "$0")/.."

PKGS="${CT_PACKAGES_DIR:-$(dirname "$(dirname "$(command -v ct-ng)")")/share/crosstool-ng/packages}"
[ -d "${PKGS}" ] || { echo "::error::crosstool-NG packages dir not found: ${PKGS}"; exit 1; }
mkdir -p tarballs

# fetch <file> <sha256> <url>... : 依次尝试各 URL, 校验通过即停止
fetch() {
  local file="$1" sum="$2" url
  shift 2
  if [ -f "tarballs/${file}" ] && echo "${sum}  tarballs/${file}" | sha256sum -c --status; then
    echo "cached: ${file}"
    return 0
  fi
  for url in "$@"; do
    echo "trying ${url}"
    if curl -fsSL --retry 3 --connect-timeout 30 -o "tarballs/${file}.tmp" "${url}" \
       && echo "${sum}  tarballs/${file}.tmp" | sha256sum -c --status; then
      mv "tarballs/${file}.tmp" "tarballs/${file}"
      echo "got: ${file}"
      return 0
    fi
    rm -f "tarballs/${file}.tmp"
  done
  echo "::error::failed to fetch ${file} from all mirrors"
  return 1
}

MUSL_VER="$(sed -n 's/^CT_MUSL_VERSION="\(.*\)"/\1/p' .config)"
if [ -z "${MUSL_VER}" ]; then
  echo "this target does not use musl; nothing to prefetch"
  exit 0
fi
MUSL_SUM="$(awk -v f="musl-${MUSL_VER}.tar.gz" '$1=="sha256" && $2==f {print $3}' "${PKGS}/musl/${MUSL_VER}/chksum")"
[ -n "${MUSL_SUM}" ] || { echo "::error::no sha256 for musl-${MUSL_VER} in ${PKGS}/musl"; exit 1; }
fetch "musl-${MUSL_VER}.tar.gz" "${MUSL_SUM}" \
  "https://musl.libc.org/releases/musl-${MUSL_VER}.tar.gz" \
  "https://sources.buildroot.net/musl/musl-${MUSL_VER}.tar.gz" \
  "https://sources.openwrt.org/musl-${MUSL_VER}.tar.gz"
ls -l tarballs
