from __future__ import annotations

import json
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from .config import DEFAULT_STATE
from .terraform_runner import TerraformRunner


runner = TerraformRunner()
runtime_state = json.loads(json.dumps(DEFAULT_STATE))


class DeployRequest(BaseModel):
    blue_weight: int = Field(ge=0, le=100, default=0)
    green_weight: int = Field(ge=0, le=100, default=100)


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield


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
    return runtime_state


@app.post("/api/deploy")
async def deploy(payload: DeployRequest) -> StreamingResponse:
    async def event_stream():
        global runtime_state
        async for event in runner.stream_apply(
            blue_weight=payload.blue_weight,
            green_weight=payload.green_weight,
        ):
            if event["event"] == "state":
                runtime_state = event["data"]
            yield (
                f"event: {event['event']}\n"
                f"data: {json.dumps(event['data'], ensure_ascii=False)}\n\n"
            )

    return StreamingResponse(event_stream(), media_type="text/event-stream")
