#!/usr/bin/env python3
"""Score vision models on real screenshots and receipts before we build UI on them.

The gate from the image-import plan: if no model reads symbols and share counts
reliably, a review screen that is wrong half the time is worse than typing the
positions in by hand, and that finding is the deliverable.

This talks to OpenRouter directly with the *same prompts the backend uses*, so a
model can be compared without deploying anything. Keep the prompts in sync with:
  Sources/StockPlanBackend/Broker/ScreenshotPortfolioExtractor.swift
  Sources/StockPlanBackend/Receipts/OpenAIVisionReceiptOCRProvider.swift

Usage:
    export OPENROUTER_API_KEY=...            # or source ~/.deepapi/env style env
    scripts/vision_eval.py portfolio fixtures/portfolio
    scripts/vision_eval.py receipts  fixtures/receipts --models openai/gpt-4o-mini

Fixtures: a directory of images. Put the expected answer beside each image as
`<image>.expected.json` to get scoring; without it the script just prints what
each model saw, which is still the fastest way to eyeball a prompt change.

  AAPL-holdings.png
  AAPL-holdings.png.expected.json  ->  {"kind":"holdings","rows":[{"symbol":"AAPL","shares":10}]}
"""

from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

DEFAULT_MODELS = ["openai/gpt-4o-mini", "anthropic/claude-haiku-4.5"]
API_URL = "https://openrouter.ai/api/v1/chat/completions"

PORTFOLIO_PROMPT = """\
You read a screenshot from a stock broker or investing app and turn it into \
structured rows. Respond with a single JSON object and nothing else:
{"kind": "holdings" | "trades" | "unknown",
 "rows": [{"symbol": string, "shares": number|null, "buyPrice": number|null, \
"buyDate": string|null (YYYY-MM-DD), "confidence": number (0..1)}]}

First classify:
- "holdings": a positions or portfolio list — what the user owns right now.
- "trades": trade confirmations, order history or executions — individual \
buys and sells with a price and a date.
- "unknown": anything else (a chart, a news screen, a watchlist with no \
quantities, a bank statement), or an image too blurred or cropped to read. \
Return "unknown" with an empty rows array. Do not force a classification.

Then extract, one row per visible position or trade:
- "symbol" is the exchange ticker, uppercase, without the exchange prefix or \
suffix (write "AAPL", not "NASDAQ:AAPL" or "AAPL.US"). If only a company name \
is shown and you are not certain of its ticker, skip the row.
- "shares" is the quantity held or traded. Fractional values are normal.
- For kind "holdings": set "buyPrice" ONLY if the screen explicitly labels a \
cost basis, average cost or average price. A last price, market price, current \
value or day-change figure is NOT a buy price — set null. This is the single \
most damaging mistake you can make here.
- For kind "trades": "buyPrice" is the execution price per share and "buyDate" \
the execution date. Include only BUY rows; skip sells, dividends and fees.
- "confidence" is your own 0..1 certainty for that row's numbers.
- Never guess a number. Null is always better than a plausible invention — \
these values become someone's financial records."""

RECEIPT_PROMPT = """\
You extract structured data from a photographed shop receipt. Respond with a \
single JSON object and nothing else, using exactly these keys (use null when a \
value is not clearly legible — never guess):
{"merchant": string|null, "total": number|null, "currency": string|null (ISO 4217, e.g. "EUR"), \
"date": string|null (YYYY-MM-DD), "taxId": string|null (merchant tax/VAT id), \
"taxTotal": number|null (total VAT/tax amount), \
"lineItems": [{"description": string, "amount": number, "quantity": number|null}]}
Amounts are numbers without currency symbols. If the image is not a receipt, \
return all null values and an empty lineItems array.

lineItems rules:
- One entry per purchased article, in the order printed.
- "amount" is the line total as printed, with quantity already applied. Do not \
multiply it yourself.
- "quantity" only when the receipt states units; otherwise null.
- Omit non-article lines: subtotals, totals, VAT summaries, discounts applied \
to the whole basket, loyalty points, change given, payment method lines.
- If the articles are not legible enough to read individually, return an empty \
array. A partial list is worse than none, because the totals will not reconcile."""

TASKS = {
    "portfolio": (PORTFOLIO_PROMPT, "Classify this screenshot and extract its rows. Return the JSON object.", 3000),
    "receipts": (RECEIPT_PROMPT, "Extract the fields from this receipt image and return the JSON object.", 2000),
}


def call_model(model: str, system: str, user: str, image: pathlib.Path, max_tokens: int, api_key: str) -> tuple[dict | None, str]:
    mime = mimetypes.guess_type(image.name)[0] or "image/jpeg"
    data_url = f"data:{mime};base64,{base64.b64encode(image.read_bytes()).decode()}"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": [{"type": "text", "text": system}]},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": user},
                    {"type": "image_url", "image_url": {"url": data_url}},
                ],
            },
        ],
        "temperature": 0,
        "max_tokens": max_tokens,
        "response_format": {"type": "json_object"},
    }
    req = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = json.load(resp)
    except urllib.error.HTTPError as exc:
        return None, f"HTTP {exc.code}: {exc.read()[:200].decode(errors='replace')}"
    except Exception as exc:  # noqa: BLE001 - a harness; report and move on
        return None, str(exc)

    text = (body.get("choices") or [{}])[0].get("message", {}).get("content")
    if not text:
        return None, "empty completion"
    try:
        return json.loads(text), ""
    except json.JSONDecodeError as exc:
        return None, f"undecodable JSON: {exc}"


