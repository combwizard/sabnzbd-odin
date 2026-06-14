#!/usr/bin/python3 -OO
# Copyright (C) 2026 Combwizard
# Part of sabnzbd-odin; based on SABnzbd - Copyright 2007-2026 by The SABnzbd-Team (sabnzbd.org)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.

"""
tests.test_odin_webhook - Odin completion webhook from SABnzbd
"""

import json

import sabnzbd.odin_webhook as odin_webhook
from sabnzbd.constants import Status
from tests.test_nzbqueue import make_dummy_nzo


class TestOdinWebhook:
    def test_notify_terminal_skips_when_disabled(self, mocker):
        mocker.patch("sabnzbd.cfg.odin_enable", return_value=False)
        thread = mocker.patch("sabnzbd.odin_webhook.Thread")
        nzo = make_dummy_nzo("odin", files=1, articles=1)
        nzo.nzo_id = "SABnzbd_nzo_odin_test"
        nzo.nzo_info["odin_download_id"] = "dl-1"
        odin_webhook.notify_terminal(nzo, "/completed/file.mkv")
        thread.assert_not_called()

    def test_notify_terminal_skips_without_odin_ids(self, mocker):
        mocker.patch("sabnzbd.cfg.odin_enable", return_value=True)
        thread = mocker.patch("sabnzbd.odin_webhook.Thread")
        nzo = make_dummy_nzo("odin", files=1, articles=1)
        nzo.nzo_id = "SABnzbd_nzo_odin_test"
        odin_webhook.notify_terminal(nzo, "/completed/file.mkv")
        thread.assert_not_called()

    def test_notify_terminal_posts_completed_payload(self, mocker):
        mocker.patch("sabnzbd.cfg.odin_enable", return_value=True)
        mocker.patch("sabnzbd.cfg.odin_url", return_value="http://127.0.0.1:8688/api/v1/webhook/sabnzbd")
        mocker.patch("sabnzbd.cfg.odin_api_key", return_value="secret")
        thread = mocker.patch("sabnzbd.odin_webhook.Thread")
        nzo = make_dummy_nzo("odin", files=1, articles=1)
        nzo.nzo_id = "SABnzbd_nzo_odin_test"
        nzo.nzo_info["odin_download_id"] = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
        nzo.nzo_info["odin_target_id"] = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
        nzo.status = Status.COMPLETED
        odin_webhook.notify_terminal(nzo, "/pool/downloads/completed/movie.mkv")
        thread.assert_called_once()
        _, kwargs = thread.call_args
        assert kwargs["target"] == odin_webhook._post_webhook
        payload = kwargs["args"][1]
        assert payload["event"] == "completed"
        assert payload["odin_download_id"] == "f47ac10b-58cc-4372-a567-0e02b2c3d479"
        assert payload["storage"] == "/pool/downloads/completed/movie.mkv"

    def test_post_webhook_sends_api_key(self, mocker):
        mocker.patch("sabnzbd.cfg.odin_api_key", return_value="secret")
        opener = mocker.patch("urllib.request.urlopen")
        opener.return_value.__enter__.return_value.status = 200
        odin_webhook._post_webhook(
            "http://127.0.0.1:8688/api/v1/webhook/sabnzbd",
            {"event": "failed", "nzo_id": "SABnzbd_nzo_abc"},
        )
        req = opener.call_args[0][0]
        assert req.get_header("Content-type") == "application/json"
        assert req.get_header("X-api-key") == "secret"
        body = json.loads(req.data.decode("utf-8"))
        assert body["event"] == "failed"
