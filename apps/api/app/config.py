from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[3]
TERRAFORM_DIR = ROOT_DIR / "infra" / "terraform"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


DEFAULT_STATE = {
    "loadBalancer": {
        "name": "sre-playground-lb",
        "status": "idle",
        "endpoint": None,
        "type": "external-http",
    },
    "traffic": {
        "blue": 100,
        "green": 0,
        "active": "blue",
    },
    "services": [
        {
            "id": "blue",
            "name": "sre-playground-blue",
            "status": "serving",
            "version": "blue",
            "url": None,
            "weight": 100,
            "color": "blue",
        },
        {
            "id": "green",
            "name": "sre-playground-green",
            "status": "standby",
            "version": "green",
            "url": None,
            "weight": 0,
            "color": "green",
        },
    ],
    "rollout": {
        "phase": "idle",
        "progress": 0,
        "message": "awaiting deployment activity",
    },
    "requestProbe": {
        "status": "idle",
        "target": "unknown",
        "observedColor": None,
        "observedVersion": None,
        "statusCode": None,
        "latencyMs": None,
        "lastCheckedAt": None,
        "samplePath": None,
        "error": None,
    },
    "settings": {
        "probeIntervalSeconds": 5.0,
        "readOnly": False,
    },
    "meta": {
        "source": "default",
        "terraformStateAvailable": False,
        "lastUpdatedAt": utc_now(),
        "demoMode": False,
    },
}
