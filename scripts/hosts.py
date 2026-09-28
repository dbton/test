#!/usr/bin/env python3
"""Host 注册表: list [all|host,...] 输出矩阵; check [host] 校验实际构建环境。"""

import argparse
import json
import platform
import re
import sys
from pathlib import Path

REGISTRY = Path(__file__).resolve().parent.parent / "hosts.json"


def load_hosts():
    hosts = json.loads(REGISTRY.read_text())
    if not hosts:
        raise ValueError("no hosts configured")
    for name, host in hosts.items():
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
            raise ValueError(f"invalid host name '{name}'")
        for key in ("runner", "container", "package_manager", "arch", "os_id", "version_id", "label"):
            if not isinstance(host.get(key), str) or any(c in host[key] for c in "\n\r\t"):
                raise ValueError(f"invalid {key} for host '{name}'")
            if key != "version_id" and not host[key]:
                raise ValueError(f"empty {key} for host '{name}'")
        if host["package_manager"] not in ("apt", "pacman"):
            raise ValueError(f"unsupported package manager for host '{name}'")
    return hosts


def select_hosts(hosts, selection):
    selection = selection.strip()
    names = list(hosts) if selection in ("", "all") else list(
        dict.fromkeys(name.strip() for name in selection.split(",") if name.strip())
    )
    if not names:
        raise ValueError("no hosts selected")
    for name in names:
        if name not in hosts:
            raise ValueError(f"unknown host '{name}' (available: {', '.join(hosts)})")
    return [dict(name=name, **hosts[name]) for name in names]


def current_host():
    if platform.system() != "Linux":
        raise ValueError("only Linux build/host environments are currently supported")
    arch = platform.machine()
    arch = {"arm64": "aarch64", "amd64": "x86_64"}.get(arch.lower(), arch)
    release = platform.freedesktop_os_release()
    return arch, release.get("ID", ""), release.get("VERSION_ID", "")


def check_host(hosts, name, actual):
    arch, os_id, version_id = actual
    if name and name not in hosts:
        raise ValueError(f"unknown host '{name}' (available: {', '.join(hosts)})")
    candidates = [name] if name else list(hosts)
    for candidate in candidates:
        host = hosts[candidate]
        if (host["arch"] == arch and host["os_id"] == os_id
                and (not host["version_id"] or host["version_id"] == version_id)):
            return candidate, host["label"]
    detected = f"{arch} {os_id} {version_id}".strip()
    if name:
        raise ValueError(f"host '{name}' does not match running environment ({detected}); "
                         "use its matching native runner/container")
    raise ValueError(f"unsupported host environment ({detected}); add a profile to hosts.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("list", "check"))
    parser.add_argument("selection", nargs="?", default="")
    args = parser.parse_args()
    try:
        hosts = load_hosts()
        if args.command == "list":
            print(json.dumps(select_hosts(hosts, args.selection), separators=(",", ":")))
        else:
            print("\t".join(check_host(hosts, args.selection, current_host())))
    except (ValueError, OSError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
