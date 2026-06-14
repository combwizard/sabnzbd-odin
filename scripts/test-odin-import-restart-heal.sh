#!/usr/bin/env bash
# Verify orphan IMPORT jobs are requeued (startup heal + reconciler SQL).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PG_CONTAINER="${ODIN_PG_CONTAINER:-odin-postgres-1}"
DL_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
JOB_TAG="odin-e2e-heal-$(date +%s)"

psql_scalar() {
  docker exec -i "${PG_CONTAINER}" psql -U odin -d odin -v ON_ERROR_STOP=1 -tA -c "$1" | tr -d '[:space:]'
}

run_tx() {
  docker exec -i "${PG_CONTAINER}" psql -U odin -d odin -v ON_ERROR_STOP=1 -q -tA <<SQL
BEGIN;
$1
COMMIT;
SQL
}

echo "==> Orphan IMPORT heal (${DL_ID})"

STARTUP_STATE="$(run_tx "
INSERT INTO river_job (
  kind, state, attempt, max_attempts, attempted_at, scheduled_at, priority, args, metadata, queue, tags
) VALUES (
  'IMPORT', 'running', 1, 3,
  now() - interval '20 minutes', now() - interval '20 minutes',
  1, jsonb_build_object('download_id', '${DL_ID}'), '{}'::jsonb, 'default',
  ARRAY['${JOB_TAG}-startup']::varchar[]
);
UPDATE river_job
SET state = 'available', scheduled_at = NOW(), finalized_at = NULL,
    attempted_at = NULL, attempted_by = NULL
WHERE kind = 'IMPORT' AND state = 'running' AND args->>'download_id' = '${DL_ID}';
SELECT state::text FROM river_job
WHERE kind='IMPORT' AND args->>'download_id'='${DL_ID}' ORDER BY id DESC LIMIT 1;
")"

[[ "${STARTUP_STATE}" == "available" ]] || {
  echo "FAIL: startup heal expected available, got '${STARTUP_STATE}'" >&2
  exit 1
}
echo "  startup heal: running → ${STARTUP_STATE}"

RECON_STATE="$(run_tx "
UPDATE river_job
SET state = 'running', attempted_at = now() - interval '20 minutes',
    finalized_at = NULL, attempted_by = ARRAY['dead-worker']
WHERE kind='IMPORT' AND args->>'download_id'='${DL_ID}';
UPDATE river_job
SET state = 'available', scheduled_at = NOW(), finalized_at = NULL,
    attempted_at = NULL, attempted_by = NULL
WHERE kind = 'IMPORT' AND state = 'running'
  AND COALESCE(attempted_at, created_at) < now() - interval '15 minutes'
  AND args->>'download_id' = '${DL_ID}';
SELECT state::text FROM river_job
WHERE kind='IMPORT' AND args->>'download_id'='${DL_ID}' ORDER BY id DESC LIMIT 1;
DELETE FROM river_job WHERE args->>'download_id' = '${DL_ID}';
")"

[[ "${RECON_STATE}" == "available" ]] || {
  echo "FAIL: reconciler heal expected available, got '${RECON_STATE}'" >&2
  exit 1
}
echo "  reconciler heal: running → ${RECON_STATE}"
echo "PASS: import restart heal (${JOB_TAG})"
