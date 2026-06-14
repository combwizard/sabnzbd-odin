#!/usr/bin/env bash
# End-to-end: SAB failure → webhook failed → Odin download FAILED, target WANTED.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_INI="${ROOT}/.dev/homelab.sabnzbd.ini"
PORT="${SAB_HOMELAB_PORT:-8385}"
BIND="127.0.0.1:${PORT}"
BASE="http://${BIND}/sabnzbd"
TEST_NZB="${ROOT}/.dev/e2e-fail.nzb"
PG_CONTAINER="${ODIN_PG_CONTAINER:-odin-postgres-1}"
FORK_CLIENT_ID="c0ffee00-0001-4000-8000-000000000001"
FORK_DEST_ID="c0ffee00-0002-4000-8000-000000000002"
TARGET_ID="${ODIN_E2E_TARGET_ID:-9d2236d9-e9b7-4757-945b-3ed3a990fc81}"
DL_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"

psql() {
  docker exec -i "${PG_CONTAINER}" psql -U odin -d odin -v ON_ERROR_STOP=1 "$@"
}

require_up() {
  curl -sf "${BASE}/api?mode=version&output=json" >/dev/null
  local odin_key
  odin_key="$(grep -A1 '^rest:' "${ROOT}/../odin/config.yaml" | grep api_key | sed 's/.*: *//' | tr -d '"')"
  curl -sf "http://127.0.0.1:8688/api/v1/system/status" -H "X-Api-Key: ${odin_key}" >/dev/null
}

restore_target() {
  if [[ -n "${ORIG_DEST:-}" && "${ORIG_DEST}" != "NULL" ]]; then
    psql -c "UPDATE media_targets SET destination_id='${ORIG_DEST}'::uuid, status='WANTED' WHERE id='${TARGET_ID}'::uuid" >/dev/null 2>&1 || true
  fi
}
trap restore_target EXIT

echo "==> Preconditions"
require_up
"${ROOT}/scripts/start-sab-fork-daemon.sh" >/dev/null 2>&1 || true
[[ -f "${TEST_NZB}" ]] || {
  echo "Missing ${TEST_NZB}" >&2
  exit 1
}

API_KEY="$(python3 - <<'PY' "${DEV_INI}"
import configobj, sys
print(configobj.ConfigObj(sys.argv[1], encoding="utf-8")["misc"]["api_key"])
PY
)"

IFS=$'\t' read -r TITLE ORIG_DEST ORIG_STATUS < <(psql -tA -F $'\t' -c "
SELECT mi.title, COALESCE(mt.destination_id::text,'NULL'), mt.status::text
FROM media_targets mt
JOIN media_items mi ON mi.id = mt.media_item_id
WHERE mt.id='${TARGET_ID}'::uuid")

echo "==> Wire target + download row"
psql -c "
UPDATE media_targets
SET destination_id='${FORK_DEST_ID}'::uuid, status='DOWNLOADING'
WHERE id='${TARGET_ID}'::uuid;
INSERT INTO downloads (
  id, target_id, client_id, external_id, title, status, progress,
  messages, attempt_count, max_attempts, manual_grab
) VALUES (
  '${DL_ID}'::uuid,
  '${TARGET_ID}'::uuid,
  '${FORK_CLIENT_ID}'::uuid,
  'pending-fail-e2e',
  'odin-e2e-webhook-fail',
  'DOWNLOADING',
  0.01,
  '[\"grabbed\"]'::jsonb,
  1,
  5,
  true
);"
echo "  target: ${TITLE}"
echo "  download_id: ${DL_ID}"

echo "==> SAB addlocalfile (doomed NZB)"
ADD="$(curl -sfG "${BASE}/api" \
  --data-urlencode "mode=addlocalfile" \
  --data-urlencode "output=json" \
  --data-urlencode "apikey=${API_KEY}" \
  --data-urlencode "name=${TEST_NZB}" \
  --data-urlencode "cat=odin" \
  --data-urlencode "odin_download_id=${DL_ID}" \
  --data-urlencode "odin_target_id=${TARGET_ID}")"
NZO_ID="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['nzo_ids'][0])" "${ADD}")"
echo "  nzo_id: ${NZO_ID}"

