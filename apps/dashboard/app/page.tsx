"use client";

import { useEffect, useRef, useState } from "react";

type InfraService = {
  id: string;
  name: string;
  status: string;
  version: string;
  url: string | null;
  weight: number;
  color: "blue" | "green";
};

type InfraState = {
  loadBalancer: {
    name: string;
    status: string;
    endpoint: string | null;
    type: string;
  };
  traffic: {
    blue: number;
    green: number;
    active: string;
  };
  services: InfraService[];
  rollout: {
    phase: string;
    progress: number;
    message: string;
  };
  requestProbe: {
    status: string;
    target: string;
    observedColor: string | null;
    observedVersion: string | null;
    statusCode: number | null;
    latencyMs: number | null;
    lastCheckedAt: string | null;
    samplePath: string | null;
    error: string | null;
  };
  settings: {
    probeIntervalSeconds: number;
    readOnly: boolean;
  };
  meta: {
    source: string;
    terraformStateAvailable: boolean;
    lastUpdatedAt: string;
    demoMode: boolean;
    projectId?: string | null;
    region?: string | null;
    terraformDir?: string | null;
  };
};

type ProbePulse = {
  id: string;
  target: string;
  progress: number;
  startedAt: number;
  durationMs: number;
};

const MAX_VISIBLE_PROBE_PULSES = 10;
const PROBE_PULSE_DURATION_MS = 1000;

const API_BASE = process.env.NEXT_PUBLIC_API_BASE_URL || "http://localhost:8000";

const initialState: InfraState = {
  loadBalancer: {
    name: "sre-playground-lb",
    status: "idle",
    endpoint: null,
    type: "external-http",
  },
  traffic: {
    blue: 100,
    green: 0,
    active: "blue",
  },
  services: [
    {
      id: "blue",
      name: "sre-playground-blue",
      status: "serving",
      version: "blue",
      url: null,
      weight: 100,
      color: "blue",
    },
    {
      id: "green",
      name: "sre-playground-green",
      status: "standby",
      version: "green",
      url: null,
      weight: 0,
      color: "green",
    },
  ],
  rollout: {
    phase: "idle",
    progress: 0,
    message: "awaiting deployment activity",
  },
  requestProbe: {
    status: "idle",
    target: "unknown",
    observedColor: null,
    observedVersion: null,
    statusCode: null,
    latencyMs: null,
    lastCheckedAt: null,
    samplePath: null,
    error: null,
  },
  settings: {
    probeIntervalSeconds: 5,
    readOnly: false,
  },
  meta: {
    source: "default",
    terraformStateAvailable: false,
    lastUpdatedAt: new Date().toISOString(),
    demoMode: false,
  },
};

function serviceTone(status: string): string {
  if (status === "serving") {
    return "serving";
  }
  if (status === "failed") {
    return "failed";
  }
  return "standby";
}

function trafficEdgeColor(color: "blue" | "green", weight: number): string {
  if (weight <= 0) {
    return "rgba(120, 118, 114, 0.45)";
  }

  const saturation = 18 + weight * 0.72;
  const lightness = 78 - weight * 0.34;
  const hue = color === "blue" ? 203 : 150;
  return `hsl(${hue} ${saturation}% ${lightness}%)`;
}

function serviceCardStyle(color: "blue" | "green", weight: number) {
  if (weight <= 0) {
    return {
      border: "1px solid rgba(120, 118, 114, 0.22)",
      background: "#ffffff",
      boxShadow: "0 20px 40px rgba(120, 118, 114, 0.06)",
    };
  }

  const stroke = trafficEdgeColor(color, weight);

  return {
    border: `1px solid ${stroke}`,
    background: "#ffffff",
    boxShadow:
      color === "blue"
        ? "0 20px 40px rgba(14,107,168,0.10)"
        : "0 20px 40px rgba(47,143,104,0.10)",
  };
}

function formatTimestamp(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return new Intl.DateTimeFormat("ja-JP", {
    dateStyle: "medium",
    timeStyle: "medium",
  }).format(date);
}

