"use client";

import { useEffect, useRef, useState } from "react";
import ReactFlow, { Background, Controls, Edge, MarkerType, Node } from "reactflow";
import "reactflow/dist/style.css";

type InfraState = {
  loadBalancer: {
    name: string;
    status: string;
  };
  traffic: {
    blue: number;
    green: number;
  };
  services: Array<{
    id: string;
    name: string;
    status: string;
    version: string;
  }>;
};

const API_BASE = process.env.NEXT_PUBLIC_API_BASE_URL || "http://localhost:8000";

const initialState: InfraState = {
  loadBalancer: { name: "sre-playground-lb", status: "idle" },
  traffic: { blue: 100, green: 0 },
  services: [
    { id: "blue", name: "sre-playground-blue", status: "serving", version: "blue" },
    { id: "green", name: "sre-playground-green", status: "standby", version: "green" },
  ],
};

function buildGraph(state: InfraState): { nodes: Node[]; edges: Edge[] } {
  return {
    nodes: [
      {
        id: "lb",
        position: { x: 250, y: 40 },
        data: {
          label: `${state.loadBalancer.name}\n${state.loadBalancer.status}`,
        },
        style: {
          width: 220,
          borderRadius: 18,
          border: "1px solid rgba(29,29,27,0.2)",
          background: "#fffaf1",
          padding: 16,
          whiteSpace: "pre-line",
        },
      },
      {
        id: "blue",
        position: { x: 60, y: 220 },
        data: {
          label: `${state.services[0].name}\n${state.traffic.blue}%`,
        },
        style: {
          width: 220,
          borderRadius: 18,
          border: "1px solid rgba(14,107,168,0.3)",
          background: "rgba(14,107,168,0.12)",
          padding: 16,
          whiteSpace: "pre-line",
        },
      },
      {
        id: "green",
        position: { x: 430, y: 220 },
        data: {
          label: `${state.services[1].name}\n${state.traffic.green}%`,
        },
        style: {
          width: 220,
          borderRadius: 18,
          border: "1px solid rgba(47,143,104,0.35)",
          background: "rgba(47,143,104,0.12)",
          padding: 16,
          whiteSpace: "pre-line",
        },
      },
    ],
    edges: [
      {
        id: "lb-blue",
        source: "lb",
        target: "blue",
        label: `${state.traffic.blue}%`,
        markerEnd: { type: MarkerType.ArrowClosed },
        animated: state.traffic.blue > 0,
        style: { stroke: "#0e6ba8", strokeWidth: 2 },
      },
      {
        id: "lb-green",
        source: "lb",
        target: "green",
        label: `${state.traffic.green}%`,
        markerEnd: { type: MarkerType.ArrowClosed },
        animated: state.traffic.green > 0,
        style: { stroke: "#2f8f68", strokeWidth: 2 },
      },
    ],
  };
}

export default function DashboardPage() {
  const [infraState, setInfraState] = useState<InfraState>(initialState);
  const [progress, setProgress] = useState(0);
  const [phase, setPhase] = useState("idle");
  const [logs, setLogs] = useState<string[]>([]);
  const [blueWeight, setBlueWeight] = useState(0);
  const [greenWeight, setGreenWeight] = useState(100);
  const [deploying, setDeploying] = useState(false);
  const logBottomRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    fetch(`${API_BASE}/api/state`)
      .then((res) => res.json())
      .then((data: InfraState) => {
        setInfraState(data);
        setBlueWeight(data.traffic.blue);
        setGreenWeight(data.traffic.green);
      })
      .catch(() => undefined);
  }, []);

  useEffect(() => {
    logBottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [logs]);

  async function handleDeploy() {
    setDeploying(true);
    setLogs([]);
    setProgress(0);
    setPhase("queued");

    const response = await fetch(`${API_BASE}/api/deploy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        blue_weight: blueWeight,
        green_weight: greenWeight,
      }),
    });

    if (!response.body) {
      setLogs((prev) => [...prev, "No event stream returned from API."]);
      setDeploying(false);
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

    setDeploying(false);
  }

  const graph = buildGraph(infraState);

  return (
    <main className="app-shell">
      <section className="hero">
        <span className="eyebrow">SRE Playground</span>
        <h1>Blue/Green deploys with live topology.</h1>
        <p>
          Terraform-driven Cloud Run blue/green deployment, traffic weighting,
          and rollout progress in one control plane.
        </p>
      </section>

      <section className="metrics">
        <div className="metric">
          Load Balancer
          <strong>{infraState.loadBalancer.status}</strong>
        </div>
        <div className="metric">
          Blue Traffic
          <strong>{infraState.traffic.blue}%</strong>
        </div>
        <div className="metric">
          Green Traffic
          <strong>{infraState.traffic.green}%</strong>
        </div>
      </section>

      <div className="grid" style={{ marginTop: 20 }}>
        <section className="panel panel-pad">
          <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 16 }}>
            <div>
              <h2 style={{ margin: 0 }}>Infrastructure Topology</h2>
              <p style={{ color: "var(--muted)" }}>
                React Flow representation of the load balancer and active revisions.
              </p>
            </div>
            <div className="badge">
              <span className="dot blue" />
              Blue
              <span className="dot green" />
              Green
            </div>
          </div>
          <div style={{ height: 500 }}>
            <ReactFlow nodes={graph.nodes} edges={graph.edges} fitView>
              <Background />
              <Controls />
            </ReactFlow>
          </div>
        </section>

        <section className="stack">
          <div className="panel panel-pad controls">
            <div>
              <h2 style={{ margin: 0 }}>Deploy Control</h2>
              <p style={{ color: "var(--muted)" }}>
                Set target weights and stream rollout logs over SSE.
              </p>
            </div>

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
                  setGreenWeight(next);
                  setBlueWeight(100 - next);
                }}
              />
            </div>

            <button
              className="deploy-button"
              type="button"
              disabled={deploying || blueWeight + greenWeight !== 100}
              onClick={handleDeploy}
            >
              {deploying ? "Deploying..." : "Deploy"}
            </button>

            <div>
              <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 8 }}>
                <span>Phase: {phase}</span>
                <span>{progress}%</span>
              </div>
              <div className="progress-bar">
                <span style={{ width: `${progress}%` }} />
              </div>
            </div>
          </div>

          <div className="panel panel-pad">
            <h2 style={{ marginTop: 0 }}>Deployment Log</h2>
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
