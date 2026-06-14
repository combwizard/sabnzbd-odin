#!/usr/bin/env bash
# Prepare and run Odin ↔ SABnzbd fork integration test.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER_ROOT="${SAB_ODIN_DOCKER_ROOT:-/opt/_dockers/sabnzbd-odin}"
DOCKER_CONFIG="${DOCKER_ROOT}/config"
SOURCE_INI="${DOCKER_CONFIG}/sabnzbd.ini"
PORT="${SAB_HOMELAB_PORT:-8385}"
BIND="127.0.0.1:${PORT}"
PID_FILE="${ROOT}/.dev/sabnzbd-fork.pid"
LOG_FILE="${ROOT}/.dev/sabnzbd-fork.log"
DEV_INI="${ROOT}/.dev/homelab.sabnzbd.ini"
ODIN_SQL="${ROOT}/../odin/scripts/setup-sab-fork-client.sql"

cd "${ROOT}"

PYTHON="${ROOT}/.venv/bin/python"
if [[ ! -x "${PYTHON}" ]]; then
  echo "Creating venv and installing requirements..."
  python3 -m venv "${ROOT}/.venv"
  "${ROOT}/.venv/bin/pip" install -q -r requirements.txt -r tests/requirements.txt
  PYTHON="${ROOT}/.venv/bin/python"
fi

mkdir -p "${ROOT}/.dev"
if [[ ! -f "${SOURCE_INI}" ]]; then
  echo "Missing ${SOURCE_INI}" >&2
  exit 1
fi

"${PYTHON}" - <<'PY' "${SOURCE_INI}" "${ROOT}/.dev/homelab.sabnzbd.ini" "${PORT}" "${DOCKER_CONFIG}" "${ROOT}"
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
PY

start_fork() {
  if curl -sf "http://${BIND}/sabnzbd/api?mode=version" >/dev/null 2>&1; then
    echo "SAB fork already listening on ${BIND}"
    return 0
  fi
  if ! command -v par2 >/dev/null 2>&1; then
    echo "Warning: par2 not installed; SAB may log errors but the API should still work for this test." >&2
  fi
  echo "Starting SAB fork on ${BIND} (detached) ..."
  setsid nohup "${PYTHON}" -OO SABnzbd.py -f "${ROOT}/.dev/homelab.sabnzbd.ini" -s "${BIND}" -b 0 >>"${LOG_FILE}" 2>&1 </dev/null &
  echo $! >"${PID_FILE}"
  for _ in $(seq 1 40); do
    if curl -sf "http://${BIND}/sabnzbd/api?mode=version" >/dev/null 2>&1; then
      echo "SAB fork ready (pid $(cat "${PID_FILE}"))"
      return 0
    fi
    sleep 0.5
  done
  echo "SAB fork failed to start. Log:" >&2
  tail -30 "${LOG_FILE}" >&2 || true
  exit 1
}

start_fork
"${ROOT}/scripts/test-odin-integration.sh"

if [[ -f "${ODIN_SQL}" ]]; then
  echo "==> Updating Odin download clients in Postgres"
  docker exec -i odin-postgres-1 psql -U odin -d odin -v sab_fork_port="${PORT}" <"${ODIN_SQL}"
  export SAB_API_KEY="$(python3 - <<'PY' "${DEV_INI}"
import configobj, sys
print(configobj.ConfigObj(sys.argv[1], encoding="utf-8")["misc"]["api_key"])
PY
)"
  if [[ -d "${ROOT}/../odin" ]]; then
    echo "==> Odin connectivity test (optional)"
    (cd "${ROOT}/../odin" && SAB_API_KEY="${SAB_API_KEY}" go test ./internal/download/ -run TestSABnzbdForkConnectivity -count=1) || true
  fi
else
  echo "Skipping Odin DB setup (missing ${ODIN_SQL})" >&2
fi

echo
echo "Done."
echo "  SAB fork UI: http://${BIND}/sabnzbd"
echo "  Run metadata test again: ${ROOT}/scripts/test-odin-integration.sh"
echo "  Odin: Settings → Download clients → Test on 'SABnzbd Fork'"
