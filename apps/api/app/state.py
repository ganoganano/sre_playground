from __future__ import annotations

import json
import shutil
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from .config import DEFAULT_STATE, ROOT_DIR, utc_now


ENV_FILE = ROOT_DIR / ".sre_playground.env"


def _clone_default_state() -> dict:
    return json.loads(json.dumps(DEFAULT_STATE))


def _parse_env_file(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}

    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip("\"'")
    return values


def load_runtime_config() -> dict[str, str]:
    env = _parse_env_file(ENV_FILE)
    project_id = env.get("PROJECT_ID", "")
    region = env.get("REGION", "asia-northeast1")
    repository_name = env.get("REPOSITORY_NAME", "sre-playground")
    service_name = env.get("SERVICE_NAME", "sre-playground")
    blue_tag = env.get("BLUE_TAG", "blue")
    green_tag = env.get("GREEN_TAG", "green")
    probe_agent_url = env.get("PROBE_AGENT_URL", "http://localhost:8010")
    otel_collector_service_name = env.get("OTEL_COLLECTOR_SERVICE_NAME", "sre-playground-otel-collector")
    otel_collector_tag = env.get("OTEL_COLLECTOR_TAG", "latest")
    otel_exporter_otlp_endpoint = env.get("OTEL_EXPORTER_OTLP_ENDPOINT", "")
    otel_exporter_otlp_traces_endpoint = env.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "")
    otel_environment = env.get("OTEL_ENVIRONMENT", "demo")
    green_extra_latency_ms = env.get("GREEN_EXTRA_LATENCY_MS", "0")
    app_error_rate = env.get("APP_ERROR_RATE", "0")

    return {
        "project_id": project_id,
        "region": region,
        "repository_name": repository_name,
        "service_name": service_name,
        "blue_tag": blue_tag,
        "green_tag": green_tag,
        "blue_image": (
            f"{region}-docker.pkg.dev/{project_id}/{repository_name}/{service_name}:{blue_tag}"
            if project_id
            else ""
        ),
        "green_image": (
            f"{region}-docker.pkg.dev/{project_id}/{repository_name}/{service_name}:{green_tag}"
            if project_id
            else ""
        ),
        "probe_agent_url": probe_agent_url,
        "otel_collector_service_name": otel_collector_service_name,
        "otel_collector_tag": otel_collector_tag,
        "otel_exporter_otlp_endpoint": otel_exporter_otlp_endpoint,
        "otel_exporter_otlp_traces_endpoint": otel_exporter_otlp_traces_endpoint,
        "otel_environment": otel_environment,
        "green_extra_latency_ms": green_extra_latency_ms,
        "app_error_rate": app_error_rate,
    }


def _gcloud_available() -> bool:
    return shutil.which("gcloud") is not None


