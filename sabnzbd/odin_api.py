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
sabnzbd.odin_api - Odin API helpers (metadata passthrough and per-slot speed)
"""

from typing import Any

import sabnzbd
from sabnzbd.constants import KIBI, Status
from sabnzbd.nzb import NzbObject, NzoInfo


def _param_str(params: Any, key: str) -> str:
    """Return a single trimmed string from request/API parameters.

    Accepts dict-like params (CherryPy) and Starlette QueryParams (upstream #3373).
    """
    if hasattr(params, "getlist"):
        values = params.getlist(key)
        if values:
            return str(values[0]).strip()
    value = params.get(key)
    if isinstance(value, list):
        value = value[0] if value else ""
    if value is None:
        return ""
    return str(value).strip()


def odin_info_from_kwargs(kwargs: Any) -> NzoInfo:
    """Extract optional Odin correlation IDs from API parameters."""
    info: NzoInfo = {}
    if download_id := _param_str(kwargs, "odin_download_id"):
        info["odin_download_id"] = download_id
    if target_id := _param_str(kwargs, "odin_target_id"):
        info["odin_target_id"] = target_id
    return info


def odin_slot_fields(nzo: NzbObject) -> dict[str, str]:
    """Queue/history slot fields for Odin integration."""
    return {
        "odin_download_id": nzo.nzo_info.get("odin_download_id", ""),
        "odin_target_id": nzo.nzo_info.get("odin_target_id", ""),
    }


def slot_kbpersec(nzo: NzbObject, slot_status: str) -> str:
    """Per-job download speed in KB/s for queue slots."""
    if slot_status != Status.DOWNLOADING:
        return "0.00"
    bps = sabnzbd.BPSMeter.nzo_bps.get(str(nzo.nzo_id), 0.0)
    return "%.2f" % (bps / KIBI)
