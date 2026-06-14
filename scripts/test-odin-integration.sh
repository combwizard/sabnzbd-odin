#!/usr/bin/env bash
# Verify Odin metadata passthrough on a running SABnzbd fork instance.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_INI="${ROOT}/.dev/homelab.sabnzbd.ini"
PORT="${SAB_HOMELAB_PORT:-8385}"
BASE="http://127.0.0.1:${PORT}/sabnzbd"
TEST_NZB_SRC="${ROOT}/tests/data/test_file_extension/some_nzb_file"
TEST_NZB="${ROOT}/.dev/odin-test.nzb"
cp -f "${TEST_NZB_SRC}" "${TEST_NZB}"
DL_ID="f47ac10b-58cc-4372-a567-0e02b2c3d479"
TG_ID="6ba7b810-9dad-11d1-80b4-00c04fd430c8"

if [[ ! -f "${DEV_INI}" ]]; then
  echo "Missing ${DEV_INI}. Run scripts/run-homelab.sh first (or scripts/setup-odin-test.sh)." >&2
  exit 1
fi

API_KEY="$(python3 - <<'PY' "${DEV_INI}"
import configobj, sys
cfg = configobj.ConfigObj(sys.argv[1], encoding="utf-8")
print(cfg["misc"]["api_key"])
PY
)"

echo "==> SAB version"
VERSION="$(curl -sf "${BASE}/api?mode=version&output=json&apikey=${API_KEY}")"
echo "${VERSION}"

echo "==> Add local NZB with Odin correlation IDs"
ADD="$(curl -sfG "${BASE}/api" \
  --data-urlencode "mode=addlocalfile" \
  --data-urlencode "output=json" \
  --data-urlencode "apikey=${API_KEY}" \
  --data-urlencode "name=${TEST_NZB}" \
  --data-urlencode "cat=odin" \
  --data-urlencode "odin_download_id=${DL_ID}" \
  --data-urlencode "odin_target_id=${TG_ID}")"
echo "${ADD}"

NZO_ID="$(python3 - <<'PY' "${ADD}"
import json, sys
data = json.loads(sys.argv[1])
ids = data.get("nzo_ids") or []
if not ids:
    raise SystemExit("addlocalfile returned no nzo_ids")
print(ids[0])
PY
)"

sleep 1

echo "==> Queue slot should echo Odin IDs"
QUEUE="$(curl -sfG "${BASE}/api" \
  --data-urlencode "mode=queue" \
  --data-urlencode "output=json" \
  --data-urlencode "apikey=${API_KEY}" \
  --data-urlencode "nzo_ids=${NZO_ID}")"

python3 - <<'PY' "${QUEUE}" "${NZO_ID}" "${DL_ID}" "${TG_ID}"
import json, sys

queue = json.loads(sys.argv[1])
nzo_id, want_dl, want_tg = sys.argv[2:5]
slots = queue.get("queue", {}).get("slots") or queue.get("slots") or []
slot = next((s for s in slots if s.get("nzo_id") == nzo_id), None)
if slot is None:
    raise SystemExit(f"nzo_id {nzo_id} not found in queue ({len(slots)} slots)")
if slot.get("odin_download_id") != want_dl:
    raise SystemExit(f"odin_download_id mismatch: {slot.get('odin_download_id')!r}")
if slot.get("odin_target_id") != want_tg:
    raise SystemExit(f"odin_target_id mismatch: {slot.get('odin_target_id')!r}")
print(f"OK queue slot {nzo_id}")
print(f"  odin_download_id={slot['odin_download_id']}")
print(f"  odin_target_id={slot['odin_target_id']}")
PY

echo "==> Cleanup queue entry"
curl -sfG "${BASE}/api" \
  --data-urlencode "mode=queue" \
  --data-urlencode "name=delete" \
  --data-urlencode "value=${NZO_ID}" \
  --data-urlencode "del_files=1" \
  --data-urlencode "apikey=${API_KEY}" >/dev/null

echo "Odin metadata integration test passed."
