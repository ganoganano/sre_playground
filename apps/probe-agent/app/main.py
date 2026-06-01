from __future__ import annotations

import asyncio
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import asynccontextmanager
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class ProbeSettingsState:
    target_url: str
    interval_seconds: float
    timeout_seconds: float


def load_settings() -> ProbeSettingsState:
    return ProbeSettingsState(
        target_url=os.environ.get("PROBE_TARGET_URL", "http://example.com"),
        interval_seconds=float(os.environ.get("PROBE_INTERVAL_SECONDS", "5.0")),
        timeout_seconds=float(os.environ.get("PROBE_TIMEOUT_SECONDS", "5.0")),
    )


settings_state = load_settings()
latest_probe: dict[str, Any] = {
    "status": "idle",
    "target": "unknown",
    "observedColor": None,
    "observedVersion": None,
    "statusCode": None,
    "latencyMs": None,
    "lastCheckedAt": None,
    "samplePath": None,
    "error": None,
    "agent": "probe-agent",
}
probe_task: asyncio.Task[None] | None = None
demo_mode = os.environ.get("DEMO_MODE", "").lower() in {"1", "true", "yes", "on"}


class ProbeSettingsPayload(BaseModel):
    target_url: str | None = Field(default=None, alias="targetUrl")
    interval_seconds: float | None = Field(
        default=None,
        alias="probeIntervalSeconds",
        ge=0.1,
        le=10.0,
    )
    timeout_seconds: float | None = Field(
        default=None,
        alias="timeoutSeconds",
        ge=0.1,
        le=30.0,
    )


def classify_target(payload: dict[str, Any]) -> str:
    observed = payload.get("color")
    if observed in {"blue", "green"}:
        return observed
    return "unknown"


def probe_once(target_url: str, timeout_seconds: float) -> dict[str, Any]:
    sample_path = f"/?probe={int(time.time() * 1000)}"
    probe_url = urllib.parse.urljoin(target_url.rstrip("/") + "/", sample_path.lstrip("/"))
    started = time.perf_counter()
    checked_at = utc_now()

    try:
        with urllib.request.urlopen(probe_url, timeout=timeout_seconds) as response:
            latency_ms = round((time.perf_counter() - started) * 1000, 1)
            payload = json.loads(response.read().decode("utf-8"))
            return {
                "status": "ok",
                "target": classify_target(payload),
                "observedColor": payload.get("color"),
                "observedVersion": payload.get("version"),
                "statusCode": response.status,
                "latencyMs": latency_ms,
                "lastCheckedAt": checked_at,
                "samplePath": payload.get("path") or sample_path,
                "error": None,
                "agent": "probe-agent",
            }
    except urllib.error.HTTPError as exc:
        latency_ms = round((time.perf_counter() - started) * 1000, 1)
        return {
            "status": "http_error",
            "target": "unknown",
            "observedColor": None,
            "observedVersion": None,
            "statusCode": exc.code,
            "latencyMs": latency_ms,
            "lastCheckedAt": checked_at,
            "samplePath": sample_path,
            "error": str(exc),
            "agent": "probe-agent",
        }
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ValueError) as exc:
        latency_ms = round((time.perf_counter() - started) * 1000, 1)
        return {
            "status": "failed",
            "target": "unknown",
            "observedColor": None,
            "observedVersion": None,
            "statusCode": None,
            "latencyMs": latency_ms,
            "lastCheckedAt": checked_at,
            "samplePath": sample_path,
            "error": str(exc),
            "agent": "probe-agent",
        }


async def probe_loop() -> None:
    global latest_probe
    while True:
        latest_probe = await asyncio.to_thread(
            probe_once,
            settings_state.target_url,
            settings_state.timeout_seconds,
        )
        await asyncio.sleep(settings_state.interval_seconds)


@asynccontextmanager
async def lifespan(_: FastAPI):
    global probe_task
    probe_task = asyncio.create_task(probe_loop())
    try:
        yield
    finally:
        if probe_task is not None:
            probe_task.cancel()


app = FastAPI(title="SRE Playground Probe Agent", lifespan=lifespan)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/settings")
async def get_settings() -> dict[str, Any]:
    return {
        "targetUrl": settings_state.target_url,
        "probeIntervalSeconds": settings_state.interval_seconds,
        "timeoutSeconds": settings_state.timeout_seconds,
        "readOnly": demo_mode,
    }


@app.post("/settings")
async def update_settings(payload: ProbeSettingsPayload) -> dict[str, Any]:
    if demo_mode:
        raise HTTPException(status_code=403, detail="settings are locked in demo mode")
    if payload.target_url is not None:
        settings_state.target_url = payload.target_url
    if payload.interval_seconds is not None:
        settings_state.interval_seconds = payload.interval_seconds
    if payload.timeout_seconds is not None:
        settings_state.timeout_seconds = payload.timeout_seconds
    return await get_settings()


@app.get("/latest")
async def get_latest() -> dict[str, Any]:
    return latest_probe


@app.get("/meta")
async def meta() -> dict[str, Any]:
    return {
        "agent": "probe-agent",
        "demoMode": demo_mode,
        "settings": asdict(settings_state),
        "startedAt": utc_now(),
    }
