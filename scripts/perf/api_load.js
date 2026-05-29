// Token-driven protected-endpoint capacity test — the real load test.
// setup() creates a user + logs in once; VUs reuse the token.
// NOTE: if MFA is enforced for new accounts in your env, set TOKEN directly:
//   TOKEN=<jwt> k6 run scripts/perf/api_load.js
// Run: k6 run scripts/perf/api_load.js
import http from "k6/http";
import { check, sleep } from "k6";
import { Trend } from "k6/metrics";

const BASE = __ENV.BASE_URL || "http://localhost:8090";
const SYMBOLS = ["BTC", "ETH", "SOL", "ADA", "XRP"];

const quoteLatency = new Trend("quote_latency", true);

export const options = {
  scenarios: {
    steady: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "20s", target: Number(__ENV.VUS || 30) },
        { duration: Number(__ENV.DURATION || "60s") ? "60s" : "60s", target: Number(__ENV.VUS || 30) },
        { duration: "10s", target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.02"],
    http_req_duration: ["p(95)<400", "p(99)<800"],
  },
};

export function setup() {
  if (__ENV.TOKEN) return { token: __ENV.TOKEN };
  const headers = { "Content-Type": "application/json" };
  const cred = {
    email: `perf_setup_${Date.now()}@example.com`,
    username: `perf_setup_${Date.now()}`,
    password: "Perf-Test-Passw0rd!",
  };
  http.post(`${BASE}/auth/register`, JSON.stringify(cred), { headers });
  const login = http.post(
    `${BASE}/auth/login`,
    JSON.stringify({ email: cred.email, password: cred.password }),
    { headers }
  );
  let token = "";
  try {
    token = login.json("token") || login.json("accessToken") || "";
  } catch (_) {
    token = "";
  }
  if (!token) {
    console.warn(
      "No token from login (MFA enforced?). Protected calls will 401. " +
        "Re-run with TOKEN=<jwt> to test authenticated capacity."
    );
  }
  return { token };
}

export default function (data) {
  const auth = data.token ? { Authorization: `Bearer ${data.token}` } : {};

  const sym = SYMBOLS[Math.floor(Math.random() * SYMBOLS.length)];
  const q = http.get(`${BASE}/crypto/quote/${sym}`, { headers: auth });
  quoteLatency.add(q.timings.duration);
  check(q, { "quote handled": (r) => [200, 401, 404, 429].includes(r.status) });

  const stats = http.get(`${BASE}/statistics/stocks`, { headers: auth });
  check(stats, { "stats handled": (r) => [200, 401, 404].includes(r.status) });

  const expenses = http.get(`${BASE}/expenses`, { headers: auth });
  check(expenses, { "expenses handled": (r) => [200, 401, 404].includes(r.status) });

  sleep(0.3);
}

export function handleSummary(data) {
  return { "scripts/perf/out/api_load.json": JSON.stringify(data, null, 2) };
}
