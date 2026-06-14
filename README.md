# sabnzbd-odin

SABnzbd fork for use as a headless Usenet download worker with [Odin](https://github.com/combwizard/odin).

Upstream SABnzbd does not include these changes. Odin can still talk to stock SAB using queue-level speed, but **metadata passthrough**, **per-slot download speed**, and **completion webhooks** require this fork (or equivalent patches).

Based on [sabnzbd/sabnzbd](https://github.com/sabnzbd/sabnzbd) (GPL v2). General SABnzbd documentation: [sabnzbd.org](https://sabnzbd.org).

## What this fork adds

| Feature | Summary |
|---------|---------|
| **Metadata passthrough** | Odin passes `odin_download_id` and `odin_target_id` when adding NZBs; SAB stores them on the job and echoes them in queue/history API responses. |
| **Per-slot `kbpersec`** | Each queue slot reports its own download speed (stock SAB only exposes total speed on the queue header). |
| **Completion webhooks** | When post-processing finishes, SAB POSTs a terminal event to Odin so import can start immediately without polling. |

See [docs/ODIN.md](docs/ODIN.md) for API parameters, webhook payload, configuration, and code map.

## Requirements

- Python 3.10+
- Dependencies in `requirements.txt` (`python3 -m pip install -r requirements.txt -U`)
- System binaries: `par2`, `unrar` (see [upstream install guide](https://github.com/sabnzbd/sabnzbd/blob/master/INSTALL.txt))

## Quick start

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt -r tests/requirements.txt

# Run (creates sabnzbd.ini in the default data dir on first start)
.venv/bin/python -OO SABnzbd.py

# Or with an explicit config file
.venv/bin/python -OO SABnzbd.py -f /path/to/sabnzbd.ini
```

Enable Odin webhooks in `sabnzbd.ini`:

```ini
[odin]
odin_enable = 1
odin_url = http://127.0.0.1:8688/api/v1/webhook/sabnzbd
odin_api_key = your-odin-rest-api-key
```

Add an NZB with Odin correlation IDs:

```http
GET /sabnzbd/api?mode=addurl&apikey=…&name=…&cat=odin
    &odin_download_id=f47ac10b-58cc-4372-a567-0e02b2c3d479
    &odin_target_id=6ba7b810-9dad-11d1-80b4-00c04fd430c8
```

Optional parameters on `addurl`, `addfile`, and `addlocalfile`.

## Testing

Unit tests for the Odin integration:

```bash
.venv/bin/python -m pytest tests/test_api_odin.py tests/test_odin_webhook.py tests/test_bpsmeter_nzo.py -q
```

Homelab validation scripts (require a running fork and, for E2E, a running Odin instance) live under `scripts/test-odin-*.sh`. See [docs/ODIN.md](docs/ODIN.md#homelab-scripts).

## Relationship to upstream

This repo tracks upstream SABnzbd on `develop` and layers Odin-specific changes on top. It is maintained for Odin integration, not as a general-purpose SABnzbd distribution.

- **Upstream:** https://github.com/sabnzbd/sabnzbd
- **Odin consumer:** https://github.com/combwizard/odin — see `odin/.cursor/docs/SABNZBD-INTEGRATION.md` in that repo for the client side (status mirroring, speed resolution, webhook receiver).

## License

GPL v2 — same as upstream SABnzbd.

## Copyright

SABnzbd is Copyright 2007-2026 by The SABnzbd-Team ([sabnzbd.org](https://sabnzbd.org)).

Odin integration code in this fork is Copyright (C) 2026 Combwizard. Modified upstream files retain the SABnzbd-Team notice with an additional modification line; new files (e.g. `sabnzbd/odin_webhook.py`) are attributed to Combwizard and note their basis in SABnzbd.
