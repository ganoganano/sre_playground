from __future__ import annotations

import json
import os
from asyncio import Task, create_task, sleep, to_thread
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi import HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from .state import (
    build_infra_state,
    fetch_probe_agent_settings,
    load_runtime_config,
    update_probe_agent_settings,
    with_probe,
)
from .terraform_runner import TerraformRunner


runner = TerraformRunner()
runtime = load_runtime_config()
probe_agent_url = runtime["probe_agent_url"]
probe_interval_seconds = 5.0
runtime_state = build_infra_state(probe_interval_seconds=probe_interval_seconds, include_probe=False)
FULL_STATE_REFRESH_SECONDS = 5.0
refresh_task: Task[None] | None = None
demo_mode = os.environ.get("DEMO_MODE", "").lower() in {"1", "true", "yes", "on"}
DEMO_MODE_PROBE_INTERVAL_SECONDS = 1.0

if demo_mode:
    probe_interval_seconds = DEMO_MODE_PROBE_INTERVAL_SECONDS
    runtime_state["settings"]["probeIntervalSeconds"] = probe_interval_seconds


class DeployRequest(BaseModel):
    blue_weight: int = Field(ge=0, le=100, default=0)
    green_weight: int = Field(ge=0, le=100, default=100)


class ProbeSettings(BaseModel):
    probe_interval_seconds: float = Field(
        alias="probeIntervalSeconds",
        ge=0.1,
        le=10.0,
        default=5.0,
    )


async def refresh_runtime_state_loop() -> None:
    global runtime_state, probe_interval_seconds
    while True:
        runtime_state = await to_thread(
            build_infra_state,
            load_balancer_status=runtime_state["loadBalancer"]["status"],
            rollout_phase=runtime_state["rollout"]["phase"],
            rollout_progress=runtime_state["rollout"]["progress"],
            rollout_message=runtime_state["rollout"]["message"],
            probe_interval_seconds=probe_interval_seconds,
            include_probe=False,
        )
        await sleep(FULL_STATE_REFRESH_SECONDS)


@asynccontextmanager
async def lifespan(_: FastAPI):
    global refresh_task
    if demo_mode:
        await to_thread(
            update_probe_agent_settings,
            probe_agent_url,
            interval_seconds=DEMO_MODE_PROBE_INTERVAL_SECONDS,
        )
    refresh_task = create_task(refresh_runtime_state_loop())
    try:
        yield
    finally:
        if refresh_task is not None:
            refresh_task.cancel()


