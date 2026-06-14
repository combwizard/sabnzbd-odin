#!/usr/bin/env bash
# Start the SABnzbd fork detached from the terminal (survives shell/Cursor session exit).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_INI="${ROOT}/.dev/homelab.sabnzbd.ini"
LOG_FILE="${ROOT}/.dev/sabnzbd-fork.log"
PID_FILE="${ROOT}/.dev/sabnzbd-fork.pid"
PORT="${SAB_HOMELAB_PORT:-8385}"
BIND="${SAB_HOMELAB_BIND:-127.0.0.1:${PORT}}"
PYTHON="${ROOT}/.venv/bin/python"

if [[ ! -x "${PYTHON}" ]]; then
  echo "Missing venv at ${PYTHON}. Run scripts/setup-odin-test.sh first." >&2
  exit 1
fi

if [[ ! -f "${DEV_INI}" ]]; then
  echo "Missing ${DEV_INI}. Run scripts/run-homelab.sh once to build it." >&2
  exit 1
fi

stop_fork() {
  if [[ -f "${PID_FILE}" ]]; then
    local pid
    pid="$(cat "${PID_FILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
      echo "Stopping SAB fork pid ${pid}"
      kill "${pid}" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "${pid}" 2>/dev/null || return 0
        sleep 0.5
      done
      kill -9 "${pid}" 2>/dev/null || true
    fi
  fi
  pkill -f "${ROOT}/SABnzbd.py -f ${DEV_INI}" 2>/dev/null || true
}

if curl -sf "http://${BIND}/sabnzbd/api?mode=version&output=json" >/dev/null 2>&1; then
  echo "SAB fork already listening on http://${BIND}/sabnzbd"
  exit 0
fi

stop_fork
mkdir -p "${ROOT}/.dev"

cd "${ROOT}"
setsid nohup "${PYTHON}" -OO SABnzbd.py -f "${DEV_INI}" -s "${BIND}" -b 0 >>"${LOG_FILE}" 2>&1 </dev/null &
echo $! >"${PID_FILE}"

for _ in $(seq 1 40); do
  if curl -sf "http://${BIND}/sabnzbd/api?mode=version&output=json" >/dev/null 2>&1; then
    echo "SAB fork ready"
    echo "  UI:  http://${BIND}/sabnzbd"
    echo "  pid: $(cat "${PID_FILE}")"
    exit 0
  fi
  sleep 0.5
done

echo "SAB fork failed to start. Recent log:" >&2
tail -30 "${LOG_FILE}" >&2 || true
exit 1
