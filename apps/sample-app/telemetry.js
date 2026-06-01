import { diag, DiagConsoleLogger, DiagLogLevel } from "@opentelemetry/api";
import { getNodeAutoInstrumentations } from "@opentelemetry/auto-instrumentations-node";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { resourceFromAttributes } from "@opentelemetry/resources";
import { NodeSDK } from "@opentelemetry/sdk-node";
import { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } from "@opentelemetry/semantic-conventions";

const serviceName = process.env.OTEL_SERVICE_NAME || "sre-playground-sample-app";
const serviceVersion = process.env.APP_VERSION || "v1";
const exporterUrl =
  process.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT ||
  process.env.OTEL_EXPORTER_OTLP_ENDPOINT ||
  "";
const logLevel = process.env.OTEL_DIAGNOSTIC_LOG_LEVEL || "error";

if (logLevel === "debug") {
  diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.DEBUG);
}

let sdkStarted = false;

export async function startTelemetry() {
  if (sdkStarted || !exporterUrl) {
    return;
  }

  const sdk = new NodeSDK({
    resource: resourceFromAttributes({
      [ATTR_SERVICE_NAME]: serviceName,
      [ATTR_SERVICE_VERSION]: serviceVersion,
      "deployment.environment": process.env.OTEL_ENVIRONMENT || "demo",
      "service.namespace": "sre-playground",
      "service.instance.id": `${process.env.APP_COLOR || "unknown"}-${process.pid}`,
    }),
    traceExporter: new OTLPTraceExporter({
      url: exporterUrl,
    }),
    instrumentations: [getNodeAutoInstrumentations()],
  });

  await sdk.start();
  sdkStarted = true;

  process.on("SIGTERM", async () => {
    await sdk.shutdown().catch(() => {});
    process.exit(0);
  });
}
