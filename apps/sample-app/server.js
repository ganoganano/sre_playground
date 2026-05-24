import http from "node:http";
import os from "node:os";

const port = Number(process.env.PORT || 8080);
const color = process.env.APP_COLOR || "blue";
const version = process.env.APP_VERSION || "v1";

const server = http.createServer((req, res) => {
  const payload = {
    service: "sre-playground-sample-app",
    color,
    version,
    hostname: os.hostname(),
    timestamp: new Date().toISOString(),
    path: req.url,
  };

  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.writeHead(200);
  res.end(JSON.stringify(payload, null, 2));
});

server.listen(port, "0.0.0.0", () => {
  console.log(`sample app listening on ${port} (${color}/${version})`);
});
