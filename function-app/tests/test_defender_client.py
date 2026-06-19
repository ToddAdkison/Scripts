from unittest.mock import MagicMock, patch
import pytest
import requests

from src.defender_client import DefenderClient


def _make_credential():
    cred = MagicMock()
    cred.get_token.return_value = MagicMock(token="fake-token")
    return cred


def _make_graph_response(rows: list[dict], schema: list[dict] = None):
    if schema is None and rows:
        schema = [{"Name": k, "Type": "string"} for k in rows[0].keys()]
    resp = MagicMock()
    resp.status_code = 200
    resp.json.return_value = {"Schema": schema or [], "Results": rows}
    resp.raise_for_status = MagicMock()
    return resp


def test_run_hunting_query_returns_rows():
    rows = [{"DeviceName": "pc01", "ActionType": "logon"}]
    cred = _make_credential()
    with patch("src.defender_client.requests.post", return_value=_make_graph_response(rows)):
        client = DefenderClient(cred, "https://graph.microsoft.com/.default")
        result = client.run_hunting_query("DeviceEvents | limit 1")
    assert result == rows


def test_run_hunting_query_returns_empty_list():
    cred = _make_credential()
    resp = _make_graph_response([], schema=[])
    with patch("src.defender_client.requests.post", return_value=resp):
        client = DefenderClient(cred, "https://graph.microsoft.com/.default")
        result = client.run_hunting_query("DeviceEvents | limit 0")
    assert result == []


def test_run_hunting_query_retries_on_429():
    cred = _make_credential()
    throttled = MagicMock()
    throttled.status_code = 429
    throttled.headers = {"Retry-After": "0"}

    success = _make_graph_response([{"col": "val"}])

    with patch("src.defender_client.requests.post", side_effect=[throttled, success]):
        with patch("src.defender_client.time.sleep"):
            client = DefenderClient(cred, "https://graph.microsoft.com/.default")
            result = client.run_hunting_query("DeviceEvents | limit 1")

    assert len(result) == 1


def test_run_hunting_query_raises_on_4xx():
    cred = _make_credential()
    resp = MagicMock()
    resp.status_code = 403
    resp.raise_for_status.side_effect = requests.HTTPError("403 Forbidden")
    with patch("src.defender_client.requests.post", return_value=resp):
        client = DefenderClient(cred, "https://graph.microsoft.com/.default")
        with pytest.raises(requests.HTTPError):
            client.run_hunting_query("DeviceEvents | limit 1")