function cubicBezierPoint(
  t: number,
  start: { x: number; y: number },
  control1: { x: number; y: number },
  control2: { x: number; y: number },
  end: { x: number; y: number },
) {
  const oneMinusT = 1 - t;
  return {
    x:
      oneMinusT ** 3 * start.x +
      3 * oneMinusT ** 2 * t * control1.x +
      3 * oneMinusT * t ** 2 * control2.x +
      t ** 3 * end.x,
    y:
      oneMinusT ** 3 * start.y +
      3 * oneMinusT ** 2 * t * control1.y +
      3 * oneMinusT * t ** 2 * control2.y +
      t ** 3 * end.y,
  };
}

function probePoint(target: string, progress: number) {
  const ingressShare = 0.34;

  if (progress <= ingressShare) {
    return cubicBezierPoint(
      progress / ingressShare,
      { x: 194, y: 90 },
      { x: 214, y: 86 },
      { x: 238, y: 86 },
      { x: 270, y: 90 },
    );
  }

  const downstreamProgress = (progress - ingressShare) / (1 - ingressShare);
  if (target === "blue") {
    return cubicBezierPoint(
      downstreamProgress,
      { x: 390, y: 145 },
      { x: 360, y: 190 },
      { x: 280, y: 228 },
      { x: 179, y: 264 },
    );
  }

  if (target === "green") {
    return cubicBezierPoint(
      downstreamProgress,
      { x: 390, y: 145 },
      { x: 420, y: 190 },
      { x: 500, y: 228 },
      { x: 601, y: 264 },
    );
  }

  return null;
}

function TopologySvg({
  state,
  probePulses,
}: {
  state: InfraState;
  probePulses: ProbePulse[];
}) {
  const [blueService, greenService] = state.services;
  const probeTarget = state.requestProbe.status === "ok" ? state.requestProbe.target : "unknown";
  const blueActive = probeTarget === "blue" || (probeTarget === "unknown" && state.traffic.blue > 0);
  const greenActive = probeTarget === "green" || (probeTarget === "unknown" && state.traffic.green > 0);
  const probeIngressPath = "M194 90 C 214 86 238 86 270 90";
  const bluePath = "M390 145 C 360 190 280 228 179 264";
  const greenPath = "M390 145 C 420 190 500 228 601 264";
  const blueStroke = blueActive
    ? trafficEdgeColor("blue", Math.max(state.traffic.blue, 100))
    : trafficEdgeColor("blue", state.traffic.blue);
  const greenStroke = greenActive
    ? trafficEdgeColor("green", Math.max(state.traffic.green, 100))
    : trafficEdgeColor("green", state.traffic.green);
  const activeProbePoints = probePulses
    .map((pulse) => ({
      id: pulse.id,
      point: probePoint(pulse.target, pulse.progress),
    }))
    .filter((pulse): pulse is { id: string; point: { x: number; y: number } } => pulse.point !== null);

  const cardBase = {
    fill: "#fffaf1",
    stroke: "rgba(29,29,27,0.14)",
  };

  const blueCard = serviceCardStyle("blue", blueService.weight);
  const greenCard = serviceCardStyle("green", greenService.weight);

  return (
    <svg className="topology-svg" viewBox="0 0 780 520" role="img" aria-label="Infrastructure topology">
      <defs>
        <marker
          id="arrow-blue"
          markerWidth="12"
          markerHeight="12"
          refX="10"
          refY="6"
          orient="auto"
          markerUnits="strokeWidth"
        >
          <path d="M1,1 L11,6 L1,11" fill="none" stroke={blueStroke} strokeWidth="1.8" />
        </marker>
        <marker
          id="arrow-green"
          markerWidth="12"
          markerHeight="12"
          refX="10"
          refY="6"
          orient="auto"
          markerUnits="strokeWidth"
        >
          <path d="M1,1 L11,6 L1,11" fill="none" stroke={greenStroke} strokeWidth="1.8" />
        </marker>
      </defs>

      <path
        d={probeIngressPath}
        className={state.requestProbe.status === "ok" ? "topology-link active" : "topology-link"}
        style={{ stroke: "rgba(198, 103, 43, 0.7)" }}
      />
      <path
        d={bluePath}
        className={blueActive ? "topology-link active" : "topology-link"}
        style={{ stroke: blueStroke }}
        markerEnd="url(#arrow-blue)"
      />
      <path
        d={greenPath}
        className={greenActive ? "topology-link active" : "topology-link"}
        style={{ stroke: greenStroke }}
        markerEnd="url(#arrow-green)"
      />
      <rect x="34" y="40" width="160" height="96" rx="20" style={cardBase} className="topology-node" />
      <text x="54" y="72" className="topology-kicker">EXTERNAL PROBE</text>
      <text x="54" y="99" className="topology-title">Probe Agent</text>
      <text x="54" y="122" className="topology-copy">
        {probeIntervalSecondsDisplay(state.settings.probeIntervalSeconds)}
      </text>
      <rect x="270" y="36" width="240" height="108" rx="20" style={cardBase} className="topology-node" />
      <text x="290" y="68" className="topology-kicker">LOAD BALANCER</text>
      <text x="290" y="95" className="topology-title">{state.loadBalancer.name}</text>
      <text x="290" y="118" className="topology-copy">{state.loadBalancer.status}</text>
      <text x="290" y="136" className="topology-copy">{state.loadBalancer.type}</text>

      <rect x="54" y="264" width="250" height="126" rx="20" style={blueCard} className="topology-node" />
      <text x="74" y="296" className="topology-kicker">BLUE SERVICE</text>
      <text x="74" y="323" className="topology-title">{blueService.name}</text>
      <text x="74" y="346" className="topology-copy">{blueService.status}</text>
      <text x="74" y="366" className="topology-copy">Configured {state.traffic.blue}%</text>
      <text x="74" y="384" className="topology-copy">
        Probe {probeTarget === "blue" ? "active" : "standby"}
      </text>

      <rect x="476" y="264" width="250" height="126" rx="20" style={greenCard} className="topology-node" />
      <text x="496" y="296" className="topology-kicker">GREEN SERVICE</text>
      <text x="496" y="323" className="topology-title">{greenService.name}</text>
      <text x="496" y="346" className="topology-copy">{greenService.status}</text>
      <text x="496" y="366" className="topology-copy">Configured {state.traffic.green}%</text>
      <text x="496" y="384" className="topology-copy">
        Probe {probeTarget === "green" ? "active" : "standby"}
      </text>

      <g>
        <rect x="204" y="188" width="82" height="28" rx="14" className="topology-badge" />
        <text x="245" y="206" textAnchor="middle" className="topology-badge-text">
          {state.traffic.blue}%
        </text>
      </g>
      <g>
        <rect x="494" y="188" width="82" height="28" rx="14" className="topology-badge" />
        <text x="535" y="206" textAnchor="middle" className="topology-badge-text">
          {state.traffic.green}%
        </text>
      </g>
      {activeProbePoints.map((pulse) => (
        <circle
          key={pulse.id}
          cx={pulse.point.x}
          cy={pulse.point.y}
          r="7"
          className="topology-probe-dot"
        />
      ))}
    </svg>
  );
}

