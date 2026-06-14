#!/usr/bin/env bash
# Start the Odin-enabled SABnzbd fork as production on :8383.
# Config and runtime files live under /opt/_dockers/sabnzbd-odin.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER_ROOT="${SAB_ODIN_DOCKER_ROOT:-/opt/_dockers/sabnzbd-odin}"
DOCKER_CONFIG="${DOCKER_ROOT}/config"
PROD_INI="${DOCKER_CONFIG}/sabnzbd.ini"
LOG_FILE="${DOCKER_ROOT}/sabnzbd-fork.log"
PID_FILE="${DOCKER_ROOT}/sabnzbd-fork.pid"
PORT="${SAB_PROD_PORT:-8383}"
BIND="${SAB_PROD_BIND:-0.0.0.0:${PORT}}"
PYTHON="${ROOT}/.venv/bin/python"

if [[ ! -x "${PYTHON}" ]]; then
  echo "Missing venv at ${PYTHON}. Run: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt" >&2
  exit 1
fi

if [[ ! -f "${PROD_INI}" ]]; then
  echo "Missing ${PROD_INI}. Run scripts/cutover-prod.sh or scripts/run-prod.sh first." >&2
  exit 1
fi

if ! command -v par2 >/dev/null 2>&1; then
  echo "par2 is required on the host for downloads to start." >&2
  exit 1
fi

stop_prod() {
  if [[ -f "${PID_FILE}" ]]; then
    local pid
    pid="$(cat "${PID_FILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
      echo "Stopping SAB prod fork pid ${pid}"
      kill "${pid}" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "${pid}" 2>/dev/null || return 0
        sleep 0.5
      done
      kill -9 "${pid}" 2>/dev/null || true
    fi
  fi
  pkill -f "${ROOT}/SABnzbd.py -f ${PROD_INI}" 2>/dev/null || true
}

if curl -sf "http://127.0.0.1:${PORT}/sabnzbd/api?mode=version&output=json" >/dev/null 2>&1; then
  ver="$(curl -sf "http://127.0.0.1:${PORT}/sabnzbd/api?mode=version&output=json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)"
  echo "SAB prod fork already listening on http://127.0.0.1:${PORT}/sabnzbd (version=${ver})"
  exit 0
fi

stop_prod
mkdir -p "${DOCKER_CONFIG}/logs" "${DOCKER_ROOT}"

cd "${ROOT}"
setsid nohup "${PYTHON}" -OO SABnzbd.py -f "${PROD_INI}" -s "${BIND}" -b 0 >>"${LOG_FILE}" 2>&1 </dev/null &
echo $! >"${PID_FILE}"

for _ in $(seq 1 40); do
  if curl -sf "http://127.0.0.1:${PORT}/sabnzbd/api?mode=version&output=json" >/dev/null 2>&1; then
    echo "SAB prod fork ready"
    echo "  UI:  http://127.0.0.1:${PORT}/sabnzbd"
    echo "  cfg: ${PROD_INI}"
    echo "  pid: $(cat "${PID_FILE}")"
    exit 0
  fi
  sleep 0.5
done

echo "SAB prod fork failed to start. Recent log:" >&2
tail -30 "${LOG_FILE}" >&2 || true
exit 1
