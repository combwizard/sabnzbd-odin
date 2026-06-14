#!/usr/bin/env bash
# Cut over production SABnzbd from Docker (:8383) to the Odin fork under sabnzbd-odin.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER_ROOT="${SAB_ODIN_DOCKER_ROOT:-/opt/_dockers/sabnzbd-odin}"
DOCKER_CONFIG="${DOCKER_ROOT}/config"
OLD_DOCKER="/opt/_dockers/sabnzbd"
OLD_CONFIG="${OLD_DOCKER}/config"
PROD_INI="${DOCKER_CONFIG}/sabnzbd.ini"
PORT="${SAB_PROD_PORT:-8383}"
PYTHON="${ROOT}/.venv/bin/python"

echo "==> Preconditions"
command -v par2 >/dev/null || { echo "Install par2 on the host first." >&2; exit 1; }
[[ -x "${PYTHON}" ]] || {
  echo "Creating venv..."
  python3 -m venv "${ROOT}/.venv"
  "${ROOT}/.venv/bin/pip" install -q -r "${ROOT}/requirements.txt"
}

mkdir -p "${DOCKER_CONFIG}/"{admin,logs,scripts}

echo "==> Sync config from ${OLD_CONFIG} (preserve queue/history)"
if [[ -d "${OLD_CONFIG}/admin" ]]; then
  rsync -a "${OLD_CONFIG}/admin/" "${DOCKER_CONFIG}/admin/"
fi
if [[ -f "${OLD_CONFIG}/sabnzbd.ini" ]]; then
  cp -a "${OLD_CONFIG}/sabnzbd.ini" "${PROD_INI}"
elif [[ ! -f "${PROD_INI}" ]]; then
  echo "No source sabnzbd.ini found." >&2
  exit 1
fi
if [[ -d "${OLD_CONFIG}/scripts" ]]; then
  rsync -a "${OLD_CONFIG}/scripts/" "${DOCKER_CONFIG}/scripts/"
fi

echo "==> Patch prod ini (host paths, port ${PORT}, [odin])"
"${PYTHON}" "${ROOT}/scripts/patch-sabnzbd-ini.py" \
  "${PROD_INI}" "${PROD_INI}" "${PORT}" "${DOCKER_CONFIG}" "${ROOT}/../odin"

echo "==> Stop homelab fork on :8385 (if running)"
if [[ -f "${ROOT}/.dev/sabnzbd-fork.pid" ]]; then
  pid="$(cat "${ROOT}/.dev/sabnzbd-fork.pid")"
  kill "${pid}" 2>/dev/null || true
  rm -f "${ROOT}/.dev/sabnzbd-fork.pid"
fi
pkill -f "${ROOT}/SABnzbd.py -f ${ROOT}/.dev/homelab.sabnzbd.ini" 2>/dev/null || true

echo "==> Stop Docker SAB (${OLD_DOCKER})"
if docker ps --format '{{.Names}}' | grep -qx sabnzbd; then
  (cd "${OLD_DOCKER}" && docker compose stop sabnzbd)
fi

echo "==> Start prod fork under ${DOCKER_ROOT}"
"${ROOT}/scripts/start-sab-prod-daemon.sh"

API_KEY="$(python3 -c "import configobj; print(configobj.ConfigObj('${PROD_INI}', encoding='utf-8')['misc']['api_key'])")"
VER="$(curl -sf "http://127.0.0.1:${PORT}/sabnzbd/api?mode=version&output=json&apikey=${API_KEY}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))')"
Q="$(curl -sf "http://127.0.0.1:${PORT}/sabnzbd/api?mode=queue&output=json&apikey=${API_KEY}" | python3 -c 'import json,sys; q=json.load(sys.stdin).get("queue",{}); print(len(q.get("slots",[])))')"

echo "==> Verify"
echo "  version: ${VER}"
echo "  queue slots: ${Q}"
grep -q "odin_enable = 1" "${PROD_INI}" && echo "  odin webhooks: enabled"

echo
echo "Cutover complete."
echo "  Prod UI: http://127.0.0.1:${PORT}/sabnzbd"
echo "  Config:  ${PROD_INI}"
echo "  Logs:    ${DOCKER_ROOT}/sabnzbd-fork.log"
echo
echo "Odin client 'SabNZBd' should keep working at :${PORT} (same API key)."
echo "To prevent Docker SAB from restarting: cd ${OLD_DOCKER} && docker compose down"
