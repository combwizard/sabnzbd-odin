#!/usr/bin/env bash
# POST a sample SABnzbd completion webhook to Odin (smoke test).
set -euo pipefail

ODIN_URL="${ODIN_URL:-http://127.0.0.1:8688}"
API_KEY="${ODIN_API_KEY:-${REST_API_KEY:-}}"

if [[ -z "${API_KEY}" ]]; then
  echo "Set ODIN_API_KEY or REST_API_KEY (Odin REST API key)." >&2
  exit 1
fi

DL_ID="${ODIN_DOWNLOAD_ID:-f47ac10b-58cc-4372-a567-0e02b2c3d479}"
NZO_ID="${SAB_NZO_ID:-SABnzbd_nzo_test}"

PAYLOAD="$(cat <<EOF
{
  "event": "completed",
  "nzo_id": "${NZO_ID}",
  "odin_download_id": "${DL_ID}",
  "odin_target_id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
  "status": "Completed",
  "storage": "/mnt/extra1/downloads/sabnzbd/completed/odin/test.mkv",
  "fail_message": ""
}
EOF
)"

echo "==> POST ${ODIN_URL}/api/v1/webhook/sabnzbd"
curl -sf -X POST "${ODIN_URL}/api/v1/webhook/sabnzbd" \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: ${API_KEY}" \
  -d "${PAYLOAD}"
echo
echo "==> OK"
