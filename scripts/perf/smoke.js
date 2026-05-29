// Public/unauthenticated smoke + middleware-overhead floor.
// Run: k6 run scripts/perf/smoke.js
import http from "k6/http";
import { check, sleep } from "k6";

const BASE = __ENV.BASE_URL || "http://localhost:8090";

export const options = {
  vus: Number(__ENV.VUS || 20),
  duration: __ENV.DURATION || "30s",
  thresholds: {
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(95)<150", "p(99)<300"],
  },
};

export default function () {
  const health = http.get(`${BASE}/health`);
  check(health, { "health 200": (r) => r.status === 200 });

  const ready = http.get(`${BASE}/health/ready`);
  check(ready, { "ready 200/503": (r) => r.status === 200 || r.status === 503 });

  const hello = http.get(`${BASE}/api/hello`);
  check(hello, { "hello reachable": (r) => r.status === 200 || r.status === 404 });

  sleep(0.5);
}

export function handleSummary(data) {
  return { "scripts/perf/out/smoke.json": JSON.stringify(data, null, 2) };
}