psql -c "UPDATE downloads SET external_id='${NZO_ID}' WHERE id='${DL_ID}'::uuid;"

echo "==> Wait for SAB failure (max 5 min)"
ST=""
for _ in $(seq 1 150); do
  HIST="$(curl -sfG "${BASE}/api" \
    --data-urlencode "mode=history" \
    --data-urlencode "output=json" \
    --data-urlencode "apikey=${API_KEY}" \
    --data-urlencode "nzo_ids=${NZO_ID}" || echo '{}')"
  ST="$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
slots=d.get('history',{}).get('slots') or d.get('slots') or []
print(slots[0]['status'] if slots else '')
" "${HIST}")"
  if [[ "${ST}" == "Failed" || "${ST}" == "Completed" ]]; then
    echo "  SAB terminal status: ${ST}"
    break
  fi
  sleep 2
done
[[ "${ST}" == "Failed" ]] || {
  echo "FAIL: expected SAB Failed, got ${ST:-unknown}" >&2
  exit 1
}

sleep 3

DOWNLOAD_STATUS="$(psql -tA -c "SELECT status::text FROM downloads WHERE id='${DL_ID}'::uuid")"
TARGET_STATUS="$(psql -tA -c "SELECT status::text FROM media_targets WHERE id='${TARGET_ID}'::uuid")"
IMPORT_COUNT="$(psql -tA -c "
SELECT COUNT(*)::int FROM river_job
WHERE kind='IMPORT' AND args->>'download_id'='${DL_ID}'")"

WEBHOOK_LOG="$(grep -F "Odin webhook delivered" /opt/_dockers/sabnzbd-odin/config/logs/sabnzbd.log 2>/dev/null | grep -F "${NZO_ID}" | tail -1 || \
  grep -F "Odin webhook delivered" "${ROOT}/.dev/sabnzbd-fork.log" 2>/dev/null | grep -F "${NZO_ID}" | tail -1 || true)"

echo "  download_status=${DOWNLOAD_STATUS}"
echo "  target_status=${TARGET_STATUS}"
echo "  import_jobs=${IMPORT_COUNT}"
[[ -n "${WEBHOOK_LOG}" ]] && echo "  sab_log: ${WEBHOOK_LOG}"

[[ "${DOWNLOAD_STATUS}" == "FAILED" ]] || {
  echo "FAIL: expected download FAILED, got ${DOWNLOAD_STATUS}" >&2
  exit 1
}
[[ "${TARGET_STATUS}" == "WANTED" ]] || {
  echo "FAIL: expected target WANTED, got ${TARGET_STATUS}" >&2
  exit 1
}
[[ "${IMPORT_COUNT}" == "0" ]] || {
  echo "FAIL: failed download should not enqueue IMPORT (count=${IMPORT_COUNT})" >&2
  exit 1
}
[[ -n "${WEBHOOK_LOG}" ]] || {
  echo "FAIL: missing SAB webhook log for ${NZO_ID}" >&2
  exit 1
}

curl -sfG "${BASE}/api" \
  --data-urlencode "mode=history" \
  --data-urlencode "name=delete" \
  --data-urlencode "value=${NZO_ID}" \
  --data-urlencode "del_files=1" \
  --data-urlencode "apikey=${API_KEY}" >/dev/null || true

psql -c "
DELETE FROM downloads WHERE id='${DL_ID}'::uuid;
UPDATE media_targets SET status='WANTED' WHERE id='${TARGET_ID}'::uuid;" >/dev/null

echo "PASS: webhook failure E2E (download_id=${DL_ID})"
