"""Constants for the Fizzlayer Home Assistant integration."""

import json
from pathlib import Path

DOMAIN = "fizzlayer"
# Shown on the code step and in the log, and it matches manifest.json so a
# running install can be told apart from the 1.0.0 build.
INTEGRATION_VERSION = json.loads(
    (Path(__file__).parent / "manifest.json").read_text(encoding="utf-8")
)["version"]
DEFAULT_BASE_URL = "https://fizzlayer.com"
MY_HOME_ASSISTANT_URL = "https://my.home-assistant.io/redirect/config_flow_start?domain=fizzlayer"

# State changes for one entity are coalesced, then a heartbeat resends the last
# value so a silence alert still sees the sensor. The minimum silence window is
# one minute and the scheduler runs about once a minute, so the heartbeat is
# shorter than that window.
MIN_CHANGE_SECONDS = 10
HEARTBEAT_SECONDS = 30
FLUSH_SECONDS = 2
MAX_BATCH = 40
MAX_BUFFER = 500

POLL_INTERVAL = 3
POLL_ATTEMPTS = 100

DEFAULT_DEVICE_CLASSES = frozenset(
    {
        "temperature",
        "humidity",
        "power",
        "energy",
        "battery",
        "door",
        "window",
        "opening",
        "garage_door",
        "moisture",
        "gas",
        "carbon_monoxide",
        "safety",
        "plug",
        "outlet",
    }
)
