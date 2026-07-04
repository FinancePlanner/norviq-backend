#!/usr/bin/env python3
"""Tiny read-only finance API over the finance SQLite store.

Run:
  python3 finance_api_server.py --db /root/.hermes/financial-pipeline/data/finance.sqlite --port 8765
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import re
import sqlite3
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit



def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--db", default=str(Path.home() / ".hermes" / "financial-pipeline" / "data" / "finance.sqlite"))
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    return p.parse_args()


def parse_window_days(qs) -> int:
    try:
        return max(1, int((qs.get("days", ["30"])[0])))
    except Exception:
        return 30


def as_iso(ts: datetime | None = None) -> str:
    return (ts or datetime.now(timezone.utc)).isoformat(timespec="seconds")


API_TOKEN = os.environ.get("FINANCE_API_TOKEN", "").strip()
# Routes reachable without a token (liveness probing and route discovery).
PUBLIC_PATHS = {"/healthz", "", "/"}

TICKER_SYMBOL_RE = re.compile(r"^[A-Z][A-Z0-9.\-]{0,9}$")

TICKER_POSTS_SCHEMA = """
CREATE TABLE IF NOT EXISTS ticker_posts (
    event_id TEXT PRIMARY KEY,
    symbol TEXT NOT NULL,
    author TEXT,
    author_handle TEXT,
    text TEXT,
    url TEXT,
    sentiment TEXT,
    sentiment_score REAL,
    confidence REAL,
    posted_at TEXT NOT NULL,
    ingested_at TEXT NOT NULL
)
"""
TICKER_POSTS_INDEX = (
    "CREATE INDEX IF NOT EXISTS idx_ticker_posts_symbol_posted "
    "ON ticker_posts (symbol, posted_at DESC)"
)


class FinanceHandler(BaseHTTPRequestHandler):
    db_path: str

    def _load_conn(self):
        return sqlite3.connect(self.db_path)

    def _json(self, payload: dict, status: int = 200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(json.dumps(payload, ensure_ascii=False).encode("utf-8"))

    def _err(self, msg: str, status: int = 400):
        self._json({"error": msg}, status)

    def _read(self, topic: str | None = None, days: int = 30, limit: int = 100):
        conn = self._load_conn()
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()

        where = ["1=1"]
        params = []
        if topic:
            where.append("topic = ?")
            params.append(topic)
        since = (datetime.now(timezone.utc) - timedelta(days=days)).date().isoformat()
        where.append("substr(ingested_at,1,10) >= ?")
        params.append(since)

        q = (
            "SELECT event_id, source, source_id, observed_at, ingested_at, topic, subcategory, payload, derived, sentiment, status, version "
            "FROM fin_event WHERE " + " AND ".join(where) + " ORDER BY ingested_at DESC LIMIT ?"
        )
        params.append(limit)
        rows = cur.execute(q, params).fetchall()
        conn.close()
        return rows

    def _authorized(self, path: str) -> bool:
        if not API_TOKEN or path in PUBLIC_PATHS:
            return True
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return False
        return hmac.compare_digest(header[len("Bearer "):].strip(), API_TOKEN)

    def do_GET(self):
        try:
            parsed = urlsplit(self.path)
            path = parsed.path.rstrip("/")
            qs = parse_qs(parsed.query)

            if not self._authorized(path):
                self._err("Unauthorized", 401)
                return

            if path == "/healthz":
                conn = self._load_conn()
                c = conn.cursor()
                try:
                    total = c.execute("SELECT COUNT(*) FROM fin_event").fetchone()[0]
                    self._json({"ok": True, "events": int(total), "generated_at": as_iso()})
                except Exception as e:
                    self._json({"ok": False, "error": str(e)}, 500)
                finally:
                    conn.close()
                return

            if path == "/finance/summary":
                days = parse_window_days(qs)
                rows = self._read(days=days, limit=5000)
                by_topic = {}
                total = 0
                latest = []
                for r in rows:
                    total += 1
                    by_topic[r["topic"]] = by_topic.get(r["topic"], 0) + 1
                    if len(latest) < 5:
                        latest.append({
                            "event_id": r["event_id"],
                            "source": r["source"],
                            "topic": r["topic"],
                            "ingested_at": r["ingested_at"],
                            "source_id": r["source_id"],
                        })
                self._json({
                    "window_days": days,
                    "generated_at": as_iso(),
                    "total_events": total,
                    "by_topic": by_topic,
                    "latest_events": latest,
                })
                return

            if path.startswith("/finance/topic/"):
                topic = path.split("/", 3)[-1]
                if not topic:
                    self._err("missing topic")
                    return
                days = parse_window_days(qs)
                limit = min(500, int(qs.get("limit", ["50"])[0]))
                rows = self._read(topic=topic, days=days, limit=limit)
                payload = []
                for r in rows:
                    payload.append({
                        "event_id": r["event_id"],
                        "source": r["source"],
                        "source_id": r["source_id"],
                        "topic": r["topic"],
                        "observed_at": r["observed_at"],
                        "ingested_at": r["ingested_at"],
                        "status": r["status"],
                    })
                self._json({
                    "topic": topic,
                    "window_days": days,
                    "count": len(payload),
                    "events": payload,
                })
                return

            if path.startswith("/finance/ticker/") and path.endswith("/posts"):
                symbol = path.split("/")[3].lstrip("$").upper()
                if not TICKER_SYMBOL_RE.match(symbol):
                    self._err("invalid symbol")
                    return
                days = parse_window_days(qs)
                limit = min(200, max(1, int(qs.get("limit", ["50"])[0])))
                since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat(timespec="seconds")
                conn = self._load_conn()
                conn.row_factory = sqlite3.Row
                try:
                    cur = conn.cursor()
                    cur.execute(TICKER_POSTS_SCHEMA)
                    cur.execute(TICKER_POSTS_INDEX)
                    rows = cur.execute(
                        "SELECT event_id, symbol, author, author_handle, text, url, sentiment, "
                        "sentiment_score, confidence, posted_at, ingested_at "
                        "FROM ticker_posts WHERE symbol = ? AND posted_at >= ? "
                        "ORDER BY posted_at DESC LIMIT ?",
                        (symbol, since, limit),
                    ).fetchall()
                finally:
                    conn.close()
                posts = [
                    {
                        "event_id": r["event_id"],
                        "author": r["author"],
                        "author_handle": r["author_handle"],
                        "text": r["text"],
                        "url": r["url"],
                        "sentiment": r["sentiment"] or "neutral",
                        "sentiment_score": r["sentiment_score"],
                        "confidence": r["confidence"],
                        "posted_at": r["posted_at"],
                    }
                    for r in rows
                ]
                self._json({
                    "symbol": symbol,
                    "days": days,
                    "count": len(posts),
                    "posts": posts,
                    "generated_at": as_iso(),
                })
                return

            if path == "/finance/net-worth":
                rows = self._read(topic="NetWorth", days=180, limit=200)
                history = []
                latest = None
                for r in rows:
                    derived = json.loads(r["derived"] or "{}"); payload = json.loads(r["payload"] or "{}")
                    value = derived.get("net_worth_estimate") or derived.get("net_worth")
                    if value is None:
                        # lightweight heuristic in case this was captured as text
                        summary = payload.get("title", "")
                        if value is None and summary:
                            import re
                            m = re.search(r"\$?([0-9]+(?:\.[0-9]+)?)", summary)
                            value = float(m.group(1)) if m else None
                    rec = {
                        "event_id": r["event_id"],
                        "ingested_at": r["ingested_at"],
                        "value": value,
                    }
                    if latest is None and value is not None:
                        latest = rec
                    history.append(rec)
                if latest is None:
                    latest = {"value": None, "event_id": None, "ingested_at": None}
                self._json({
                    "latest": latest,
                    "history": history[:20],
                    "generated_at": as_iso(),
                })
                return

            if path == "/finance/sentiment":
                topic = qs.get("topic", [None])[0]
                days = parse_window_days(qs)
                rows = self._read(topic=topic if topic else None, days=days, limit=5000)
                cnt = {"positive": 0, "neutral": 0, "negative": 0}
                score_sum = 0.0
                scored = 0
                for r in rows:
                    sent = json.loads(r["sentiment"] or "{}")
                    label = sent.get("label", "neutral")
                    cnt[label] = cnt.get(label, 0) + 1
                    if isinstance(sent.get("score"), (int, float)):
                        scored += 1
                        score_sum += float(sent["score"])
                avg = score_sum / scored if scored else 0.0
                self._json({
                    "topic": topic,
                    "window_days": days,
                    "count": sum(cnt.values()),
                    "label_counts": cnt,
                    "average_score": round(avg, 4),
                    "sampled": scored,
                })
                return

            if path == "/finance/events":
                limit = min(200, int(qs.get("limit", ["100"])[0]))
                rows = self._read(days=parse_window_days(qs), limit=limit)
                events = []
                for r in rows:
                    events.append({
                        "event_id": r["event_id"],
                        "source": r["source"],
                        "source_id": r["source_id"],
                        "topic": r["topic"],
                        "observed_at": r["observed_at"],
                        "ingested_at": r["ingested_at"],
                        "payload": json.loads(r["payload"] or "{}"),
                        "sentiment": json.loads(r["sentiment"] or "{}"),
                    })
                self._json({"count": len(events), "events": events})
                return

            if path in ("", "/"):
                self._json({
                    "service": "finance-api",
                    "routes": [
                        "/healthz",
                        "/finance/summary?days=30",
                        "/finance/topic/<topic>?days=30",
                        "/finance/net-worth",
                        "/finance/sentiment?topic=Stocks&days=30",
                        "/finance/events?days=30&limit=100",
                        "/finance/ticker/<symbol>/posts?days=14&limit=50",
                    ],
                })
                return

            self._err("Unknown route", 404)
        except Exception as e:
            self._json({"error": str(e)}, 500)


def run() -> None:
    args = parse_args()
    db_path = str(Path(args.db))

    server = ThreadingHTTPServer((args.host, args.port), FinanceHandler)
    FinanceHandler.db_path = db_path
    print(f"finance-api running at http://{args.host}:{args.port}")
    print(f"DB: {db_path}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    run()
