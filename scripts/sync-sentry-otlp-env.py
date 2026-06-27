#!/usr/bin/env python3
"""Derive SENTRY_OTLP_* from SENTRY_DSN for the OTel collector Sentry exporter."""
from __future__ import annotations

import re
import sys
from pathlib import Path

DSN_RE = re.compile(
    r"^https://([^@]+)@o(\d+)\.ingest\.([^.]+)\.sentry\.io/(\d+)$"
)


def derive_otlp(dsn: str) -> dict[str, str]:
    match = DSN_RE.match(dsn.strip())
    if not match:
        raise SystemExit(f"unsupported SENTRY_DSN format: {dsn!r}")
    key, org, region, project = match.groups()
    base = f"https://o{org}.ingest.{region}.sentry.io/api/{project}/integration/otlp/v1"
    return {
        "SENTRY_OTLP_TRACES_ENDPOINT": f"{base}/traces",
        "SENTRY_OTLP_LOGS_ENDPOINT": f"{base}/logs",
        "SENTRY_OTLP_AUTH_HEADER": f"sentry sentry_key={key}",
    }


def upsert_env(path: Path, updates: dict[str, str]) -> None:
    lines = path.read_text().splitlines() if path.exists() else []
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        if not line or line.startswith("#") or "=" not in line:
            out.append(line)
            continue
        key, _ = line.split("=", 1)
        if key in updates:
            out.append(f"{key}={updates[key]}")
            seen.add(key)
        else:
            out.append(line)
    for key, value in updates.items():
        if key not in seen:
            out.append(f"{key}={value}")
    path.write_text("\n".join(out).rstrip() + "\n")


def main() -> None:
    env_file = Path(sys.argv[1] if len(sys.argv) > 1 else ".env.production")
    if not env_file.exists():
        raise SystemExit(f"env file not found: {env_file}")

    values = {
        line.split("=", 1)[0]: line.split("=", 1)[1]
        for line in env_file.read_text().splitlines()
        if line and not line.startswith("#") and "=" in line
    }
    dsn = values.get("SENTRY_DSN", "").strip()
    if not dsn:
        raise SystemExit(f"SENTRY_DSN is not set in {env_file}")

    updates = derive_otlp(dsn)
    upsert_env(env_file, updates)
    print(f"Updated SENTRY_OTLP_* in {env_file}")


if __name__ == "__main__":
    main()
