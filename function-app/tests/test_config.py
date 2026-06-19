import os
import pytest
from src.config import Config


def _set_required(overrides: dict = None):
    base = {
        "KQL_QUERY": "DeviceEvents | limit 10",
        "SHAREPOINT_SITE_ID": "site-id",
        "SHAREPOINT_DRIVE_ID": "drive-id",
        "SHAREPOINT_PARENT_FOLDER_ID": "root",
    }
    if overrides:
        base.update(overrides)
    return base


def test_from_env_succeeds_with_all_required(monkeypatch):
    for k, v in _set_required().items():
        monkeypatch.setenv(k, v)
    config = Config.from_env()
    assert config.kql_query == "DeviceEvents | limit 10"
    assert config.sharepoint_site_id == "site-id"
    assert config.graph_scope == "https://graph.microsoft.com/.default"


def test_from_env_raises_on_missing_required(monkeypatch):
    monkeypatch.delenv("KQL_QUERY", raising=False)
    monkeypatch.setenv("SHAREPOINT_SITE_ID", "x")
    monkeypatch.setenv("SHAREPOINT_DRIVE_ID", "x")
    monkeypatch.setenv("SHAREPOINT_PARENT_FOLDER_ID", "x")
    with pytest.raises(EnvironmentError, match="KQL_QUERY"):
        Config.from_env()


def test_from_env_uses_custom_graph_scope(monkeypatch):
    for k, v in _set_required().items():
        monkeypatch.setenv(k, v)
    monkeypatch.setenv("GRAPH_API_SCOPE", "https://graph.microsoft.com/custom")
    config = Config.from_env()
    assert config.graph_scope == "https://graph.microsoft.com/custom"
