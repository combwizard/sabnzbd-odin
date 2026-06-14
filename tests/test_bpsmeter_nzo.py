#!/usr/bin/python3 -OO
# Copyright 2007-2026 by The SABnzbd-Team (sabnzbd.org)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.

import time

from sabnzbd.bpsmeter import BPSMeter


def test_update_nzo_tracks_per_job_speed():
    meter = BPSMeter()
    meter.init_server_stats("srv1")
    meter.update(server="srv1", amount=1024 * 150)
    meter.update_nzo("job-a", 1024 * 100)
    meter.update_nzo("job-b", 1024 * 50)
    meter.update()
    assert meter.nzo_bps["job-a"] > 0
    assert meter.nzo_bps["job-b"] > 0
    assert meter.nzo_bps["job-a"] > meter.nzo_bps["job-b"]


def test_update_nzo_resets_with_global_reset():
    meter = BPSMeter()
    meter.init_server_stats("srv1")
    meter.update(server="srv1", amount=1024)
    meter.update_nzo("job-a", 1024)
    meter.update()
    meter.bps = 0.0
    meter.start_time = time.time() - 10
    meter.reset()
    assert meter.nzo_bps == {}
    assert meter.nzo_cached_amount == {}
