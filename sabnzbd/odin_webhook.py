#!/usr/bin/python3 -OO
# Copyright (C) 2026 Combwizard
# Part of sabnzbd-odin; based on SABnzbd - Copyright 2007-2026 by The SABnzbd-Team (sabnzbd.org)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

"""
sabnzbd.odin_webhook - Push terminal download events to Odin
"""

import json
import logging
import urllib.error
import urllib.request
from threading import Thread
from typing import TYPE_CHECKING, Any

import sabnzbd.cfg as cfg
from sabnzbd.constants import Status
from sabnzbd.encoding import utob

if TYPE_CHECKING:
    from sabnzbd.nzb import NzbObject

_ODIN_API_KEY_HEADER = "X-Api-Key"


def notify_terminal(nzo: "NzbObject", storage: str) -> None:
    """Notify Odin when a job reaches a terminal post-processing state."""
    if not cfg.odin_enable():
        return

    odin_download_id = nzo.nzo_info.get("odin_download_id", "")
    odin_target_id = nzo.nzo_info.get("odin_target_id", "")
    if not odin_download_id and not odin_target_id:
        return

    url = cfg.odin_url().strip()
    if not url:
        logging.debug("Odin webhook skipped: odin_url is empty")
        return

    event = "completed" if nzo.status == Status.COMPLETED else "failed"
    payload = {
        "event": event,
        "nzo_id": nzo.nzo_id,
        "odin_download_id": odin_download_id,
        "odin_target_id": odin_target_id,
        "status": nzo.status,
        "storage": storage or "",
        "fail_message": nzo.fail_msg or "",
    }
    Thread(target=_post_webhook, args=(url, payload), daemon=True, name="OdinWebhook").start()


def _post_webhook(url: str, payload: dict[str, Any]) -> None:
    body = utob(json.dumps(payload))
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    api_key = cfg.odin_api_key().strip()
    if api_key:
        req.add_header(_ODIN_API_KEY_HEADER, api_key)

    try:
        with urllib.request.urlopen(req, timeout=45) as response:
            logging.info(
                "Odin webhook delivered for nzo_id=%s event=%s status=%s",
                payload.get("nzo_id"),
                payload.get("event"),
                response.status,
            )
    except urllib.error.HTTPError as err:
        logging.warning(
            "Odin webhook HTTP error for nzo_id=%s: %s %s",
            payload.get("nzo_id"),
            err.code,
            err.reason,
        )
    except Exception:
        logging.warning("Odin webhook failed for nzo_id=%s", payload.get("nzo_id"), exc_info=True)