function probeIntervalSecondsDisplay(value: number) {
  return `Every ${value.toFixed(1)} sec`;
}

export default function DashboardPage() {
  const [infraState, setInfraState] = useState<InfraState>(initialState);
  const [progress, setProgress] = useState(0);
  const [phase, setPhase] = useState("idle");
  const [logs, setLogs] = useState<string[]>([]);
  const [blueWeight, setBlueWeight] = useState(100);
  const [greenWeight, setGreenWeight] = useState(0);
  const [deploying, setDeploying] = useState(false);
  const [streamStatus, setStreamStatus] = useState("connecting");
  const [probePulses, setProbePulses] = useState<ProbePulse[]>([]);
  const [probeIntervalSeconds, setProbeIntervalSeconds] = useState(5);
  const [savingProbeInterval, setSavingProbeInterval] = useState(false);
  const [trafficDirty, setTrafficDirty] = useState(false);
  const [probeIntervalDirty, setProbeIntervalDirty] = useState(false);
  const logBottomRef = useRef<HTMLDivElement | null>(null);
  const probeAnimationHandleRef = useRef<number | null>(null);
  const probeIntervalRef = useRef(5);
  const trafficDirtyRef = useRef(false);
  const probeIntervalDirtyRef = useRef(false);
  const deployingRef = useRef(false);

  useEffect(() => {
    trafficDirtyRef.current = trafficDirty;
  }, [trafficDirty]);

  useEffect(() => {
    probeIntervalDirtyRef.current = probeIntervalDirty;
  }, [probeIntervalDirty]);

  useEffect(() => {
    deployingRef.current = deploying;
  }, [deploying]);

  useEffect(() => {
    Promise.all([
      fetch(`${API_BASE}/api/state`).then((res) => res.json() as Promise<InfraState>),
      fetch(`${API_BASE}/api/settings`).then(
        (res) => res.json() as Promise<{ probeIntervalSeconds: number }>,
      ),
    ])
      .then(([data, settings]) => {
        setInfraState(data);
        setBlueWeight(data.traffic.blue);
        setGreenWeight(data.traffic.green);
        setProgress(data.rollout.progress);
        setPhase(data.rollout.phase);
        setProbeIntervalSeconds(settings.probeIntervalSeconds);
        probeIntervalRef.current = settings.probeIntervalSeconds;
      })
      .catch(() => {
        setStreamStatus("offline");
      });
  }, []);

  useEffect(() => {
    const eventSource = new EventSource(`${API_BASE}/api/state/stream`);

    eventSource.addEventListener("open", () => {
      setStreamStatus("live");
    });

    eventSource.addEventListener("state", (event) => {
      const messageEvent = event as MessageEvent<string>;
      const nextState = JSON.parse(messageEvent.data) as InfraState;
      setInfraState(nextState);
      if (!trafficDirtyRef.current && !deployingRef.current) {
        setBlueWeight(nextState.traffic.blue);
        setGreenWeight(nextState.traffic.green);
      }
      setProgress(nextState.rollout.progress);
      setPhase(nextState.rollout.phase);
      if (!probeIntervalDirtyRef.current) {
        setProbeIntervalSeconds(nextState.settings.probeIntervalSeconds);
      }
      probeIntervalRef.current = nextState.settings.probeIntervalSeconds;
    });

    eventSource.addEventListener("probe", (event) => {
      const messageEvent = event as MessageEvent<string>;
      const probe = JSON.parse(messageEvent.data) as InfraState["requestProbe"];
      if (probe.target === "blue" || probe.target === "green") {
        const now = performance.now();
        setProbePulses((current) => {
          const maxVisible = Math.min(
            MAX_VISIBLE_PROBE_PULSES,
            Math.max(1, Math.round(PROBE_PULSE_DURATION_MS / (probeIntervalRef.current * 1000))),
          );
          const next = [
            ...current,
            {
              id: `${probe.lastCheckedAt ?? Date.now().toString()}:${probe.target}`,
              target: probe.target,
              progress: 0,
              startedAt: now,
              durationMs: PROBE_PULSE_DURATION_MS,
            },
          ];
          return next.slice(-maxVisible);
        });
      }
    });

    eventSource.onerror = () => {
      setStreamStatus("reconnecting");
    };

    return () => {
      if (probeAnimationHandleRef.current !== null) {
        window.cancelAnimationFrame(probeAnimationHandleRef.current);
      }
      eventSource.close();
    };
  }, []);

  useEffect(() => {
    const tick = (now: number) => {
      setProbePulses((current) =>
        current
          .map((pulse) => ({
            ...pulse,
            progress: Math.min((now - pulse.startedAt) / pulse.durationMs, 1),
          }))
          .filter((pulse) => pulse.progress < 1),
      );
      probeAnimationHandleRef.current = window.requestAnimationFrame(tick);
    };

    probeAnimationHandleRef.current = window.requestAnimationFrame(tick);

    return () => {
      if (probeAnimationHandleRef.current !== null) {
        window.cancelAnimationFrame(probeAnimationHandleRef.current);
        probeAnimationHandleRef.current = null;
      }
    };
  }, []);

  useEffect(() => {
    logBottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [logs]);

  async function handleProbeIntervalCommit(nextValue: number) {
    setSavingProbeInterval(true);
    try {
      const response = await fetch(`${API_BASE}/api/settings`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          probeIntervalSeconds: nextValue,
        }),
      });

      if (!response.ok) {
        throw new Error(`settings update failed: ${response.status}`);
      }

      const data = (await response.json()) as { probeIntervalSeconds: number };
      setProbeIntervalSeconds(data.probeIntervalSeconds);
      probeIntervalRef.current = data.probeIntervalSeconds;
      setProbeIntervalDirty(false);
        setInfraState((current) => ({
          ...current,
          settings: {
            probeIntervalSeconds: data.probeIntervalSeconds,
            readOnly: current.settings.readOnly,
          },
        }));
    } finally {
      setSavingProbeInterval(false);
    }
  }

  async function handleDeploy() {
    setDeploying(true);
    setTrafficDirty(false);
    setLogs([]);
    setProgress(0);
    setPhase("queued");

    try {
      const response = await fetch(`${API_BASE}/api/deploy`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          blue_weight: blueWeight,
          green_weight: greenWeight,
        }),
      });

      if (!response.ok) {
        setLogs((prev) => [...prev, `Deploy API failed with status ${response.status}.`]);
        return;
      }

      if (!response.body) {
        setLogs((prev) => [...prev, "No event stream returned from API."]);
        return;
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      while (true) {
        const { value, done } = await reader.read();
        if (done) {
          break;
        }

        buffer += decoder.decode(value, { stream: true });
        const chunks = buffer.split("\n\n");
        buffer = chunks.pop() || "";

        for (const chunk of chunks) {
          const eventMatch = chunk.match(/event: (.+)/);
          const dataMatch = chunk.match(/data: (.+)/);
          if (!eventMatch || !dataMatch) {
            continue;
          }

          const eventName = eventMatch[1];
          const data = JSON.parse(dataMatch[1]);

          if (eventName === "status") {
            setPhase(data.phase);
            setProgress(data.progress ?? 0);
            setLogs((prev) => [...prev, `[status] ${data.message}`]);
          }

          if (eventName === "log") {
            setLogs((prev) => [...prev, `[${data.channel}] ${data.message}`]);
          }

          if (eventName === "state") {
            setInfraState(data);
          }

          if (eventName === "error") {
            setLogs((prev) => [...prev, `[error] ${data.message}`]);
          }
        }
      }
    } catch {
      setLogs((prev) => [...prev, "[error] failed to connect to deploy stream"]);
    } finally {
      setDeploying(false);
    }
  }

  return (
    <main className="app-shell">
      <section className="hero">
        <span className="eyebrow">Phase 2 / Infrastructure Visualization Dashboard</span>
        <h1>Topology, traffic, and rollout telemetry in one view.</h1>
        <p>
          A fixed SVG topology renders the blue/green traffic path while the API streams
          live infrastructure state and deployment progress.
        </p>
      </section>

      <section className="metrics">
        <div className="metric">
          Load Balancer
          <strong>{infraState.loadBalancer.status}</strong>
          <span>{infraState.loadBalancer.name}</span>
        </div>
        <div className="metric">
          Active Route
          <strong>{infraState.traffic.active}</strong>
          <span>{infraState.traffic.blue}% / {infraState.traffic.green}% split</span>
        </div>
        <div className="metric">
          State Stream
          <strong>{streamStatus}</strong>
          <span>{formatTimestamp(infraState.meta.lastUpdatedAt)}</span>
        </div>
      </section>

      <div className="grid">
        <section className="panel panel-pad">
          <div className="panel-head">
            <div>
              <h2>Infrastructure Topology</h2>
              <p>Load balancer to Cloud Run blue/green routing with live weights.</p>
            </div>
            <div className="badge">
              <span className="dot blue" />
              Blue
              <span className="dot green" />
              Green
            </div>
          </div>

          <div className="topology-meta">
            <span>Source: {infraState.meta.source}</span>
            <span>Region: {infraState.meta.region || "n/a"}</span>
            <span>Project: {infraState.meta.projectId || "n/a"}</span>
          </div>

          <div className="traffic-bar" aria-label="traffic split">
            <span className="traffic-blue" style={{ width: `${infraState.traffic.blue}%` }} />
            <span className="traffic-green" style={{ width: `${infraState.traffic.green}%` }} />
          </div>

          <div className="traffic-labels">
            <span>Blue {infraState.traffic.blue}%</span>
            <span>Green {infraState.traffic.green}%</span>
          </div>

          <div className="flow-wrap">
            <TopologySvg state={infraState} probePulses={probePulses} />
          </div>

          <div className="resource-grid">
            <article className="resource-card">
              <h3>Load Balancer</h3>
              <strong>{infraState.loadBalancer.name}</strong>
              <span>Status: {infraState.loadBalancer.status}</span>
              <span>Type: {infraState.loadBalancer.type}</span>
              <a href={infraState.loadBalancer.endpoint || "#"} className="resource-link">
                {infraState.loadBalancer.endpoint || "endpoint unavailable"}
              </a>
            </article>

            {infraState.services.map((service) => (
              <article className={`resource-card ${service.color}`} key={service.id}>
                <h3>{service.version.toUpperCase()} Service</h3>
                <strong>{service.name}</strong>
                <span className={`service-status ${serviceTone(service.status)}`}>
                  {service.status}
                </span>
                <span>Traffic Weight: {service.weight}%</span>
                <a href={service.url || "#"} className="resource-link">
                  {service.url || "service URL unavailable"}
                </a>
              </article>
            ))}
          </div>
        </section>

        <section className="stack">
          <div className="panel panel-pad controls">
            <div>
              <h2>Deploy Control</h2>
              <p>Adjust target weights and watch rollout progress via SSE.</p>
              {infraState.meta.demoMode ? (
                <p className="panel-copy">Demo mode is enabled. Deploy and settings changes are locked.</p>
              ) : null}
            </div>

            <fieldset className="controls-fieldset" disabled={infraState.settings.readOnly}>
              <div className="control-row">
                <label htmlFor="blue-weight">Blue Weight: {blueWeight}%</label>
                <input
                  id="blue-weight"
                  type="range"
                  min={0}
                  max={100}
                  value={blueWeight}
                  onChange={(event) => {
                    const next = Number(event.target.value);
                    setTrafficDirty(true);
                    setBlueWeight(next);
                    setGreenWeight(100 - next);
                  }}
                />
              </div>

              <div className="control-row">
                <label htmlFor="green-weight">Green Weight: {greenWeight}%</label>
                <input
                  id="green-weight"
                  type="range"
                  min={0}
                  max={100}
                  value={greenWeight}
                  onChange={(event) => {
                    const next = Number(event.target.value);
                    setTrafficDirty(true);
                    setGreenWeight(next);
                    setBlueWeight(100 - next);
                  }}
                />
              </div>

              <div className="control-row">
                <label htmlFor="probe-interval">
                  Probe Interval: {probeIntervalSeconds.toFixed(1)} sec
                </label>
                <input
                  id="probe-interval"
                  type="range"
                  min={0.1}
                  max={10}
                  step={0.1}
                  value={probeIntervalSeconds}
                  onChange={(event) => {
                    setProbeIntervalDirty(true);
                    setProbeIntervalSeconds(Number(event.target.value));
                  }}
                  onMouseUp={(event) => {
                    void handleProbeIntervalCommit(Number((event.target as HTMLInputElement).value));
                  }}
                  onTouchEnd={(event) => {
                    void handleProbeIntervalCommit(Number((event.target as HTMLInputElement).value));
                  }}
                />
                <input
                  type="number"
                  min={0.1}
                  max={10}
                  step={0.1}
                  value={probeIntervalSeconds}
                  onChange={(event) => {
                    const next = Number(event.target.value);
                    if (Number.isFinite(next)) {
                      setProbeIntervalDirty(true);
                      setProbeIntervalSeconds(next);
                    }
                  }}
                  onBlur={() => {
                    const bounded = Math.min(10, Math.max(0.1, probeIntervalSeconds));
                    setProbeIntervalSeconds(bounded);
                    void handleProbeIntervalCommit(bounded);
                  }}
                />
                <span className="control-hint">
                  {infraState.settings.readOnly
                    ? "Locked in demo mode"
                    : savingProbeInterval
                      ? "Saving..."
                      : "0.1 - 10.0 sec"}
                </span>
              </div>

              <button
                className="deploy-button"
                type="button"
                disabled={deploying || infraState.settings.readOnly || blueWeight + greenWeight !== 100}
                onClick={handleDeploy}
              >
                {deploying ? "Deploying..." : "Deploy"}
              </button>
            </fieldset>

            <div className="rollout-card">
              <div className="rollout-meta">
                <span>Phase: {phase}</span>
                <span>{progress}%</span>
              </div>
              <div className="progress-bar">
                <span style={{ width: `${progress}%` }} />
              </div>
              <p>{infraState.rollout.message}</p>
            </div>
          </div>

          <div className="panel panel-pad">
            <h2>Deployment Log</h2>
            <p className="panel-copy">Terraform JSON events and stderr/stdout are appended here.</p>
            <div className="log-box">
              {logs.length === 0 ? "Awaiting deployment events..." : logs.join("\n")}
              <div ref={logBottomRef} />
            </div>
          </div>
        </section>
      </div>
    </main>
  );
}