def score_portfolio(got: dict, want: dict) -> tuple[int, int, list[str]]:
    """Field-level score. Notes call out the mistakes that cost money."""
    hits = total = 0
    notes: list[str] = []

    total += 1
    if got.get("kind") == want.get("kind"):
        hits += 1
    else:
        notes.append(f"kind {got.get('kind')!r} != {want.get('kind')!r}")

    want_rows = {r["symbol"].upper(): r for r in want.get("rows", [])}
    got_rows = {str(r.get("symbol", "")).upper(): r for r in got.get("rows", [])}

    for symbol, wrow in want_rows.items():
        total += 1
        grow = got_rows.get(symbol)
        if grow is None:
            notes.append(f"{symbol}: missed")
            continue
        hits += 1
        for field in ("shares", "buyPrice", "buyDate"):
            if field not in wrow:
                continue
            total += 1
            if _close(grow.get(field), wrow.get(field)):
                hits += 1
            else:
                notes.append(f"{symbol}.{field}: {grow.get(field)!r} != {wrow.get(field)!r}")

    for symbol in got_rows.keys() - want_rows.keys():
        total += 1
        notes.append(f"{symbol}: invented")

    # An invented cost basis on a holdings screen is the failure mode that
    # silently corrupts gain/loss, so surface it separately from a plain miss.
    if want.get("kind") == "holdings":
        for symbol, grow in got_rows.items():
            if grow.get("buyPrice") is not None:
                notes.append(f"{symbol}: DANGEROUS — buyPrice on a holdings screen")

    return hits, total, notes


def score_receipt(got: dict, want: dict) -> tuple[int, int, list[str]]:
    hits = total = 0
    notes: list[str] = []
    for field in ("merchant", "total", "currency", "date", "taxId", "taxTotal"):
        if field not in want:
            continue
        total += 1
        if _close(got.get(field), want.get(field)):
            hits += 1
        else:
            notes.append(f"{field}: {got.get(field)!r} != {want.get(field)!r}")

    if "lineItems" in want:
        want_items = want["lineItems"]
        got_items = got.get("lineItems") or []
        total += 1
        if len(got_items) == len(want_items):
            hits += 1
        else:
            notes.append(f"lineItems count {len(got_items)} != {len(want_items)}")
        if got_items and got.get("total") is not None:
            line_sum = sum(i.get("amount") or 0 for i in got_items)
            if abs(line_sum - got["total"]) >= 0.01:
                notes.append(f"lineItems sum {line_sum:.2f} != total {got['total']:.2f} (would not reconcile)")
    return hits, total, notes


def _close(got, want) -> bool:
    if isinstance(want, (int, float)) and isinstance(got, (int, float)):
        return abs(got - want) < 0.01
    if isinstance(want, str) and isinstance(got, str):
        return got.strip().upper() == want.strip().upper()
    return got == want


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("task", choices=sorted(TASKS))
    parser.add_argument("fixtures", type=pathlib.Path)
    parser.add_argument("--models", nargs="+", default=DEFAULT_MODELS)
    parser.add_argument("--verbose", action="store_true", help="print raw model output for every image")
    args = parser.parse_args()

    api_key = os.environ.get("OPENROUTER_API_KEY") or os.environ.get("AI_API_KEY")
    if not api_key:
        print("Set OPENROUTER_API_KEY.", file=sys.stderr)
        return 2

    images = sorted(
        p for p in args.fixtures.iterdir()
        if p.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp", ".heic"}
    )
    if not images:
        print(f"No images in {args.fixtures}.", file=sys.stderr)
        return 2

    system, user, max_tokens = TASKS[args.task]
    scorer = score_portfolio if args.task == "portfolio" else score_receipt
    summary: dict[str, tuple[int, int, int, float]] = {}

    for model in args.models:
        print(f"\n=== {model} ===")
        hits = total = failures = 0
        started = time.monotonic()
        for image in images:
            got, err = call_model(model, system, user, image, max_tokens, api_key)
            if got is None:
                failures += 1
                print(f"  {image.name}: FAILED — {err}")
                continue
            if args.verbose:
                print(f"  {image.name}: {json.dumps(got, ensure_ascii=False)}")

            expected_path = image.with_suffix(image.suffix + ".expected.json")
            if not expected_path.exists():
                if not args.verbose:
                    print(f"  {image.name}: {json.dumps(got, ensure_ascii=False)[:160]}  (no expectation)")
                continue

            want = json.loads(expected_path.read_text())
            h, t, notes = scorer(got, want)
            hits += h
            total += t
            mark = "ok " if h == t else "BAD"
            print(f"  {mark} {image.name}: {h}/{t}")
            for note in notes:
                print(f"        - {note}")
        elapsed = time.monotonic() - started
        summary[model] = (hits, total, failures, elapsed)

    print("\n=== summary ===")
    for model, (hits, total, failures, elapsed) in summary.items():
        pct = f"{100 * hits / total:.1f}%" if total else "n/a (no expectations)"
        print(f"  {model:40s} {pct:>22s}  {hits}/{total} fields, {failures} call failures, {elapsed:.0f}s")
    print("\nGate: below ~90% on symbol and share count, do not ship the review UI.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
