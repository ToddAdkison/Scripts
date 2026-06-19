import logging
import time

import requests
from azure.identity import DefaultAzureCredential

GRAPH_HUNTING_URL = "https://graph.microsoft.com/v1.0/security/runHuntingQuery"
_RETRY_WAITS = [2, 4, 8]
_RETRYABLE_STATUSES = {429, 503}


class DefenderClient:
    def __init__(self, credential: DefaultAzureCredential, scope: str) -> None:
        self._credential = credential
        self._scope = scope

    def _get_token(self) -> str:
        return self._credential.get_token(self._scope).token

    def run_hunting_query(self, kql_query: str) -> list[dict]:
        headers = {
            "Authorization": f"Bearer {self._get_token()}",
            "Content-Type": "application/json",
        }
        body = {"Query": kql_query}
        response = None

        for attempt, wait in enumerate(_RETRY_WAITS):
            response = requests.post(
                GRAPH_HUNTING_URL, headers=headers, json=body, timeout=60
            )
            if response.status_code in _RETRYABLE_STATUSES:
                retry_after = int(response.headers.get("Retry-After", wait))
                logging.warning(
                    "Graph API returned %d — retrying in %ds (attempt %d/%d)",
                    response.status_code,
                    retry_after,
                    attempt + 1,
                    len(_RETRY_WAITS),
                )
                time.sleep(retry_after)
                headers["Authorization"] = f"Bearer {self._get_token()}"
                continue
            break

        response.raise_for_status()
        data = response.json()

        schema = data.get("Schema", [])
        results = data.get("Results", [])

        column_names = [col["Name"] for col in schema]
        logging.info(
            "Defender Advanced Hunting returned %d rows with columns: %s",
            len(results),
            column_names,
        )

        # Results already come back as a list of dicts keyed by column name
        return results
