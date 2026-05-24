from __future__ import annotations

import asyncio
import json
import shutil
from asyncio.subprocess import PIPE
from pathlib import Path
from typing import AsyncIterator

from .config import DEFAULT_STATE, TERRAFORM_DIR


class TerraformRunner:
    def __init__(self, terraform_dir: Path = TERRAFORM_DIR) -> None:
        self.terraform_dir = terraform_dir

    def terraform_available(self) -> bool:
        return shutil.which("terraform") is not None

    async def stream_apply(
        self, blue_weight: int, green_weight: int
    ) -> AsyncIterator[dict]:
        yield self._event(
            "status",
            {
                "phase": "queued",
                "message": "deployment requested",
                "progress": 5,
            },
        )

        if self.terraform_available():
            async for event in self._stream_real_apply(blue_weight, green_weight):
                yield event
            return

        async for event in self._stream_mock_apply(blue_weight, green_weight):
            yield event

    async def _stream_real_apply(
        self, blue_weight: int, green_weight: int
    ) -> AsyncIterator[dict]:
        command = [
            "terraform",
            "apply",
            "-auto-approve",
            f"-var=blue_weight={blue_weight}",
            f"-var=green_weight={green_weight}",
        ]

        process = await asyncio.create_subprocess_exec(
            *command,
            cwd=str(self.terraform_dir),
            stdout=PIPE,
            stderr=PIPE,
        )

        yield self._event(
            "status",
            {
                "phase": "applying",
                "message": "terraform apply started",
                "progress": 15,
            },
        )

        async def read_stream(stream, channel: str):
            while True:
                line = await stream.readline()
                if not line:
                    break
                text = line.decode("utf-8", errors="replace").rstrip()
                if text:
                    yield self._event("log", {"channel": channel, "message": text})

        async for event in read_stream(process.stdout, "stdout"):
            yield event

        async for event in read_stream(process.stderr, "stderr"):
            yield event

        return_code = await process.wait()
        if return_code != 0:
            yield self._event(
                "error",
                {
                    "phase": "failed",
                    "message": f"terraform apply failed with exit code {return_code}",
                },
            )
            return

        yield self._event(
            "state",
            self.build_state_payload(blue_weight, green_weight, status="serving"),
        )
        yield self._event(
            "status",
            {
                "phase": "completed",
                "message": "terraform apply completed",
                "progress": 100,
            },
        )

    async def _stream_mock_apply(
        self, blue_weight: int, green_weight: int
    ) -> AsyncIterator[dict]:
        mock_steps = [
            ("planning", "terraform binary not found, running mock deployment flow", 20),
            ("planning", "refreshing state", 35),
            ("applying", "updating backend weights", 60),
            ("applying", "waiting for rollout health checks", 85),
        ]

        for phase, message, progress in mock_steps:
            await asyncio.sleep(0.6)
            yield self._event(
                "status",
                {
                    "phase": phase,
                    "message": message,
                    "progress": progress,
                },
            )
            yield self._event(
                "log",
                {
                    "channel": "stdout",
                    "message": message,
                },
            )

        yield self._event(
            "state",
            self.build_state_payload(blue_weight, green_weight, status="serving"),
        )
        yield self._event(
            "status",
            {
                "phase": "completed",
                "message": "mock deployment completed",
                "progress": 100,
            },
        )

    def build_state_payload(
        self, blue_weight: int, green_weight: int, status: str
    ) -> dict:
        payload = json.loads(json.dumps(DEFAULT_STATE))
        payload["traffic"]["blue"] = blue_weight
        payload["traffic"]["green"] = green_weight
        payload["loadBalancer"]["status"] = status
        payload["services"][0]["status"] = "serving" if blue_weight > 0 else "standby"
        payload["services"][1]["status"] = "serving" if green_weight > 0 else "standby"
        return payload

    @staticmethod
    def _event(event: str, data: dict) -> dict:
        return {"event": event, "data": data}
