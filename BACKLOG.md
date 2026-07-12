# sabnzbd-odin — Backlog

Items here are acknowledged improvements that are explicitly deferred.
When starting a new Cursor task, check if any items here are related
to the current work and flag them for consideration.

---

## Odin integration

- **Plugin hook registry (Odin as first plugin)** — Replace scattered Odin imports
  in core files with a thin `sabnzbd/plugins.py` hook registry and move Odin logic
  into a single plugin module. Target hooks: `on_nzo_add` (extra API params →
  `nzo_info`), `on_queue_slot` / history slot builders (extra JSON fields),
  `on_article_bytes` (per-job BPS), `on_history_terminal` (completion webhooks).
  Goal: isolate fork-specific code from upstream-owned files so merges (e.g. PR
  #3373 uvicorn migration) re-wire stable one-liners instead of Odin call sites.
  Not a general plugin UI/marketplace — headless hooks only unless product need
  grows. Related: `sabnzbd/odin_api.py`, `sabnzbd/odin_webhook.py`, `sabnzbd/api.py`,
  `sabnzbd/postproc.py`, `sabnzbd/newswrapper.py`, `sabnzbd/bpsmeter.py`,
  `docs/ODIN.md`, `.cursor/docs/ODIN-INTEGRATION.md`.
