#!/usr/bin/env python3
"""Patch sabnzbd.ini for host-run Odin fork (absolute paths, port, [odin])."""

from __future__ import annotations

import re
import sys
from pathlib import Path

import configobj


def odin_api_key_from_yaml(odin_cfg: Path) -> str:
    if not odin_cfg.is_file():
        return ""
    in_rest = False
    for line in odin_cfg.read_text(encoding="utf-8").splitlines():
        if re.match(r"^rest:\s*$", line):
            in_rest = True
            continue
        if in_rest:
            if re.match(r"^[a-z_]+:\s*", line) and not re.match(r"^\s", line):
                break
            m = re.match(r"\s*api_key:\s*(.+)", line)
            if m:
                return m.group(1).strip().strip('"').strip("'")
    return ""


def patch_ini(
    source: Path,
    dest: Path,
    *,
    port: str,
    config_root: Path,
    odin_root: Path,
    preserve_odin: bool = True,
) -> None:
    cfg = configobj.ConfigObj(infile=str(source), default_encoding="utf-8", encoding="utf-8")
    misc = cfg.setdefault("misc", {})

    misc["port"] = port
    misc["auto_browser"] = "0"
    misc["download_dir"] = "/pool/downloads/sabnzbd/incomplete"
    misc["complete_dir"] = "/pool/downloads/sabnzbd/completed"
    misc["script_dir"] = str(config_root / "scripts")
    misc["admin_dir"] = str(config_root / "admin")
    misc["log_dir"] = str(config_root / "logs")

    odin = None
    if preserve_odin and dest.exists():
        old = configobj.ConfigObj(infile=str(dest), default_encoding="utf-8", encoding="utf-8")
        odin = old.get("odin")
    if odin is None and preserve_odin:
        odin = cfg.get("odin")
    api_key = odin_api_key_from_yaml(odin_root / "config.yaml")
    if odin is None:
        odin = {
            "odin_enable": "1",
            "odin_url": "http://127.0.0.1:8688/api/v1/webhook/sabnzbd",
            "odin_api_key": api_key,
        }
    elif api_key:
        odin = dict(odin)
        odin["odin_api_key"] = api_key

    cfg["odin"] = odin
    dest.parent.mkdir(parents=True, exist_ok=True)
    cfg.filename = str(dest)
    cfg.write()


def main() -> int:
    if len(sys.argv) < 4:
        print(
            "usage: patch-sabnzbd-ini.py <source.ini> <dest.ini> <port> " "[config_root] [odin_repo_root]",
            file=sys.stderr,
        )
        return 2

    source = Path(sys.argv[1])
    dest = Path(sys.argv[2])
    port = sys.argv[3]
    config_root = Path(sys.argv[4]) if len(sys.argv) > 4 else dest.parent
    odin_root = Path(sys.argv[5]) if len(sys.argv) > 5 else Path(__file__).resolve().parents[2] / "odin"

    patch_ini(source, dest, port=port, config_root=config_root, odin_root=odin_root)
    print(f"Wrote {dest}")
    print(f"  port={port}")
    print(f"  odin_enable={cfg_get_odin_enable(dest)}")
    return 0


def cfg_get_odin_enable(path: Path) -> str:
    cfg = configobj.ConfigObj(infile=str(path), default_encoding="utf-8", encoding="utf-8")
    return str(cfg.get("odin", {}).get("odin_enable", "0"))


if __name__ == "__main__":
    raise SystemExit(main())
