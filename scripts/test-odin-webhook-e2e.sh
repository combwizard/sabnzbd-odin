#!/usr/bin/env bash
# End-to-end: Odin download row + SAB fork grab + webhook → IMPORT enqueue.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_INI="${ROOT}/.dev/homelab.sabnzbd.ini"
PORT="${SAB_HOMELAB_PORT:-8385}"
BIND="127.0.0.1:${PORT}"
BASE="http://${BIND}/sabnzbd"
TEST_NZB_SRC="${ROOT}/tests/data/test_file_extension/some_nzb_file"
TEST_NZB="${ROOT}/.dev/e2e-webhook.nzb"
PG_CONTAINER="${ODIN_PG_CONTAINER:-odin-postgres-1}"
FORK_CLIENT_ID="c0ffee00-0001-4000-8000-000000000001"
FORK_DEST_ID="c0ffee00-0002-4000-8000-000000000002"
TARGET_ID="${ODIN_E2E_TARGET_ID:-9d2236d9-e9b7-4757-945b-3ed3a990fc81}"
DL_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
LOG_MARK="e2e-webhook-${DL_ID}"

psql() {
  docker exec -i "${PG_CONTAINER}" psql -U odin -d odin -v ON_ERROR_STOP=1 "$@"
}

require_up() {
  curl -sf "${BASE}/api?mode=version&output=json" >/dev/null || {
    echo "SAB fork not running on ${BIND}. Run scripts/start-sab-fork-daemon.sh" >&2
    exit 1
  }
  local odin_key
  odin_key="$(grep -A1 '^rest:' "${ROOT}/../odin/config.yaml" | grep api_key | sed 's/.*: *//' | tr -d '"')"
  curl -sf "http://127.0.0.1:8688/api/v1/system/status" -H "X-Api-Key: ${odin_key}" >/dev/null || {
    echo "Odin API not reachable on :8688" >&2
    exit 1
  }
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
cp -f "${TEST_NZB_SRC}" "${TEST_NZB}"

API_KEY="$(python3 - <<'PY' "${DEV_INI}"
import configobj, sys
print(configobj.ConfigObj(sys.argv[1], encoding="utf-8")["misc"]["api_key"])
PY
)"

