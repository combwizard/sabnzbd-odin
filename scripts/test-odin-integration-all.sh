#!/usr/bin/env bash
# Run the Odin ↔ SABnzbd fork validation suite.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

echo "############################################"
echo "# Odin integration suite"
echo "############################################"

scripts/start-sab-fork-daemon.sh

echo
echo "==> Unit tests (Python)"
.venv/bin/python -m pytest tests/test_api_odin.py tests/test_odin_webhook.py tests/test_bpsmeter_nzo.py -q

echo
echo "==> API metadata smoke"
scripts/test-odin-integration.sh

echo
echo "==> Webhook completion E2E"
scripts/test-odin-webhook-e2e.sh

echo
echo "==> Webhook failure E2E"
scripts/test-odin-webhook-failure-e2e.sh

echo
echo "==> Import restart heal"
scripts/test-odin-import-restart-heal.sh

if [[ -d "${ROOT}/../odin" ]]; then
  echo
  echo "==> Odin unit tests (webhook + sabnzbd)"
  (cd "${ROOT}/../odin" && go test ./internal/download/ -run 'TestSabWebhook' -count=1)
  (cd "${ROOT}/../odin" && go test ./api/rest/ -run 'TestPostSABnzbdWebhook' -count=1)
fi

echo
echo "############################################"
echo "# ALL PASSED"
echo "############################################"
