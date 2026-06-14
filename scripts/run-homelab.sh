#!/usr/bin/env bash
# Run the SABnzbd fork with homelab settings from /opt/_dockers/sabnzbd-odin.
# Uses host paths for download dirs and port 8385 so Docker (:8383) can stay up.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER_ROOT="${SAB_ODIN_DOCKER_ROOT:-/opt/_dockers/sabnzbd-odin}"
DOCKER_CONFIG="${DOCKER_ROOT}/config"
SOURCE_INI="${DOCKER_CONFIG}/sabnzbd.ini"
DEV_DIR="${ROOT}/.dev"
DEV_INI="${DEV_DIR}/homelab.sabnzbd.ini"
DEV_PORT="${SAB_HOMELAB_PORT:-8385}"
DEV_BIND="${SAB_HOMELAB_BIND:-127.0.0.1:${DEV_PORT}}"

if [[ ! -f "${SOURCE_INI}" ]]; then
  echo "Missing ${SOURCE_INI}" >&2
  exit 1
fi

mkdir -p "${DEV_DIR}"

PYTHON="${ROOT}/.venv/bin/python"
if [[ ! -x "${PYTHON}" ]]; then
  PYTHON="python3"
fi

"${PYTHON}" - <<'PY' "${SOURCE_INI}" "${DEV_INI}" "${DEV_PORT}" "${DOCKER_CONFIG}" "${ROOT}"
import re
import sys
from pathlib import Path

import configobj

source, dest, port, config_root, root = sys.argv[1:6]
config_root = Path(config_root)
root = Path(root)
dest_path = Path(dest)

cfg = configobj.ConfigObj(infile=source, default_encoding="utf-8", encoding="utf-8")
misc = cfg.setdefault("misc", {})

misc["port"] = port
misc["auto_browser"] = "0"
misc["download_dir"] = "/pool/downloads/sabnzbd/incomplete"
misc["complete_dir"] = "/pool/downloads/sabnzbd/completed"
misc["script_dir"] = str(config_root / "scripts")
misc["admin_dir"] = str(config_root / "admin")
misc["log_dir"] = str(config_root / "logs")

odin = None
if dest_path.exists():
    old = configobj.ConfigObj(infile=str(dest_path), default_encoding="utf-8", encoding="utf-8")
    odin = old.get("odin")

api_key = ""
odin_cfg = root.parent / "odin" / "config.yaml"
if odin_cfg.is_file():
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
                api_key = m.group(1).strip().strip('"').strip("'")
                break

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

cfg.filename = dest
cfg.write()
print(f"Wrote {dest}")
print(f"  port={port}")
print(f"  download_dir={misc['download_dir']}")
print(f"  complete_dir={misc['complete_dir']}")
print(f"  odin_enable={odin.get('odin_enable', '0')}")
PY

cd "${ROOT}"
if [[ "${1:-}" == "--daemon" || "${SAB_FORK_DAEMON:-}" == "1" ]]; then
  exec "${ROOT}/scripts/start-sab-fork-daemon.sh"
fi
exec "${PYTHON}" -OO SABnzbd.py -f "${DEV_INI}" -s "${DEV_BIND}" -b 0 "$@"