echo "==> Wire target to Odin Fork Test (restored on exit)"
IFS=$'\t' read -r TITLE ORIG_DEST ORIG_STATUS < <(psql -tA -F $'\t' -c "
SELECT mi.title, COALESCE(mt.destination_id::text,'NULL'), mt.status::text
FROM media_targets mt
JOIN media_items mi ON mi.id = mt.media_item_id
WHERE mt.id='${TARGET_ID}'::uuid")

psql -c "
UPDATE media_targets
SET destination_id='${FORK_DEST_ID}'::uuid, status='GRABBED'
WHERE id='${TARGET_ID}'::uuid;
INSERT INTO downloads (
  id, target_id, client_id, external_id, title, status, progress,
  messages, attempt_count, max_attempts, manual_grab
) VALUES (
  '${DL_ID}'::uuid,
  '${TARGET_ID}'::uuid,
  '${FORK_CLIENT_ID}'::uuid,
  'pending-e2e',
  'odin-e2e-webhook',
  'QUEUED',
  0,
  '[\"grabbed\"]'::jsonb,
  1,
  5,
  true
);"

echo "  target: ${TITLE}"
echo "  download_id: ${DL_ID}"

echo "==> SAB addlocalfile (Odin correlation IDs)"
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

psql -c "
UPDATE downloads
SET external_id='${NZO_ID}', status='DOWNLOADING', progress=0.01
WHERE id='${DL_ID}'::uuid;
UPDATE media_targets SET status='DOWNLOADING' WHERE id='${TARGET_ID}'::uuid;"

echo "==> Wait for SAB completion (max 3 min)"
for _ in $(seq 1 90); do
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
  if [[ "${ST}" == "Completed" || "${ST}" == "Failed" ]]; then
    echo "  SAB terminal status: ${ST}"
    break
  fi
  sleep 2
done
[[ "${ST:-}" == "Completed" ]] || {
  echo "SAB did not complete in time (status=${ST:-unknown})" >&2
  exit 1
}

echo "==> Give webhook a moment"
sleep 3

echo "==> Verify Odin state (webhook path)"
psql -c "
SELECT d.id, d.status::text AS download_status, d.output_path, mt.status::text AS target_status
FROM downloads d
JOIN media_targets mt ON mt.id = d.target_id
WHERE d.id='${DL_ID}'::uuid;"

IMPORT_COUNT="$(psql -tA -c "
SELECT COUNT(*)::int FROM river_job
WHERE kind='IMPORT'
  AND args->>'download_id'='${DL_ID}'")"

IMPORT_STATE="$(psql -tA -c "
SELECT state::text FROM river_job
WHERE kind='IMPORT' AND args->>'download_id'='${DL_ID}'
ORDER BY id DESC LIMIT 1")"

DOWNLOAD_STATUS="$(psql -tA -c "SELECT status::text FROM downloads WHERE id='${DL_ID}'::uuid")"
TARGET_STATUS="$(psql -tA -c "SELECT status::text FROM media_targets WHERE id='${TARGET_ID}'::uuid")"
OUTPUT_PATH="$(psql -tA -c "SELECT COALESCE(output_path,'') FROM downloads WHERE id='${DL_ID}'::uuid")"

echo "  download_status=${DOWNLOAD_STATUS}"
echo "  target_status=${TARGET_STATUS}"
echo "  output_path=${OUTPUT_PATH}"
echo "  import_jobs=${IMPORT_COUNT} (latest_state=${IMPORT_STATE:-none})"

WEBHOOK_LOG="$(grep -F "Odin webhook delivered" /opt/_dockers/sabnzbd-odin/config/logs/sabnzbd.log 2>/dev/null | grep -F "${NZO_ID}" | tail -1 || \
  grep -F "Odin webhook delivered" "${ROOT}/.dev/sabnzbd-fork.log" 2>/dev/null | grep -F "${NZO_ID}" | tail -1 || true)"
[[ -n "${WEBHOOK_LOG}" ]] && echo "  sab_log: ${WEBHOOK_LOG}"

if [[ "${DOWNLOAD_STATUS}" != "COMPLETED" ]]; then
  echo "FAIL: expected download COMPLETED, got ${DOWNLOAD_STATUS}" >&2
  exit 1
fi
if [[ -z "${OUTPUT_PATH}" ]]; then
  echo "FAIL: webhook did not set output_path" >&2
  exit 1
fi
if [[ "${IMPORT_COUNT}" -lt 1 ]]; then
  echo "FAIL: no IMPORT job recorded for download" >&2
  exit 1
fi
if [[ -z "${WEBHOOK_LOG}" ]]; then
  echo "FAIL: SAB log missing webhook delivery for ${NZO_ID}" >&2
  exit 1
fi
# Test NZB unpacks junk files, not real media — import may finish quickly and reset target to WANTED.

echo "==> Cleanup SAB history/queue artifact"
curl -sfG "${BASE}/api" \
  --data-urlencode "mode=history" \
  --data-urlencode "name=delete" \
  --data-urlencode "value=${NZO_ID}" \
  --data-urlencode "del_files=1" \
  --data-urlencode "apikey=${API_KEY}" >/dev/null || true

psql -c "
DELETE FROM river_job WHERE kind='IMPORT' AND args->>'download_id'='${DL_ID}';
DELETE FROM downloads WHERE id='${DL_ID}'::uuid;
UPDATE media_targets SET status='WANTED' WHERE id='${TARGET_ID}'::uuid;" >/dev/null

echo "PASS: webhook E2E (${LOG_MARK})"
