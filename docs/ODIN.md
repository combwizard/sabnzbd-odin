# Odin integration

This fork adds features so Odin can use SABnzbd as a headless download worker with stable job correlation and richer queue telemetry.

## Status

| Feature | State |
|---------|-------|
| Metadata passthrough at grab time | Done |
| Per-slot `kbpersec` in queue API | Done |
| Completion webhooks to Odin | Done |

---

## Metadata passthrough

Odin passes correlation IDs when adding NZBs. SAB stores them on `nzo_info`, persists them with the queue, and echoes them in queue/history API responses.

### API parameters

Optional on `addurl`, `addfile`, and `addlocalfile`:

| Parameter | Description |
|-----------|-------------|
| `odin_download_id` | Odin `downloads.id` (UUID) |
| `odin_target_id` | Odin `media_targets.id` (UUID) |

Example:

```http
GET /sabnzbd/api?mode=addurl&apikey=…&name=…&cat=odin
    &odin_download_id=f47ac10b-58cc-4372-a567-0e02b2c3d479
    &odin_target_id=6ba7b810-9dad-11d1-80b4-00c04fd430c8
```

### Storage

- Typed keys on `NzoInfo` in `sabnzbd/nzb/object.py` (`odin_download_id`, `odin_target_id`)
- Written at add time via `_odin_info_from_kwargs()` in `sabnzbd/api.py`
- Survives queue save/restore in `nzo_info`
- Persisted in history SQLite `meta` column after completion

### API output

Queue and history slots include:

```json
{
  "nzo_id": "…",
  "odin_download_id": "f47ac10b-…",
  "odin_target_id": "6ba7b810-…"
}
```

---

## Per-slot download speed (`kbpersec`)

Stock SAB exposes **total** download speed on the queue header only (`queue.kbpersec`). Individual slots do not include `kbpersec`, which breaks consumers that bind one queue slot to one Odin download.

### Behaviour

1. **`BPSMeter.update_nzo(nzo_id, bytes)`** — called from `newswrapper.py` when a full article is received for that job
2. **`BPSMeter.nzo_bps`** — exponential moving average per `nzo_id`, updated on each `BPSMeter.update()` tick (same model as `server_bps`)
3. **`build_queue()`** — sets `slot["kbpersec"]` via `_slot_kbpersec()` when slot status is `Downloading`; otherwise `"0.00"`

Queue-level `kbpersec` is unchanged (sum across all active downloads).

### API example

```json
{
  "queue": {
    "kbpersec": "89521.06",
    "slots": [
      {
        "nzo_id": "…",
        "status": "Downloading",
        "kbpersec": "42150.00",
        "odin_download_id": "…"
      }
    ]
  }
}
```

---

## Completion webhooks

When post-processing finishes, SAB pushes a terminal event to Odin. Odin enqueues import immediately; polling remains a fallback.

### Configuration (`[odin]` in `sabnzbd.ini`)

| Option | Description |
|--------|-------------|
| `odin_enable` | `1` to send webhooks |
| `odin_url` | Full URL, e.g. `http://127.0.0.1:8688/api/v1/webhook/sabnzbd` |
| `odin_api_key` | Odin REST API key (`X-Api-Key` header) |

Webhooks are sent only for jobs that have `odin_download_id` or `odin_target_id` on `nzo_info`.

There is no Config UI for these options — edit `sabnzbd.ini` directly or use the homelab scripts below.

### Webhook payload

```json
{
  "event": "completed",
  "nzo_id": "SABnzbd_nzo_…",
  "odin_download_id": "f47ac10b-…",
  "odin_target_id": "6ba7b810-…",
  "status": "Completed",
  "storage": "/path/to/completed/file.mkv",
  "fail_message": ""
}
```

`event` is `completed` or `failed`. `storage` is the final path after sorting.

### Odin receiver

Odin exposes `POST /api/v1/webhook/sabnzbd` (REST API key required). It resolves the download by `odin_download_id` or `nzo_id` (`external_id`), then calls `claimCompleted` / `claimFailed` and enqueues IMPORT.

---

## Code map

| File | Change |
|------|--------|
| `sabnzbd/nzb/object.py` | `NzoInfo` keys for Odin IDs |
| `sabnzbd/api.py` | Add handlers, queue/history slot fields, per-slot `kbpersec` |
| `sabnzbd/bpsmeter.py` | Per-job BPS tracking |
| `sabnzbd/newswrapper.py` | `update_nzo()` on completed article |
| `sabnzbd/cfg.py` | `[odin]` options |
| `sabnzbd/odin_webhook.py` | Async POST on terminal events |
| `sabnzbd/postproc.py` | Hook after history write |
| `sabnzbd/database.py` | Persist Odin IDs in history `meta` column |
| `tests/test_api_odin.py` | Metadata passthrough and queue output |
| `tests/test_bpsmeter_nzo.py` | BPSMeter per-job tracking |
| `tests/test_odin_webhook.py` | Webhook unit tests |

---

## Homelab scripts

Optional scripts under `scripts/` for running and validating the fork alongside Odin. Paths and ports are configurable via environment variables.

| Script | Purpose |
|--------|---------|
| `scripts/patch-sabnzbd-ini.py` | Patch INI for host-run fork (paths, port, `[odin]`) |
| `scripts/run-homelab.sh` | Build overlay INI; start fork on dev port |
| `scripts/start-sab-fork-daemon.sh` | Start fork detached |
| `scripts/setup-odin-test.sh` | One-shot: venv, ini, start fork, run API test |
| `scripts/test-odin-integration.sh` | API smoke: add with Odin IDs, verify queue echo |
| `scripts/test-odin-webhook.sh` | Smoke POST to Odin webhook endpoint |
| `scripts/test-odin-webhook-e2e.sh` | Full loop: Odin download → SAB grab → webhook → IMPORT |
| `scripts/test-odin-webhook-failure-e2e.sh` | SAB failure → webhook `failed` → no IMPORT |
| `scripts/test-odin-import-restart-heal.sh` | Orphan `running` IMPORT jobs requeued |
| `scripts/test-odin-integration-all.sh` | Run full validation suite |
| `scripts/cutover-prod.sh` | Prod cutover from Docker SAB to host fork |
| `scripts/start-sab-prod-daemon.sh` | Start production daemon |

### Environment overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `SAB_HOMELAB_PORT` | `8385` | Dev fork port |
| `SAB_HOMELAB_BIND` | `127.0.0.1:8385` | Dev bind address |
| `SAB_ODIN_DOCKER_ROOT` | `/opt/_dockers/sabnzbd-odin` | Config/runtime root for prod scripts |

E2E scripts expect Odin at `http://127.0.0.1:8688` and read its REST API key from `../odin/config.yaml` relative to this repo.

---

## Testing

```bash
# Unit tests
.venv/bin/python -m pytest tests/test_api_odin.py tests/test_odin_webhook.py tests/test_bpsmeter_nzo.py -q

# Full validation suite (daemon + unit + E2E; requires Odin)
scripts/test-odin-integration-all.sh
```

---

## Odin client

On the Odin side, the download client sends `odin_download_id` / `odin_target_id` at grab time, polls queue slots for per-job speed and status, and receives completion webhooks from this fork. Webhook handling and import are configured in Odin, not in SABnzbd.
