from unittest.mock import MagicMock, patch

from src.config import Config
from src.sharepoint_client import SharePointClient


def _make_config():
    return Config(
        kql_query="DeviceEvents | limit 1",
        sharepoint_site_id="site-id",
        sharepoint_drive_id="drive-id",
        sharepoint_parent_folder_id="root",
    )


def _make_credential():
    cred = MagicMock()
    cred.get_token.return_value = MagicMock(token="fake-token")
    return cred


def test_upload_csv_calls_put_and_returns_filename():
    rows = [{"DeviceName": "pc01", "ActionType": "logon"}]
    resp = MagicMock()
    resp.status_code = 201
    resp.raise_for_status = MagicMock()
    resp.json.return_value = {"webUrl": "https://contoso.sharepoint.com/file.csv"}

    with patch("src.sharepoint_client.requests.put", return_value=resp) as mock_put:
        client = SharePointClient(_make_credential(), _make_config())
        filename = client.upload_csv(rows)

    assert filename.startswith("defender-report-")
    assert filename.endswith(".csv")
    mock_put.assert_called_once()
    _, kwargs = mock_put.call_args
    assert kwargs["headers"]["Content-Type"] == "text/csv"


def test_rows_to_csv_bytes_includes_bom():
    rows = [{"A": "1", "B": "2"}]
    result = SharePointClient._rows_to_csv_bytes(rows)
    # utf-8-sig BOM starts with \xef\xbb\xbf
    assert result[:3] == b"\xef\xbb\xbf"
    assert b"A,B" in result
    assert b"1,2" in result


def test_rows_to_csv_bytes_empty():
    assert SharePointClient._rows_to_csv_bytes([]) == b""
