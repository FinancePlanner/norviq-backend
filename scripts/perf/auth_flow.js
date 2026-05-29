// Auth cost + rate-limiter behavior: register then login.
// bcrypt + JWT issuance is the expensive part; watch p95 climb under load.
// Run: k6 run scripts/perf/auth_flow.js
import http from "k6/http";
import { check, sleep } from "k6";

const BASE = __ENV.BASE_URL || "http://localhost:8090";

export const options = {
  vus: Number(__ENV.VUS || 10),
  duration: __ENV.DURATION || "30s",
  thresholds: {
    // 429s are expected once the rate limiter engages — track separately.
    http_req_duration: ["p(95)<800"],
  },
};

function rnd() {
  return Math.random().toString(36).slice(2, 10);
}

export default function () {
  const email = `perf_${rnd()}@example.com`;
  const password = "Perf-Test-Passw0rd!";
  const headers = { "Content-Type": "application/json" };

  const reg = http.post(
    `${BASE}/auth/register`,
    JSON.stringify({ email, username: `perf_${rnd()}`, password }),
    { headers }
  );
  check(reg, {
    "register handled": (r) => [200, 201, 409, 429].includes(r.status),
  });

  const login = http.post(
    `${BASE}/auth/login`,
    JSON.stringify({ email, password }),
    { headers }
  );
  check(login, {
    "login handled": (r) => [200, 401, 403, 429].includes(r.status),
  });

  sleep(1);
}

export function handleSummary(data) {
  return { "scripts/perf/out/auth_flow.json": JSON.stringify(data, null, 2) };
}