def _run_gcloud_json(args: list[str]) -> dict[str, Any] | None:
    if not _gcloud_available():
        return None

    result = subprocess.run(
        ["gcloud", *args, "--format=json"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def _condition_state(service_payload: dict[str, Any]) -> str:
    status_payload = service_payload.get("status", {})
    for condition in status_payload.get("conditions", []):
        if condition.get("type") != "Ready":
            continue
        if condition.get("status") == "True":
            return "ready"
        return "degraded"
    return "unknown"


def _service_url(service_payload: dict[str, Any]) -> str | None:
    status_payload = service_payload.get("status", {})
    return status_payload.get("url") or status_payload.get("address", {}).get("url")


def _weight_from_url_map(
    url_map_payload: dict[str, Any] | None,
    *,
    blue_backend_name: str,
    green_backend_name: str,
) -> tuple[int | None, int | None]:
    if not url_map_payload:
        return None, None

    weighted = (
        url_map_payload.get("defaultRouteAction", {}).get("weightedBackendServices", [])
    )
    blue_weight: int | None = None
    green_weight: int | None = None

    for backend in weighted:
        backend_service = backend.get("backendService", "")
        weight = backend.get("weight")
        if backend_service.endswith(f"/backendServices/{blue_backend_name}"):
            blue_weight = weight if isinstance(weight, int) else 0
        if backend_service.endswith(f"/backendServices/{green_backend_name}"):
            green_weight = weight if isinstance(weight, int) else 0

    return blue_weight, green_weight


def _normalize_weights(
    blue_weight: int | None, green_weight: int | None
) -> tuple[int | None, int | None]:
    if blue_weight is None and green_weight is None:
        return None, None

    if blue_weight is None:
        if green_weight is None:
            return None, None
        return max(0, 100 - green_weight), green_weight

    if green_weight is None:
        return blue_weight, max(0, 100 - blue_weight)

    total = blue_weight + green_weight
    if total <= 0:
        return 0, 0

    normalized_blue = round((blue_weight / total) * 100)
    normalized_green = 100 - normalized_blue
    return normalized_blue, normalized_green


def _request_json(
    url: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
    timeout: float = 5.0,
) -> dict[str, Any] | None:
    body = None
    headers: dict[str, str] = {}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError, ValueError):
        return None


def probe_unavailable(message: str) -> dict[str, Any]:
    return {
        "status": "unavailable",
        "target": "unknown",
        "observedColor": None,
        "observedVersion": None,
        "statusCode": None,
        "latencyMs": None,
        "lastCheckedAt": utc_now(),
        "samplePath": None,
        "error": message,
        "agent": "probe-agent",
    }


def fetch_probe_agent_latest(probe_agent_url: str) -> dict[str, Any]:
    payload = _request_json(urllib.parse.urljoin(probe_agent_url.rstrip("/") + "/", "latest"))
    if payload is None:
        return probe_unavailable("probe-agent latest endpoint is unavailable")
    payload.setdefault("agent", "probe-agent")
    payload.setdefault("lastCheckedAt", utc_now())
    return payload


def fetch_probe_agent_settings(probe_agent_url: str) -> dict[str, Any] | None:
    return _request_json(urllib.parse.urljoin(probe_agent_url.rstrip("/") + "/", "settings"))


def update_probe_agent_settings(
    probe_agent_url: str,
    *,
    interval_seconds: float,
) -> dict[str, Any] | None:
    return _request_json(
        urllib.parse.urljoin(probe_agent_url.rstrip("/") + "/", "settings"),
        method="POST",
        payload={"probeIntervalSeconds": interval_seconds},
    )


def build_infra_state(
    *,
    blue_weight: int | None = None,
    green_weight: int | None = None,
    load_balancer_status: str | None = None,
    rollout_phase: str | None = None,
    rollout_progress: int | None = None,
    rollout_message: str | None = None,
    probe_interval_seconds: float | None = None,
    include_probe: bool = True,
) -> dict:
    state = _clone_default_state()
    runtime = load_runtime_config()

    project_id = runtime["project_id"]
    region = runtime["region"]
    service_name = runtime["service_name"]

    blue_service_name = f"{service_name}-blue"
    green_service_name = f"{service_name}-green"
    blue_backend_name = f"{service_name}-blue-backend"
    green_backend_name = f"{service_name}-green-backend"
    address_name = f"{service_name}-ip"
    url_map_name = f"{service_name}-url-map"

    state["loadBalancer"]["name"] = f"{service_name}-lb"
    state["services"][0]["name"] = blue_service_name
    state["services"][1]["name"] = green_service_name

    gcp_source = False
    blue_service = None
    green_service = None
    address = None
    url_map = None

    if project_id:
        blue_service = _run_gcloud_json(
            [
                "run",
                "services",
                "describe",
                blue_service_name,
                "--project",
                project_id,
                "--region",
                region,
            ]
        )
        green_service = _run_gcloud_json(
            [
                "run",
                "services",
                "describe",
                green_service_name,
                "--project",
                project_id,
                "--region",
                region,
            ]
        )
        address = _run_gcloud_json(
            [
                "compute",
                "addresses",
                "describe",
                address_name,
                "--project",
                project_id,
                "--global",
            ]
        )
        url_map = _run_gcloud_json(
            [
                "compute",
                "url-maps",
                "describe",
                url_map_name,
                "--project",
                project_id,
            ]
        )
        gcp_source = any((blue_service, green_service, address, url_map))

    if not gcp_source and blue_weight is None and green_weight is None:
        state["traffic"]["blue"] = 0
        state["traffic"]["green"] = 0
        state["traffic"]["active"] = "unknown"
        state["loadBalancer"]["status"] = load_balancer_status or "unknown"
        state["services"][0]["status"] = "unknown"
        state["services"][1]["status"] = "unknown"
        state["services"][0]["weight"] = 0
        state["services"][1]["weight"] = 0
        if rollout_phase is not None:
            state["rollout"]["phase"] = rollout_phase
        if rollout_progress is not None:
            state["rollout"]["progress"] = rollout_progress
        if rollout_message is not None:
            state["rollout"]["message"] = rollout_message
        if probe_interval_seconds is not None:
            state["settings"]["probeIntervalSeconds"] = probe_interval_seconds
        state["meta"] = {
            "source": "local-default",
            "terraformStateAvailable": False,
            "lastUpdatedAt": utc_now(),
            "projectId": project_id,
            "region": region,
        }
        return state

    live_blue, live_green = _weight_from_url_map(
        url_map,
        blue_backend_name=blue_backend_name,
        green_backend_name=green_backend_name,
    )
    live_blue, live_green = _normalize_weights(live_blue, live_green)

    resolved_blue = live_blue if live_blue is not None else 0
    resolved_green = live_green if live_green is not None else 0

    if blue_weight is not None and live_blue is None and not gcp_source:
        resolved_blue = blue_weight
    if green_weight is not None and live_green is None and not gcp_source:
        resolved_green = green_weight

    state["traffic"]["blue"] = resolved_blue
    state["traffic"]["green"] = resolved_green
    state["traffic"]["active"] = (
        "split"
        if resolved_blue == resolved_green
        else "blue"
        if resolved_blue > resolved_green
        else "green"
    )

    if address and address.get("address"):
        state["loadBalancer"]["endpoint"] = f"http://{address['address']}"

    state["loadBalancer"]["status"] = load_balancer_status or (
        "serving" if gcp_source else state["loadBalancer"]["status"]
    )

    if blue_service:
        blue_state = _condition_state(blue_service)
        state["services"][0]["url"] = _service_url(blue_service)
        state["services"][0]["status"] = (
            "serving" if resolved_blue > 0 and blue_state == "ready" else
            "standby" if blue_state == "ready" else
            "degraded"
        )
    else:
        state["services"][0]["status"] = "serving" if resolved_blue > 0 else "standby"

    if green_service:
        green_state = _condition_state(green_service)
        state["services"][1]["url"] = _service_url(green_service)
        state["services"][1]["status"] = (
            "serving" if resolved_green > 0 and green_state == "ready" else
            "standby" if green_state == "ready" else
            "degraded"
        )
    else:
        state["services"][1]["status"] = "serving" if resolved_green > 0 else "standby"

    state["services"][0]["weight"] = resolved_blue
    state["services"][1]["weight"] = resolved_green

    if rollout_phase is not None:
        state["rollout"]["phase"] = rollout_phase
    if rollout_progress is not None:
        state["rollout"]["progress"] = rollout_progress
    if rollout_message is not None:
        state["rollout"]["message"] = rollout_message

    if probe_interval_seconds is not None:
        state["settings"]["probeIntervalSeconds"] = probe_interval_seconds

    state["meta"] = {
        "source": "gcp" if gcp_source else "local-default",
        "terraformStateAvailable": False,
        "lastUpdatedAt": utc_now(),
        "projectId": project_id,
        "region": region,
    }
    return state


def with_probe(state: dict, probe_agent_url: str) -> dict:
    next_state = json.loads(json.dumps(state))
    next_state["requestProbe"] = fetch_probe_agent_latest(probe_agent_url)
    probe_settings = fetch_probe_agent_settings(probe_agent_url)
    if probe_settings and "probeIntervalSeconds" in probe_settings:
        next_state["settings"]["probeIntervalSeconds"] = probe_settings["probeIntervalSeconds"]
    next_state["meta"]["lastUpdatedAt"] = utc_now()
    return next_state
