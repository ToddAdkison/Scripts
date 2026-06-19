import logging

import azure.functions as func
from azure.identity import DefaultAzureCredential

from src.config import Config
from src.defender_client import DefenderClient
from src.sharepoint_client import SharePointClient

app = func.FunctionApp()


@app.timer_trigger(
    schedule="%TIMER_SCHEDULE%",
    arg_name="timer",
    run_on_startup=False,
    use_monitor=True,
)
def defender_to_sharepoint(timer: func.TimerRequest) -> None:
    if timer.past_due:
        logging.warning("Timer is past_due — running late")

    logging.info("Defender XDR to SharePoint function started")

    config = Config.from_env()
    credential = DefaultAzureCredential()

    defender = DefenderClient(credential, config.graph_scope)
    rows = defender.run_hunting_query(config.kql_query)

    if not rows:
        logging.warning("KQL query returned no results — skipping SharePoint upload")
        return

    sp = SharePointClient(credential, config)
    filename = sp.upload_csv(rows)

    logging.info("Function completed successfully. File: %s, Rows: %d", filename, len(rows))
