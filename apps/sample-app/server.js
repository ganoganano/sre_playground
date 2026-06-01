import http from "node:http";
import os from "node:os";
import { SpanStatusCode, context, trace } from "@opentelemetry/api";

import { startTelemetry } from "./telemetry.js";

const port = Number(process.env.PORT || 3010);
const color = process.env.APP_COLOR || "blue";
const version = process.env.APP_VERSION || "v1";
const baseLatencyMs = Number(process.env.APP_BASE_LATENCY_MS || 0);
const errorRate = Number(process.env.APP_ERROR_RATE || 0);
const extraLatencyMs = color === "green" ? Number(process.env.GREEN_EXTRA_LATENCY_MS || 0) : 0;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const server = http.createServer(async (req, res) => {
  const tracer = trace.getTracer("sample-app");
  const span = tracer.startSpan("sample-app.request");
  const activeContext = trace.setSpan(context.active(), span);
  const requestStartedAt = Date.now();

  if (baseLatencyMs + extraLatencyMs > 0) {
    await sleep(baseLatencyMs + extraLatencyMs);
  }

  const shouldFail =
    errorRate > 0 && color === "green" && Math.random() < Math.min(Math.max(errorRate, 0), 1);

  const traceId = span.spanContext().traceId;
  const spanId = span.spanContext().spanId;
  const payload = {
    service: "sre-playground-sample-app",
    color,
    version,
    hostname: os.hostname(),
    timestamp: new Date().toISOString(),
    path: req.url,
    traceId,
    spanId,
    latencyMs: Date.now() - requestStartedAt,
  };

  try {
    await context.with(activeContext, async () => {
      span.setAttribute("app.color", color);
      span.setAttribute("app.version", version);
      span.setAttribute("http.route", req.url || "/");
      span.setAttribute("demo.chaos.enabled", color === "green");

      if (shouldFail) {
        span.setAttribute("app.error_injected", true);
        span.recordException(new Error("green error injection"));
        span.setStatus({ code: SpanStatusCode.ERROR, message: "green error injection" });
        payload.error = "green error injection";
        res.setHeader("Content-Type", "application/json; charset=utf-8");
        res.writeHead(500);
        res.end(JSON.stringify(payload, null, 2));
        return;
      }

      res.setHeader("Content-Type", "application/json; charset=utf-8");
      res.writeHead(200);
      res.end(JSON.stringify(payload, null, 2));
    });
  } finally {
    span.end();
    console.log(
      JSON.stringify({
        level: shouldFail ? "error" : "info",
        message: "request served",
        color,
        version,
        path: req.url,
        statusCode: shouldFail ? 500 : 200,
        traceId,
        spanId,
        latencyMs: Date.now() - requestStartedAt,
      }),
    );
  }
});

await startTelemetry();

server.listen(port, "0.0.0.0", () => {
  console.log(`sample app listening on ${port} (${color}/${version})`);
});
