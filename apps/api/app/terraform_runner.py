from __future__ import annotations

import asyncio
import json
import shutil
from asyncio.subprocess import PIPE
from pathlib import Path
from typing import AsyncIterator

from .config import TERRAFORM_DIR
from .state import build_infra_state, load_runtime_config


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
        runtime = load_runtime_config()
        if not runtime["project_id"]:
            yield self._event(
                "error",
                {
                    "phase": "failed",
                    "message": "PROJECT_ID is not set in .sre_playground.env",
                },
            )
            return

        command = [
            "terraform",
            "apply",
            "-json",
            "-auto-approve",
            f"-var=project_id={runtime['project_id']}",
            f"-var=region={runtime['region']}",
            f"-var=service_name={runtime['service_name']}",
            f"-var=container_image_blue={runtime['blue_image']}",
            f"-var=container_image_green={runtime['green_image']}",
            f"-var=otel_exporter_otlp_traces_endpoint={runtime['otel_exporter_otlp_traces_endpoint']}",
            f"-var=otel_environment={runtime['otel_environment']}",
            f"-var=green_extra_latency_ms={runtime['green_extra_latency_ms']}",
            f"-var=app_error_rate={runtime['app_error_rate']}",
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
                "message": "terraform apply -json started",
                "progress": 15,
            },
        )

        queue: asyncio.Queue[dict | None] = asyncio.Queue()

        async def read_stdout(stream):
            while True:
                line = await stream.readline()
                if not line:
                    break
                text = line.decode("utf-8", errors="replace").rstrip()
                if text:
                    await queue.put(
                        self._event("log", {"channel": "stdout", "message": text})
                    )
                    parsed = self._parse_terraform_json_line(text)
                    if parsed is not None:
                        await queue.put(parsed)
            await queue.put(None)

        async def read_stderr(stream):
            while True:
                line = await stream.readline()
                if not line:
                    break
                text = line.decode("utf-8", errors="replace").rstrip()
                if text:
                    await queue.put(
                        self._event("log", {"channel": "stderr", "message": text})
                    )
            await queue.put(None)

        stdout_task = asyncio.create_task(read_stdout(process.stdout))
        stderr_task = asyncio.create_task(read_stderr(process.stderr))
        completed_readers = 0

        while completed_readers < 2:
            event = await queue.get()
            if event is None:
                completed_readers += 1
                continue
            yield event

        await stdout_task
        await stderr_task

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
            build_infra_state(
                blue_weight=blue_weight,
                green_weight=green_weight,
                load_balancer_status="serving",
                rollout_phase="completed",
                rollout_progress=100,
                rollout_message="terraform apply completed",
            ),
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
            build_infra_state(
                blue_weight=blue_weight,
                green_weight=green_weight,
                load_balancer_status="serving",
                rollout_phase="completed",
                rollout_progress=100,
                rollout_message="mock deployment completed",
            ),
        )
        yield self._event(
            "status",
            {
                "phase": "completed",
                "message": "mock deployment completed",
                "progress": 100,
            },
        )

    @staticmethod
    def _event(event: str, data: dict) -> dict:
        return {"event": event, "data": data}

    def _parse_terraform_json_line(self, line: str) -> dict | None:
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            return None

        event_type = payload.get("type", "")
        message = payload.get("message") or payload.get("@message") or event_type

        progress_map = {
            "version": 10,
            "planned_change": 30,
            "change_summary": 45,
            "apply_start": 60,
            "apply_progress": 75,
            "apply_complete": 90,
            "outputs": 95,
        }
        progress = progress_map.get(event_type, 20)

        if event_type in {"diagnostic", "apply_errored"}:
            return self._event(
                "error",
                {
                    "phase": "failed",
                    "message": message,
                },
            )

        return self._event(
            "status",
            {
                "phase": event_type,
                "message": message,
                "progress": progress,
            },
        )
