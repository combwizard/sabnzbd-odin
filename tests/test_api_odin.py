#!/usr/bin/python3 -OO
# Copyright 2007-2026 by The SABnzbd-Team (sabnzbd.org)
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
tests.test_api_odin - Odin integration metadata on the API
"""

from types import SimpleNamespace

import pytest

import sabnzbd
import sabnzbd.api as api
import sabnzbd.urlgrabber
from sabnzbd.constants import AddNzbFileResult
from sabnzbd.downloader import Server
from sabnzbd.nzb import NzbObject
from sabnzbd.nzbqueue import NzbQueue
from tests.test_nzbqueue import make_dummy_nzo
from tests.testhelper import SAB_NEWSSERVER_HOST, SAB_NEWSSERVER_PORT


@pytest.fixture()
def nzbqueue_env(monkeypatch, mocker, tmp_path):
    sabnzbd.Scheduler = mocker.Mock()
    sabnzbd.Scheduler.analyse = mocker.Mock(return_value=False)
    sabnzbd.ArticleCache = mocker.Mock()
    sabnzbd.Assembler = mocker.Mock()
    sabnzbd.BPSMeter = mocker.Mock()
    sabnzbd.Downloader = SimpleNamespace(paused=False)
    sabnzbd.Downloader.servers = [
        Server(
            server_id="testserver1",
            displayname="testserver1",
            host=SAB_NEWSSERVER_HOST,
            port=SAB_NEWSSERVER_PORT,
            timeout=30,
            threads=8,
            priority=0,
            use_ssl=False,
            ssl_verify=3,
            ssl_ciphers="",
            pipelining_requests=mocker.Mock(return_value=1),
        )
    ]
    monkeypatch.setattr(sabnzbd.cfg.admin_dir, "get_path", lambda: str(tmp_path))
    monkeypatch.setattr(sabnzbd.cfg.download_dir, "get_path", lambda: str(tmp_path))

    yield

    del sabnzbd.Downloader
    del sabnzbd.BPSMeter
    del sabnzbd.Assembler
    del sabnzbd.ArticleCache
    del sabnzbd.Scheduler


class TestOdinApiHelpers:
    def test_odin_info_from_kwargs_empty(self):
        assert api._odin_info_from_kwargs({}) == {}

    def test_odin_info_from_kwargs_both_ids(self):
        info = api._odin_info_from_kwargs(
            {
                "odin_download_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
                "odin_target_id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
            }
        )
        assert info == {
            "odin_download_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
            "odin_target_id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
        }

    def test_odin_info_from_kwargs_list_value(self):
        info = api._odin_info_from_kwargs({"odin_download_id": ["download-id"]})
        assert info == {"odin_download_id": "download-id"}

    def test_odin_slot_fields(self):
        nzo = NzbObject("test")
        nzo.nzo_info = {
            "odin_download_id": "dl-1",
            "odin_target_id": "tg-1",
        }
        assert api._odin_slot_fields(nzo) == {
            "odin_download_id": "dl-1",
            "odin_target_id": "tg-1",
        }


class TestOdinApiAddUrl:
    def test_addurl_passes_odin_info(self, mocker):
        add_url = mocker.patch(
            "sabnzbd.api.sabnzbd.urlgrabber.add_url",
            return_value=(AddNzbFileResult.OK, ["SABnzbd_nzo_test"]),
        )
        api._api_addurl(
            "http://example.com/test.nzb",
            {
                "odin_download_id": "dl-1",
                "odin_target_id": "tg-1",
            },
        )
        add_url.assert_called_once()
        assert add_url.call_args.kwargs["nzo_info"] == {
            "odin_download_id": "dl-1",
            "odin_target_id": "tg-1",
        }


class TestOdinUrlGrabber:
    def test_add_url_stores_odin_info(self, mocker):
        captured = []

        def capture_add(nzo):
            captured.append(nzo)
            return nzo.nzo_id

        mock_queue = mocker.Mock()
        mock_queue.add.side_effect = capture_add
        sabnzbd.NzbQueue = mock_queue
        sabnzbd.URLGrabber = mocker.Mock()

        sabnzbd.urlgrabber.add_url(
            "http://example.com/test.nzb",
            nzo_info={
                "odin_download_id": "dl-1",
                "odin_target_id": "tg-1",
            },
        )

        assert len(captured) == 1
        assert captured[0].nzo_info["odin_download_id"] == "dl-1"
        assert captured[0].nzo_info["odin_target_id"] == "tg-1"


@pytest.mark.usefixtures("nzbqueue_env")
class TestOdinQueuePersistence:
    def test_nzo_info_survives_save_and_restore(self):
        q = NzbQueue()
        nzo = make_dummy_nzo("odin", files=1, articles=1)
        nzo.nzo_info = {
            "odin_download_id": "dl-1",
            "odin_target_id": "tg-1",
        }
        q.add(nzo)
        q.save()

        q = NzbQueue()
        q.read_queue(0)
        restored = q.get_nzo(nzo.nzo_id)
        assert restored.nzo_info["odin_download_id"] == "dl-1"
        assert restored.nzo_info["odin_target_id"] == "tg-1"


class TestOdinBuildQueue:
    def test_build_queue_includes_odin_fields(self, mocker):
        nzo = make_dummy_nzo("odin", files=1, articles=1)
        nzo.nzo_info = {
            "odin_download_id": "dl-1",
            "odin_target_id": "tg-1",
        }

        mock_queue = mocker.Mock()
        mock_queue.queue_info.return_value = (nzo.bytes, nzo.remaining, 0, [nzo], 1, 1)
        sabnzbd.NzbQueue = mock_queue
        sabnzbd.BPSMeter = SimpleNamespace(bps=0, nzo_bps={str(nzo.nzo_id): 1024 * 75}, nzo_cached_amount={})
        sabnzbd.Downloader = SimpleNamespace(paused=False, paused_for_postproc=False)

        mocker.patch("sabnzbd.api.build_header", return_value={})

        queue = api.build_queue()
        assert queue["slots"][0]["odin_download_id"] == "dl-1"
        assert queue["slots"][0]["odin_target_id"] == "tg-1"

    def test_build_queue_slot_kbpersec_zero_when_not_downloading(self, mocker):
        nzo = make_dummy_nzo("odin", files=1, articles=1)
        nzo.status = "Paused"
        mock_queue = mocker.Mock()
        mock_queue.queue_info.return_value = (nzo.bytes, nzo.remaining, 0, [nzo], 1, 1)
        sabnzbd.NzbQueue = mock_queue
        sabnzbd.BPSMeter = SimpleNamespace(
            bps=1024 * 100,
            nzo_bps={str(nzo.nzo_id): 1024 * 75},
            nzo_cached_amount={},
        )
        sabnzbd.Downloader = SimpleNamespace(paused=True, paused_for_postproc=False)
        mocker.patch("sabnzbd.api.build_header", return_value={})

        queue = api.build_queue()
        assert queue["slots"][0]["kbpersec"] == "0.00"


class TestOdinHistoryPersistence:
    def test_history_db_persists_odin_ids(self, tmp_path):
        import sabnzbd.database as database
        from sabnzbd.constants import Status

        db_path = tmp_path / "history.sab"
        database.HistoryDB.db_path = str(db_path)
        history_db = database.HistoryDB()

        nzo = make_dummy_nzo("odin", files=1, articles=1)
        nzo.nzo_id = "SABnzbd_nzo_odin_hist"
        nzo.status = Status.COMPLETED
        nzo.nzo_info = {
            "odin_download_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
            "odin_target_id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
        }
        history_db.add_history_db(nzo, "/completed/movie.mkv", 12, "", "")

        items, _ = history_db.fetch_history(nzo_ids=[nzo.nzo_id])
        assert len(items) == 1
        assert items[0]["odin_download_id"] == "f47ac10b-58cc-4372-a567-0e02b2c3d479"
        assert items[0]["odin_target_id"] == "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
        assert items[0]["meta"] is None