app = FastAPI(title="SRE Playground API", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.get("/api/state")
async def state() -> dict:
    global runtime_state, probe_interval_seconds, probe_agent_url
    stream_state = await to_thread(with_probe, runtime_state, probe_agent_url)
    probe_interval_seconds = (
        DEMO_MODE_PROBE_INTERVAL_SECONDS
        if demo_mode
        else stream_state["settings"]["probeIntervalSeconds"]
    )
    stream_state["settings"]["probeIntervalSeconds"] = probe_interval_seconds
    stream_state["settings"]["readOnly"] = demo_mode
    stream_state["meta"]["demoMode"] = demo_mode
    runtime_state["requestProbe"] = stream_state["requestProbe"]
    runtime_state["settings"]["probeIntervalSeconds"] = probe_interval_seconds
    runtime_state["settings"]["readOnly"] = demo_mode
    runtime_state["meta"]["lastUpdatedAt"] = stream_state["meta"]["lastUpdatedAt"]
    runtime_state["meta"]["demoMode"] = demo_mode
    return stream_state


@app.get("/api/settings")
async def settings() -> dict:
    global probe_interval_seconds, probe_agent_url, runtime_state
    if demo_mode:
        probe_interval_seconds = DEMO_MODE_PROBE_INTERVAL_SECONDS
        runtime_state["settings"]["probeIntervalSeconds"] = probe_interval_seconds
        return {"probeIntervalSeconds": probe_interval_seconds, "readOnly": True}
    agent_settings = await to_thread(fetch_probe_agent_settings, probe_agent_url)
    if agent_settings and "probeIntervalSeconds" in agent_settings:
        probe_interval_seconds = agent_settings["probeIntervalSeconds"]
        runtime_state["settings"]["probeIntervalSeconds"] = probe_interval_seconds
    return {"probeIntervalSeconds": probe_interval_seconds, "readOnly": demo_mode}


@app.post("/api/settings")
async def update_settings(payload: ProbeSettings) -> dict:
    global probe_interval_seconds, runtime_state, probe_agent_url
    if demo_mode:
        probe_interval_seconds = DEMO_MODE_PROBE_INTERVAL_SECONDS
        runtime_state["settings"]["probeIntervalSeconds"] = probe_interval_seconds
        raise HTTPException(status_code=403, detail="settings are locked in demo mode at 1.0 seconds")
    agent_settings = await to_thread(
        update_probe_agent_settings,
        probe_agent_url,
        interval_seconds=payload.probe_interval_seconds,
    )
    if not agent_settings or "probeIntervalSeconds" not in agent_settings:
        raise HTTPException(status_code=502, detail="failed to update probe-agent settings")
    probe_interval_seconds = agent_settings["probeIntervalSeconds"]
    runtime_state["settings"]["probeIntervalSeconds"] = probe_interval_seconds
    return {"probeIntervalSeconds": probe_interval_seconds, "readOnly": demo_mode}


@app.get("/api/state/stream")
async def state_stream() -> StreamingResponse:
    async def event_stream():
        global runtime_state, probe_interval_seconds, probe_agent_url
        last_probe_checked_at: str | None = None
        while True:
            stream_state = await to_thread(with_probe, runtime_state, probe_agent_url)
            probe_interval_seconds = (
                DEMO_MODE_PROBE_INTERVAL_SECONDS
                if demo_mode
                else stream_state["settings"]["probeIntervalSeconds"]
            )
            stream_state["settings"]["probeIntervalSeconds"] = probe_interval_seconds
            stream_state["settings"]["readOnly"] = demo_mode
            stream_state["meta"]["demoMode"] = demo_mode
            runtime_state["requestProbe"] = stream_state["requestProbe"]
            runtime_state["settings"]["probeIntervalSeconds"] = probe_interval_seconds
            runtime_state["settings"]["readOnly"] = demo_mode
            runtime_state["meta"]["lastUpdatedAt"] = stream_state["meta"]["lastUpdatedAt"]
            runtime_state["meta"]["demoMode"] = demo_mode

            probe = stream_state.get("requestProbe", {})
            probe_checked_at = probe.get("lastCheckedAt")
            if (
                probe_checked_at
                and probe_checked_at != last_probe_checked_at
                and probe.get("status") == "ok"
            ):
                last_probe_checked_at = probe_checked_at
                yield (
                    "event: probe\n"
                    f"data: {json.dumps(probe, ensure_ascii=False)}\n\n"
                )
            yield (
                "event: state\n"
                f"data: {json.dumps(stream_state, ensure_ascii=False)}\n\n"
            )
            await sleep(probe_interval_seconds)

    return StreamingResponse(event_stream(), media_type="text/event-stream")


@app.post("/api/deploy")
async def deploy(payload: DeployRequest) -> StreamingResponse:
    if demo_mode:
        raise HTTPException(status_code=403, detail="deploy is locked in demo mode")

    async def event_stream():
        global runtime_state, probe_interval_seconds
        async for event in runner.stream_apply(
            blue_weight=payload.blue_weight,
            green_weight=payload.green_weight,
        ):
            if event["event"] == "status":
                runtime_state["rollout"]["phase"] = event["data"].get(
                    "phase", runtime_state["rollout"]["phase"]
                )
                runtime_state["rollout"]["progress"] = event["data"].get(
                    "progress", runtime_state["rollout"]["progress"]
                )
                runtime_state["rollout"]["message"] = event["data"].get(
                    "message", runtime_state["rollout"]["message"]
                )
            if event["event"] == "state":
                event["data"]["settings"]["probeIntervalSeconds"] = probe_interval_seconds
                runtime_state = event["data"]
            yield (
                f"event: {event['event']}\n"
                f"data: {json.dumps(event['data'], ensure_ascii=False)}\n\n"
            )

    return StreamingResponse(event_stream(), media_type="text/event-stream")
