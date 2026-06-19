import csv
import io
import logging
from datetime import datetime, timezone

import requests
from azure.identity import DefaultAzureCredential

from src.config import Config


class SharePointClient:
    def __init__(self, credential: DefaultAzureCredential, config: Config) -> None:
        self._credential = credential
        self._scope = config.graph_scope
        self._site_id = config.sharepoint_site_id
        self._drive_id = config.sharepoint_drive_id
        self._parent_folder_id = config.sharepoint_parent_folder_id

    def _get_token(self) -> str:
        return self._credential.get_token(self._scope).token

    def upload_csv(self, rows: list[dict]) -> str:
        filename = f"defender-report-{datetime.now(timezone.utc).strftime('%Y-%m-%d')}.csv"
        csv_bytes = self._rows_to_csv_bytes(rows)

        url = (
            f"https://graph.microsoft.com/v1.0"
            f"/sites/{self._site_id}"
            f"/drives/{self._drive_id}"
            f"/items/{self._parent_folder_id}:/{filename}:/content"
        )

        headers = {
            "Authorization": f"Bearer {self._get_token()}",
            "Content-Type": "text/csv",
        }

        response = requests.put(url, headers=headers, data=csv_bytes, timeout=60)
        response.raise_for_status()

        item = response.json()
        web_url = item.get("webUrl", "(no URL returned)")
        logging.info(
            "Uploaded %s (%d bytes) to SharePoint: %s",
            filename,
            len(csv_bytes),
            web_url,
        )
        return filename

    @staticmethod
    def _rows_to_csv_bytes(rows: list[dict]) -> bytes:
        if not rows:
            return b""
        output = io.StringIO()
        writer = csv.DictWriter(output, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
        # utf-8-sig adds BOM so Excel opens the file correctly without encoding prompts
        return output.getvalue().encode("utf-8-sig")
