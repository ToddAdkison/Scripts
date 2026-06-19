import os
from dataclasses import dataclass, field


@dataclass
class Config:
    kql_query: str
    sharepoint_site_id: str
    sharepoint_drive_id: str
    sharepoint_parent_folder_id: str
    graph_scope: str = "https://graph.microsoft.com/.default"
    timer_schedule: str = field(default="")

    @classmethod
    def from_env(cls) -> "Config":
        required = [
            "KQL_QUERY",
            "SHAREPOINT_SITE_ID",
            "SHAREPOINT_DRIVE_ID",
            "SHAREPOINT_PARENT_FOLDER_ID",
        ]
        missing = [k for k in required if not os.getenv(k)]
        if missing:
            raise EnvironmentError(f"Missing required app settings: {missing}")

        return cls(
            kql_query=os.environ["KQL_QUERY"],
            sharepoint_site_id=os.environ["SHAREPOINT_SITE_ID"],
            sharepoint_drive_id=os.environ["SHAREPOINT_DRIVE_ID"],
            sharepoint_parent_folder_id=os.environ["SHAREPOINT_PARENT_FOLDER_ID"],
            graph_scope=os.getenv("GRAPH_API_SCOPE", "https://graph.microsoft.com/.default"),
            timer_schedule=os.getenv("TIMER_SCHEDULE", ""),
        )
