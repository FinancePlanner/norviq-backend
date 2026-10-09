# Terminal Position Sizing (Web) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `/terminal` in norviq-web: a dense, inline-editable planning table, an autobuys side panel, Pro AI suggestions, a dashboard summary card and a per-stock card. All of it is rendered from the backend's terminal-positions API, and the backend does every calculation.

**Architecture:** A per-feature oapi-codegen slice (`internal/api/terminalapi`) talks to `/v1/terminal-positions*` and `/v1/autobuys*`. Handlers in `internal/handlers/terminal_*.go` turn backend responses into view models of preformatted strings, using a new `internal/format` package. templ components in `internal/pages/terminal` render them. Every cell edit sends an htmx `hx-patch`. The server answers with that row re-rendered plus the footer out of band. Alpine handles only display state (compact labels on blur, the round-down toggle, autobuy form prefill).

**Tech Stack:** Go 1.27, chi v5, templ, htmx 4.0.0, Alpine 3.15, templUI wrappers (`internal/pages/components/field.templ`), oapi-codegen v2.8.0, testify and `httptest` fake backends.

**Spec:** `/Users/fernandocorreiachill/Work/production/apps/norviq/norviq-backend-terminal/docs/superpowers/specs/2026-10-09-terminal-position-sizing-design.md` (section 3 "Web")

**Contract (exact DTO fields, endpoints, copy):** `/Users/fernandocorreiachill/Work/production/apps/norviq/norviq-backend-terminal/docs/superpowers/plans/2026-10-09-terminal-contract.md`

## Global Constraints

- **Workspace:** use a new git worktree of norviq-web at `/Users/fernandocorreiachill/Work/production/apps/norviq/norviq-web-terminal`, on branch `feat/terminal-positions` off `origin/main`. Task 1 Step 0 creates it. Every command below runs from that worktree root. Never edit `/Users/fernandocorreiachill/Work/production/apps/norviq/norviq-web` (the main checkout).
- **Git:** you may commit at the end of each task. Do **not** push, and do not open a PR. Pushing and the PR are Task 11's last step, and they happen only after the user explicitly approves.
- **Backend dependency:** the backend API is built by a separate plan. This plan assumes the endpoints and DTOs in the contract exist exactly as written. Tests run only against `httptest` fake backends: no real API, no staging calls. Task 2 needs the backend PR's `openapi.yaml`, which contains operationIds `listTerminalPositions`, `createTerminalPosition`, `updateTerminalPosition`, `deleteTerminalPosition`, `duplicateTerminalPosition`, `reorderTerminalPositions`, `getTerminalPositionsSummary`, `listAutobuys`, `createAutobuy`, `updateAutobuy`, `deleteAutobuy`, `suggestTerminalShareFacts`, `suggestTerminalScenario`.
- **Go toolchain:** prefix every `go` and `make` command with `GOFLAGS=-mod=mod` (there is a stale vendor dir in the main checkout, and the worktree has none). Run `templ generate` after every `.templ` edit. Commit the generated `*_templ.go` files, because `make check` fails on any `*_templ.go` diff. Commit `client.gen.go` too.
- **Assets:** `internal/server/server.go` embeds `static/styles.css`, so run `make assets` once in the new worktree before the first `go test`. It runs `bun install --frozen-lockfile` and a Parcel build.
- **The server is the only calculator.** No sizing formula may appear in Go or JS. Handlers format backend numbers. The display-only "round down to whole shares" applies `floor` to each displayed share count, which is formatting and not a formula (contract: `TerminalMath.wholeShares` = floor, never below 0).
- **Copy, verbatim (contract):** Title "Terminal position sizing". Subtitle "Decide the future market cap and share count. Norviq tells you how many shares that target is." Disclaimer "Terminal prices are your assumptions, not forecasts. Not financial advice." pt-PT: "Dimensionamento de posições terminais" / "Define a capitalização bolsista e o número de ações futuros. O Norviq diz-te quantas ações esse objetivo representa." / "Os preços terminais são pressupostos teus, não previsões. Não é aconselhamento financeiro." The nav label is "Terminal sizing" (pt-PT "Dimensionamento terminal"). Only the title, subtitle, disclaimer and nav label go through `i18n.T`. Other page copy is hardcoded English, as on every other page.
- **The disclaimer is on every surface:** the `/terminal` page, the dashboard card and the stock card.
- **Controls:** every `<input>`, `<select>`, `<textarea>` and `<button>` goes through the wrappers in `internal/pages/components/field.templ` (`Field`, `SelectField`, `SwitchField`, `NativeButton`, `PrimaryButton`, `SecondaryButton`, `GhostButton`, `SubmitButton`). The one exception is `<input type="hidden" .../>`, written on a single line. `scripts/check-no-bare-controls.sh` must not go up.
- **htmx 4 rules:**
  - Attributes do not inherit unless written `attr:inherited`, so put `hx-target` and `hx-swap` on every control.
  - `internal/pages/components/htmx.templ` sets `noSwap` for 4xx/5xx. Any handler whose body is a message for the reader must answer **200**.
  - After an `outerHTML` swap, htmx restores focus to the element with the same `id`, so every editable input has a stable id.
- **Pro gate (contract correction, 2026-10-09):** a non-Pro AI call returns **HTTP 403** with JSON `{"success":false,"code":"upgrade_required",...}`, not 402. Detect an upgrade by `code == "upgrade_required"`, because a bare 403 can also mean a missing scope. 503 means "AI lookup unavailable". 422 means the AI answer was unusable.
- **AI only suggests.** Nothing is written until the user clicks Accept. Accept reuses the row PATCH. Autobuy example chips prefill the add form and never create anything.
- **Generated package name:** `terminalapi` (spec text says `internal/api/terminal`). This deliberately follows `pilotsapi`, so handlers can import it beside `internal/pages/terminal` without an alias.
- **Lint:** golangci-lint v2 config is in `.golangci.yml`: govet shadow, revive (no shadowing builtins such as `clear`), misspell US, noctx (tests use `httptest.NewRequestWithContext`).

## Review Focus

1. **Numbers typed the pt-PT way or with suffixes** ("1,25", "1.234,56", "10T", "$1,000,000"). Expected: saved at the intended magnitude, never 1000× off. The ambiguous "1.100" reads as 1.1, as in en. Pinned in Task 1 (`TestParseAmount`) and Task 5 (`TestTerminalCellEditParsesCompactAndPtPTAmounts`).
2. **Emptying an optional cell** (shares outstanding, current price). Expected: the PATCH sends `clear`, never `0`, so the value really goes away. Pinned in Task 5 (`TestTerminalCellEditClearsAnEmptiedOptionalField`).
3. **Owning more shares than needed** (progress over 100%). Expected: the bar clamps at full width, the label shows the real percent ("120%"), and still needed is 0. Pinned in Task 3 (`TestTerminalRowVMClampsTheBarButNotTheLabelWhenOverFunded`).
4. **AI source URLs with a non-https scheme** (`javascript:`, `http:`). Expected: never rendered as links. Pinned in Task 8 (`TestTerminalAIFactsShowsOnlyHTTPSSources`).
5. **Backend failure behind the lazy dashboard and stock cards.** Expected: the host page renders, the card hides itself, and there is no error box. Pinned in Task 9 (`TestDashboardTerminalSummaryHidesOnBackendFailure`) and Task 10 (`TestStockTerminalHidesOnBackendFailure`).

---

## File Structure

| File | Responsibility |
|---|---|
| `internal/format/format.go` (+ `_test.go`) | Compact amounts with T/B/M/K, currency code → symbol, grouped numbers, percent, whole-share floor, input-safe full numbers, and parsing typed amounts. Shared and new; replaces nothing yet. |
| `oapi-codegen-terminal.yaml`, `Makefile` | The per-feature client slice, chained into `oapi-codegen-local`. |
| `internal/api/terminalapi/client.gen.go` (+ `terminalapi_test.go`) | Generated client, plus decode/encode pins. |
| `internal/pages/terminal/vm.go` | View model types, cadence constants, sample-row constants. |
| `internal/pages/terminal/helpers.go` | Template helpers: ids, htmx attribute sets, Alpine expressions. |
| `internal/pages/terminal/page.templ` | Page, workspace region, create form, footer. |
| `internal/pages/terminal/row.templ` | Scenario row (`<tbody>`), sample row, row-update fragment. |
| `internal/pages/terminal/autobuys.go`, `autobuys.templ` | Autobuys panel, forms, example chips. |
| `internal/pages/terminal/ai_vm.go`, `ai.templ` | AI suggestion panel. |
| `internal/handlers/terminal_client.go` | Client construction, auth editor, ids, ticker rule, backend error helpers, copy. |
| `internal/handlers/terminal_map.go` | Backend DTO → view model formatting (pure). |
| `internal/handlers/terminal.go` | Route table (`MountTerminalRoutes`), page handler, workspace loader. |
| `internal/handlers/terminal_update.go` | Cell PATCH. |
| `internal/handlers/terminal_actions.go` | Create, duplicate, delete, move, sample dismiss. |
| `internal/handlers/terminal_autobuys.go` | Autobuy CRUD and the active toggle. |
| `internal/handlers/terminal_ai.go` | Share-facts and scenario suggestions. |
| `internal/handlers/dashboard_terminal.go`, `internal/pages/dashboard/terminal_summary.{go,templ}` | Dashboard card. |
| `internal/handlers/stock_terminal.go`, `internal/pages/stock/terminal_card.{go,templ}` | Stock overview card. |
| `internal/server/assets/terminal.js` | Alpine components (display only). |
| `internal/nav/nav.go`, `internal/i18n/locales/*.json`, `scripts/generate-i18n.py` | Nav entry and translations. |
| `internal/server/server.go`, `internal/server/terminal_routes_test.go` | Mount the route table and pin it. |

---

### Task 1: `internal/format` package (and the worktree)

**Files:**
- Create: `internal/format/format.go`
- Test: `internal/format/format_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces (package `format`, import `github.com/FinancePlanner/StockPlanWeb/internal/format`):
  - `const Dash = "—"`
  - `var ErrEmpty, ErrNotNumber error`
  - `func CurrencySymbol(code string) string`
  - `func Compact(v float64) string`
  - `func CompactCurrency(v float64, code string) string`
  - `func Number(v float64, maxDecimals int) string`
  - `func Currency(v float64, code string) string`
  - `func Percent(ratio float64) string`
  - `func WholeShares(shares float64) float64`
  - `func InputNumber(v float64) string`
  - `func ParseAmount(raw string) (float64, error)`

- [ ] **Step 0: Create the worktree and build assets**

```bash
git -C /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-web fetch origin
git -C /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-web worktree add /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-web-terminal -b feat/terminal-positions origin/main
cd /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-web-terminal && make assets
```
Expected: the worktree exists on `feat/terminal-positions`, and `internal/server/static/styles.css` exists.

- [ ] **Step 1: Write the failing test**

`internal/format/format_test.go`:
```go
package format

import (
	"math"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCompact(t *testing.T) {
	t.Parallel()
	cases := map[float64]string{
		10e12:     "10T",
		1.25e9:    "1.25B",
		11e9:      "11B",
		10.6e9:    "10.6B",
		1e6:       "1M",
		2_916_670: "2.92M",
		1500:      "1.5K",
		999_999:   "1M",
		999.999:   "1K",
		909.0909:  "909.09",
		0:         "0",
		-1500:     "-1.5K",
		-0.001:    "0",
	}
	for in, want := range cases {
		assert.Equal(t, want, Compact(in), "Compact(%v)", in)
	}
	assert.Equal(t, Dash, Compact(math.NaN()))
	assert.Equal(t, Dash, Compact(math.Inf(1)))
}

func TestCompactCurrency(t *testing.T) {
	t.Parallel()
	assert.Equal(t, "$10T", CompactCurrency(10e12, "USD"))
	assert.Equal(t, "€1.25B", CompactCurrency(1.25e9, "EUR"))
	assert.Equal(t, "SEK 1.5K", CompactCurrency(1500, "SEK"))
	assert.Equal(t, "-$1.5K", CompactCurrency(-1500, "USD"))
	assert.Equal(t, "1M", CompactCurrency(1e6, ""))
	assert.Equal(t, Dash, CompactCurrency(math.NaN(), "USD"))
}

func TestCurrencySymbol(t *testing.T) {
	t.Parallel()
	assert.Equal(t, "$", CurrencySymbol("usd"))
	assert.Equal(t, "€", CurrencySymbol(" EUR "))
	assert.Equal(t, "£", CurrencySymbol("GBP"))
	assert.Equal(t, "CHF ", CurrencySymbol("CHF"))
	assert.Equal(t, "SEK ", CurrencySymbol("SEK"))
	assert.Equal(t, "", CurrencySymbol(""))
}

func TestNumber(t *testing.T) {
	t.Parallel()
	assert.Equal(t, "1,100", Number(1100, 2))
	assert.Equal(t, "909.09", Number(909.0909, 2))
	assert.Equal(t, "2,916.67", Number(2916.666, 2))
	assert.Equal(t, "1,234,567.5", Number(1234567.5, 2))
	assert.Equal(t, "1,100", Number(1099.6, 0))
	assert.Equal(t, "0", Number(0.004, 2))
	assert.Equal(t, "0", Number(-0.004, 2))
	assert.Equal(t, "-1,234.5", Number(-1234.5, 2))
	assert.Equal(t, Dash, Number(math.NaN(), 2))
}

func TestCurrency(t *testing.T) {
	t.Parallel()
	assert.Equal(t, "$909.09", Currency(909.0909090909091, "USD"))
	assert.Equal(t, "$204,050", Currency(204050, "USD"))
	assert.Equal(t, "$185.50", Currency(185.5, "USD"))
	assert.Equal(t, "$318,181.82", Currency(318181.8181818182, "USD"))
	assert.Equal(t, "-€12.50", Currency(-12.5, "EUR"))
	assert.Equal(t, "$0", Currency(0, "USD"))
	assert.Equal(t, "$0", Currency(-0.001, "USD"))
	assert.Equal(t, "185.50", Currency(185.5, ""))
	assert.Equal(t, Dash, Currency(math.Inf(-1), "USD"))
}

func TestPercent(t *testing.T) {
	t.Parallel()
	assert.Equal(t, "68.18%", Percent(0.6818181818181818))
	assert.Equal(t, "0%", Percent(0))
	assert.Equal(t, "120%", Percent(1.2))
	assert.Equal(t, Dash, Percent(math.NaN()))
}

func TestWholeShares(t *testing.T) {
	t.Parallel()
	assert.InDelta(t, 1100.0, WholeShares(1100), 0)
	assert.InDelta(t, 1099.0, WholeShares(1099.6), 0)
	assert.InDelta(t, 0.0, WholeShares(-3), 0)
	assert.InDelta(t, 0.0, WholeShares(math.NaN()), 0)
}

func TestInputNumber(t *testing.T) {
	t.Parallel()
	assert.Equal(t, "10000000000000", InputNumber(10e12))
	assert.Equal(t, "185.5", InputNumber(185.5))
	assert.Equal(t, "0", InputNumber(0))
	assert.Equal(t, "", InputNumber(math.NaN()))
}

func TestParseAmount(t *testing.T) {
	t.Parallel()
	ok := map[string]float64{
		"1100":       1100,
		"1,100":      1100,
		"1,25":       1.25,
		"1.234,56":   1234.56,
		"1,234.56":   1234.56,
		"1.234.567":  1234567,
		"1.100":      1.1,
		"10T":        10e12,
		"11B":        11e9,
		"1.25b":      1.25e9,
		"$1,000,000": 1e6,
		" 750 ":      750,
		"€ 2,5K":     2500,
		"-5":         -5,
	}
	for raw, want := range ok {
		got, err := ParseAmount(raw)
		require.NoError(t, err, raw)
		assert.InDelta(t, want, got, 1e-9*math.Max(1, math.Abs(want)), raw)
	}
	for _, raw := range []string{"", "   "} {
		_, err := ParseAmount(raw)
		assert.ErrorIs(t, err, ErrEmpty, raw)
	}
	for _, raw := range []string{"abc", "1,2,3", "NaN", "Inf", "T", "$"} {
		_, err := ParseAmount(raw)
		assert.ErrorIs(t, err, ErrNotNumber, raw)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `GOFLAGS=-mod=mod go test ./internal/format/ -count=1`
Expected: FAIL to compile with `undefined: Compact` (and the other functions).

- [ ] **Step 3: Write the implementation**

`internal/format/format.go`:
```go
// Package format renders numbers for Norviq pages and parses the amounts
// people type back into numbers.
//
// It is the shared home the scattered helpers in internal/handlers
// (formatCompactNumber, formatCurrency, formatBudgetCurrency, ...) should move
// to. Nothing is migrated yet: terminal position sizing is the first caller.
package format

import (
	"errors"
	"math"
	"strconv"
	"strings"
)

// Dash stands in for a value that does not exist: no price yet, or a scenario
// the backend could not compute.
const Dash = "—"

var (
	// ErrEmpty is returned by ParseAmount for a blank input.
	ErrEmpty = errors.New("format: empty amount")
	// ErrNotNumber is returned by ParseAmount for anything that is not a
	// finite number.
	ErrNotNumber = errors.New("format: not a number")
)

var currencySymbols = map[string]string{
	"USD": "$",
	"EUR": "€",
	"GBP": "£",
	"JPY": "¥",
	"BRL": "R$",
	"CAD": "CA$",
	"AUD": "A$",
	"CHF": "CHF ",
}

type compactUnit struct {
	size   float64
	suffix string
}

// Largest first: Compact takes the first unit the value reaches.
var compactUnits = []compactUnit{{1e12, "T"}, {1e9, "B"}, {1e6, "M"}, {1e3, "K"}}

func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }

func round2(v float64) float64 { return math.Round(v*100) / 100 }

func trim(v float64) string { return strconv.FormatFloat(v, 'f', -1, 64) }

// CurrencySymbol maps an ISO 4217 code to the symbol shown before an amount.
// An unknown code is shown as the code and a space ("SEK "); an empty code
// shows no symbol.
func CurrencySymbol(code string) string {
	code = strings.ToUpper(strings.TrimSpace(code))
	if code == "" {
		return ""
	}
	if symbol, ok := currencySymbols[code]; ok {
		return symbol
	}
	return code + " "
}

// Compact renders 10000000000000 as "10T" and 1250000000 as "1.25B": at most
// two decimals, no trailing zeros. A value that rounds up to 1000 of a unit
// moves to the next unit, so 999999 is "1M" rather than "1000K".
func Compact(v float64) string {
	if !finite(v) {
		return Dash
	}
	sign := ""
	if v < 0 {
		sign, v = "-", -v
	}
	for i, unit := range compactUnits {
		if v < unit.size {
			continue
		}
		if scaled := round2(v / unit.size); scaled < 1000 || i == 0 {
			return sign + trim(scaled) + unit.suffix
		}
		bigger := compactUnits[i-1]
		return sign + trim(round2(v/bigger.size)) + bigger.suffix
	}
	r := round2(v)
	switch {
	case r == 0:
		return "0"
	case r >= 1000:
		return sign + "1K"
	default:
		return sign + trim(r)
	}
}

// CompactCurrency is Compact with the currency symbol: "$10T", "-€1.5K".
func CompactCurrency(v float64, code string) string {
	if !finite(v) {
		return Dash
	}
	compact := Compact(math.Abs(v))
	if v < 0 && compact != "0" {
		return "-" + CurrencySymbol(code) + compact
	}
	return CurrencySymbol(code) + compact
}

// group inserts thousands separators into a run of digits.
func group(digits string) string {
	if len(digits) <= 3 {
		return digits
	}
	var b strings.Builder
	lead := len(digits) % 3
	if lead > 0 {
		b.WriteString(digits[:lead])
	}
	for i := lead; i < len(digits); i += 3 {
		if b.Len() > 0 {
			b.WriteByte(',')
		}
		b.WriteString(digits[i : i+3])
	}
	return b.String()
}

// Number renders v with thousands separators and up to maxDecimals decimals,
// trailing zeros dropped: 1100 → "1,100", 909.0909 → "909.09".
func Number(v float64, maxDecimals int) string {
	if !finite(v) {
		return Dash
	}
	s := strconv.FormatFloat(math.Abs(v), 'f', maxDecimals, 64)
	whole, frac, _ := strings.Cut(s, ".")
	frac = strings.TrimRight(frac, "0")
	out := group(whole)
	if frac != "" {
		out += "." + frac
	}
	if v < 0 && strings.Trim(out, "0.,") != "" {
		out = "-" + out
	}
	return out
}

// Currency renders a money amount: exactly two decimals, or none when they are
// both zero. "$909.09", "$204,050", "$185.50".
func Currency(v float64, code string) string {
	if !finite(v) {
		return Dash
	}
	s := strconv.FormatFloat(math.Abs(v), 'f', 2, 64)
	whole, frac, _ := strings.Cut(s, ".")
	out := CurrencySymbol(code) + group(whole)
	if frac != "00" {
		out += "." + frac
	}
	if v < 0 && s != "0.00" {
		out = "-" + out
	}
	return out
}

// Percent renders a ratio (0.6818) as "68.18%". Values above 1 stay above 100%.
func Percent(ratio float64) string {
	if !finite(ratio) {
		return Dash
	}
	return Number(ratio*100, 2) + "%"
}

// WholeShares is the display-only "round down to whole shares": floor, never
// below zero. It mirrors TerminalMath.wholeShares in norviq-shared.
func WholeShares(shares float64) float64 {
	if !finite(shares) || shares <= 0 {
		return 0
	}
	return math.Floor(shares)
}

// InputNumber renders the full number an input should hold and submit: no
// separators, no exponent. 1e13 → "10000000000000".
func InputNumber(v float64) string {
	if !finite(v) {
		return ""
	}
	return strconv.FormatFloat(v, 'f', -1, 64)
}

var amountNoise = strings.NewReplacer("$", "", "€", "", "£", "", "¥", "", " ", "", " ", "", "_", "")

var amountSuffixes = map[string]float64{"K": 1e3, "M": 1e6, "B": 1e9, "T": 1e12}

// ParseAmount reads what a person typed into an amount cell: currency
// symbols and spaces are ignored, a trailing K/M/B/T scales the number, and
// both "1,234.56" and "1.234,56" are understood. A lone comma followed by
// exactly three digits ("1,100") is a thousands separator; any other lone
// comma ("1,25") is a decimal comma. A lone dot is always a decimal point, so
// "1.100" is 1.1, as in en.
func ParseAmount(raw string) (float64, error) {
	s := amountNoise.Replace(strings.TrimSpace(raw))
	if s == "" {
		if strings.TrimSpace(raw) == "" {
			return 0, ErrEmpty
		}
		return 0, ErrNotNumber
	}
	multiplier := 1.0
	if scale, ok := amountSuffixes[strings.ToUpper(s[len(s)-1:])]; ok {
		multiplier = scale
		s = s[:len(s)-1]
	}
	v, err := strconv.ParseFloat(normalizeSeparators(s), 64)
	if err != nil || !finite(v) {
		return 0, ErrNotNumber
	}
	return v * multiplier, nil
}

// isGrouped reports whether s is digits grouped by sep in threes: "1,234,567".
func isGrouped(s, sep string) bool {
	parts := strings.Split(strings.TrimPrefix(s, "-"), sep)
	if len(parts) < 2 || parts[0] == "" || len(parts[0]) > 3 {
		return false
	}
	for _, part := range parts[1:] {
		if len(part) != 3 {
			return false
		}
	}
	return true
}

func normalizeSeparators(s string) string {
	comma, dot := strings.LastIndex(s, ","), strings.LastIndex(s, ".")
	switch {
	case comma >= 0 && dot >= 0 && comma > dot: // 1.234,56
		return strings.Replace(strings.ReplaceAll(s, ".", ""), ",", ".", 1)
	case comma >= 0 && dot >= 0: // 1,234.56
		return strings.ReplaceAll(s, ",", "")
	case comma >= 0 && isGrouped(s, ","): // 1,100
		return strings.ReplaceAll(s, ",", "")
	case comma >= 0 && strings.Count(s, ",") == 1: // 1,25
		return strings.Replace(s, ",", ".", 1)
	case dot >= 0 && strings.Count(s, ".") > 1 && isGrouped(s, "."): // 1.234.567
		return strings.ReplaceAll(s, ".", "")
	}
	return s
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `GOFLAGS=-mod=mod go test ./internal/format/ -count=1 -v`
Expected: PASS for all nine tests.

- [ ] **Step 5: Commit**

```bash
git add internal/format
git commit -m "feat(format): shared compact/currency/number formatting and amount parsing"
```

---

### Task 2: `terminalapi` oapi-codegen slice

**Files:**
- Create: `oapi-codegen-terminal.yaml`
- Modify: `Makefile`: the `.PHONY` line (line 1), the `oapi-codegen-local` recipe (around lines 95-101), and a new target after `oapi-codegen-pilots` (around lines 117-119)
- Create (generated): `internal/api/terminalapi/client.gen.go`
- Test: `internal/api/terminalapi/terminalapi_test.go`

**Interfaces:**
- Consumes: the backend PR's `Sources/StockPlanBackend/openapi.yaml`.
- Produces (package `terminalapi`). Later tasks rely on these exact identifiers:
  - Types: `TerminalPositionResponse`, `TerminalPositionCreateRequest`, `TerminalPositionUpdateRequest`, `TerminalPositionOrderRequest`, `TerminalPositionsListResponse`, `TerminalPositionsSummaryResponse`, `AutobuyResponse`, `AutobuyCreateRequest`, `AutobuyUpdateRequest`, `AutobuysListResponse`, `AutobuyCadence` (string type), `ShareFactsRequest`, `ShareFactsSuggestion`, `TerminalScenarioSuggestionRequest`, `TerminalScenarioSuggestion`, `ListTerminalPositionsParams{Ticker *string}`, `RequestEditorFn`, `ClientWithResponses`.
  - Constructors: `NewClientWithResponses(server string, opts ...ClientOption)`, `WithHTTPClient`.
  - Methods on `*ClientWithResponses` (each returns `*<Op>Resp` with `JSON200`/`JSON201`, `Body []byte` and `StatusCode()`): `ListTerminalPositionsWithResponse(ctx, *ListTerminalPositionsParams, ...)`, `CreateTerminalPositionWithResponse(ctx, body, ...)`, `UpdateTerminalPositionWithResponse(ctx, id openapi_types.UUID, body, ...)`, `DeleteTerminalPositionWithResponse(ctx, id, ...)`, `DuplicateTerminalPositionWithResponse(ctx, id, ...)`, `ReorderTerminalPositionsWithResponse(ctx, body, ...)`, `GetTerminalPositionsSummaryWithResponse(ctx, ...)`, `ListAutobuysWithResponse(ctx, ...)`, `CreateAutobuyWithResponse(ctx, body, ...)`, `UpdateAutobuyWithResponse(ctx, id, body, ...)`, `DeleteAutobuyWithResponse(ctx, id, ...)`, `SuggestTerminalShareFactsWithResponse(ctx, body, ...)`, `SuggestTerminalScenarioWithResponse(ctx, body, ...)`.
  - Field shapes assumed by later tasks (oapi-codegen defaults: required non-null → value; optional or nullable → pointer with `omitempty`; `format: uuid` → `openapi_types.UUID`; `format: double` → `float64`; integer → `int`):
    - `Id openapi_types.UUID`
    - `SharesOutstanding`/`CurrentSharePrice`/`TerminalSharePrice`/`SharesNeeded`/`CapitalAtTodayPrice`/`Progress`/`SharesStillNeeded`/`GapValueAtTerminal *float64`
    - `TerminalShareCount`/`TerminalMarketCap`/`ValueWanted`/`SharesOwned float64` on responses
    - `ScenarioError *string`
    - `SortOrder int`
    - Update request: all pointers plus `Clear *[]string`
    - `Ids []openapi_types.UUID`
    - Autobuy response: `Ticker *string`, `Percent *float64`, `MonthlyEquivalent *float64`, `Active bool`, `Cadence AutobuyCadence`
    - Summary: `TotalCapitalAtTodayPrice *float64`, `TopPositions []TerminalPositionResponse`
    - `ShareFactsSuggestion{SharesOutstanding, CurrentSharePrice *float64; Currency, AsOf *string; Sources []string}`
    - `TerminalScenarioSuggestion{TerminalShareCount, TerminalMarketCap float64; HorizonYears int; Rationale string; Sources []string}`
    - `TerminalScenarioSuggestionRequest{Ticker string; HorizonYears *int}`

- [ ] **Step 1: Confirm the backend spec is available**

Run: `grep -c "operationId: listTerminalPositions" ../norviq-backend-terminal/Sources/StockPlanBackend/openapi.yaml ../norviq-backend/Sources/StockPlanBackend/openapi.yaml`
Expected: `1` for at least one file. Use that file as `SPEC` below. If both print `0`, **stop and report that the backend openapi.yaml is not ready**. Do not hand-write the client.

- [ ] **Step 2: Add the slice config**

`oapi-codegen-terminal.yaml`:
```yaml
# Terminal position sizing (`/v1/terminal-positions*`, `/v1/autobuys*`),
# generated on its own for the same reason as pilots: the main client
# (oapi-codegen.yaml) is pinned to an older spec revision, and regenerating it
# wholesale breaks the build until that drift is absorbed.
#
# The package is terminalapi, not terminal, so handlers can import it beside
# the internal/pages/terminal templates without an alias.
package: terminalapi
generate:
  client: true
  models: true
output: internal/api/terminalapi/client.gen.go
output-options:
  response-type-suffix: Resp
  include-operation-ids:
    - listTerminalPositions
    - createTerminalPosition
    - updateTerminalPosition
    - deleteTerminalPosition
    - duplicateTerminalPosition
    - reorderTerminalPositions
    - getTerminalPositionsSummary
    - listAutobuys
    - createAutobuy
    - updateAutobuy
    - deleteAutobuy
    - suggestTerminalShareFacts
    - suggestTerminalScenario
```

- [ ] **Step 3: Wire the Makefile**

Make three edits to `Makefile`:
1. On line 1 (`.PHONY:`), append ` oapi-codegen-terminal` right after `oapi-codegen-pilots`.
2. In the `oapi-codegen-local:` recipe, add a last line `	$(MAKE) oapi-codegen-terminal` right after `	$(MAKE) oapi-codegen-pilots`.
3. After the `oapi-codegen-pilots:` target, append:
```make

# Kept separate for the same reason: see the note in oapi-codegen-terminal.yaml.
oapi-codegen-terminal:
	oapi-codegen -config oapi-codegen-terminal.yaml "$(OPENAPI_SPEC)"
```

- [ ] **Step 4: Generate and verify the identifiers later tasks rely on**

```bash
make oapi-codegen-terminal OPENAPI_SPEC=<SPEC from Step 1>
f=internal/api/terminalapi/client.gen.go
for t in TerminalPositionResponse TerminalPositionCreateRequest TerminalPositionUpdateRequest TerminalPositionOrderRequest TerminalPositionsListResponse TerminalPositionsSummaryResponse AutobuyResponse AutobuyCreateRequest AutobuyUpdateRequest AutobuysListResponse AutobuyCadence ShareFactsRequest ShareFactsSuggestion TerminalScenarioSuggestionRequest TerminalScenarioSuggestion ListTerminalPositionsParams; do
  grep -q "^type $t " "$f" && echo "ok   type $t" || echo "MISS type $t"; done
for m in ListTerminalPositions CreateTerminalPosition UpdateTerminalPosition DeleteTerminalPosition DuplicateTerminalPosition ReorderTerminalPositions GetTerminalPositionsSummary ListAutobuys CreateAutobuy UpdateAutobuy DeleteAutobuy SuggestTerminalShareFacts SuggestTerminalScenario; do
  grep -q "func (c \*ClientWithResponses) ${m}WithResponse(" "$f" && echo "ok   $m" || echo "MISS $m"; done
for want in 'Id +openapi_types\.UUID' 'SharesOutstanding +\*float64' 'TerminalSharePrice +\*float64' 'ScenarioError +\*string' 'SortOrder +int' 'Clear +\*\[\]string' 'Ids +\[\]openapi_types\.UUID' 'Cadence +AutobuyCadence' 'MonthlyEquivalent +\*float64' 'TotalCapitalAtTodayPrice +\*float64' 'TopPositions +\[\]TerminalPositionResponse' 'AsOf +\*string' 'Sources +\[\]string' 'HorizonYears +\*int' 'Ticker +\*string'; do
  grep -Eq "^[[:space:]]+$want" "$f" && echo "ok   $want" || echo "MISS $want"; done
```
Expected: every line starts with `ok`. If any line says `MISS`, **stop and report the differing generated names** to the coordinator. They point to a contract or openapi mismatch to settle in the backend PR. Do not hand-edit `client.gen.go`, and do not improvise renames across the plan.

- [ ] **Step 5: Write the decode/encode pins**

`internal/api/terminalapi/terminalapi_test.go`:
```go
package terminalapi_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/FinancePlanner/StockPlanWeb/internal/api/terminalapi"
	"github.com/google/uuid"
	openapi_types "github.com/oapi-codegen/runtime/types"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	amznJSON = `{"id":"6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b","ticker":"AMZN","sharesOutstanding":10600000000,` +
		`"terminalShareCount":11000000000,"terminalMarketCap":10000000000000,"valueWanted":1000000,"sharesOwned":750,` +
		`"currentSharePrice":185.5,"notes":null,"sortOrder":0,"terminalSharePrice":909.0909090909091,"sharesNeeded":1100,` +
		`"capitalAtTodayPrice":204050,"progress":0.6818181818181818,"sharesStillNeeded":350,"gapValueAtTerminal":318181.8181818182,` +
		`"scenarioError":null,"createdAt":"2026-10-09T10:00:00Z","updatedAt":"2026-10-09T10:00:00Z"}`
	sofiJSON = `{"id":"8b3c4d5e-6f70-4182-93a4-b5c6d7e8f9a0","ticker":"SOFI","sharesOutstanding":null,"terminalShareCount":0,` +
		`"terminalMarketCap":250000000000,"valueWanted":100000,"sharesOwned":10,"currentSharePrice":null,"notes":null,"sortOrder":1,` +
		`"terminalSharePrice":null,"sharesNeeded":null,"capitalAtTodayPrice":null,"progress":null,"sharesStillNeeded":null,` +
		`"gapValueAtTerminal":null,"scenarioError":"share_count_not_positive","createdAt":"2026-10-09T10:00:00Z","updatedAt":"2026-10-09T10:00:00Z"}`
)

type seen struct {
	mu                        sync.Mutex
	method, path, query, body string
}

func (s *seen) get() (method, path, query, body string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.method, s.path, s.query, s.body
}

func terminalAPIClient(t *testing.T, status int, reply string) (*terminalapi.ClientWithResponses, *seen) {
	t.Helper()
	got := &seen{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		got.mu.Lock()
		got.method, got.path, got.query, got.body = r.Method, r.URL.Path, r.URL.RawQuery, string(raw)
		got.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(reply))
	}))
	t.Cleanup(srv.Close)
	client, err := terminalapi.NewClientWithResponses(srv.URL)
	require.NoError(t, err)
	return client, got
}

func TestListTerminalPositionsDecodesDerivedValuesAndNulls(t *testing.T) {
	t.Parallel()
	client, got := terminalAPIClient(t, http.StatusOK, `{"currency":"USD","positions":[`+amznJSON+`,`+sofiJSON+`]}`)
	ticker := "AMZN"
	resp, err := client.ListTerminalPositionsWithResponse(context.Background(), &terminalapi.ListTerminalPositionsParams{Ticker: &ticker})
	require.NoError(t, err)
	require.NotNil(t, resp.JSON200)

	method, path, query, _ := got.get()
	assert.Equal(t, http.MethodGet, method)
	assert.Equal(t, "/v1/terminal-positions", path)
	assert.Equal(t, "ticker=AMZN", query)
	assert.Equal(t, "USD", resp.JSON200.Currency)
	require.Len(t, resp.JSON200.Positions, 2)

	amzn := resp.JSON200.Positions[0]
	assert.Equal(t, "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b", amzn.Id.String())
	require.NotNil(t, amzn.TerminalSharePrice)
	assert.InDelta(t, 909.0909, *amzn.TerminalSharePrice, 0.0001)
	assert.InDelta(t, 750.0, amzn.SharesOwned, 0)
	assert.Equal(t, 0, amzn.SortOrder)

	sofi := resp.JSON200.Positions[1]
	assert.Nil(t, sofi.SharesNeeded)
	assert.Nil(t, sofi.SharesOutstanding)
	require.NotNil(t, sofi.ScenarioError)
	assert.Equal(t, "share_count_not_positive", *sofi.ScenarioError)
}

// PATCH semantics depend on unset fields being absent, not null or zero.
func TestUpdateRequestOmitsUnsetFields(t *testing.T) {
	t.Parallel()
	wanted := 5.0
	cleared := []string{"currentSharePrice"}
	raw, err := json.Marshal(terminalapi.TerminalPositionUpdateRequest{ValueWanted: &wanted, Clear: &cleared})
	require.NoError(t, err)
	assert.JSONEq(t, `{"valueWanted":5,"clear":["currentSharePrice"]}`, string(raw))
}

func TestReorderSendsTheFullIdList(t *testing.T) {
	t.Parallel()
	client, got := terminalAPIClient(t, http.StatusOK, `{"currency":"USD","positions":[]}`)
	first := uuid.MustParse("7a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9")
	second := uuid.MustParse("6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b")
	resp, err := client.ReorderTerminalPositionsWithResponse(context.Background(),
		terminalapi.TerminalPositionOrderRequest{Ids: []openapi_types.UUID{first, second}})
	require.NoError(t, err)
	require.NotNil(t, resp.JSON200)
	method, path, _, body := got.get()
	assert.Equal(t, http.MethodPut, method)
	assert.Equal(t, "/v1/terminal-positions/order", path)
	assert.JSONEq(t, `{"ids":["7a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9","6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b"]}`, body)
}

func TestListAutobuysDecodesCadenceAndOptionalPercent(t *testing.T) {
	t.Parallel()
	client, _ := terminalAPIClient(t, http.StatusOK, `{"currency":"USD","autobuys":[`+
		`{"id":"b2c3d4e5-f607-4182-93a4-b5c6d7e8f9a0","ticker":null,"label":"401k","amount":0,"cadence":"percentOfContribution",`+
		`"percent":0.04,"active":true,"monthlyEquivalent":null,"createdAt":"2026-10-09T10:00:00Z","updatedAt":"2026-10-09T10:00:00Z"}],"monthlyTotal":0}`)
	resp, err := client.ListAutobuysWithResponse(context.Background())
	require.NoError(t, err)
	require.NotNil(t, resp.JSON200)
	require.Len(t, resp.JSON200.Autobuys, 1)
	item := resp.JSON200.Autobuys[0]
	assert.Equal(t, terminalapi.AutobuyCadence("percentOfContribution"), item.Cadence)
	require.NotNil(t, item.Percent)
	assert.InDelta(t, 0.04, *item.Percent, 1e-12)
	assert.Nil(t, item.MonthlyEquivalent)
	assert.Nil(t, item.Ticker)
}

func TestSummaryDecodesANullCapitalTotal(t *testing.T) {
	t.Parallel()
	client, got := terminalAPIClient(t, http.StatusOK, `{"currency":"EUR","positionCount":0,"totalValueWanted":0,`+
		`"totalGapValueAtTerminal":0,"totalCapitalAtTodayPrice":null,"pricedPositionCount":0,"monthlyAutobuyTotal":0,"topPositions":[]}`)
	resp, err := client.GetTerminalPositionsSummaryWithResponse(context.Background())
	require.NoError(t, err)
	require.NotNil(t, resp.JSON200)
	_, path, _, _ := got.get()
	assert.Equal(t, "/v1/terminal-positions/summary", path)
	assert.Equal(t, "EUR", resp.JSON200.Currency)
	assert.Nil(t, resp.JSON200.TotalCapitalAtTodayPrice)
	assert.Empty(t, resp.JSON200.TopPositions)
}

// The Pro gate is a 403 whose body carries code "upgrade_required"; handlers
// read it from Body, so it must survive whatever typed fields are generated.
func TestShareFactsUpgradeBodyIsReadable(t *testing.T) {
	t.Parallel()
	client, got := terminalAPIClient(t, http.StatusForbidden, `{"success":false,"code":"upgrade_required","error":"Upgrade required.",`+
		`"feature":"terminal_position_ai","plan":"free","requiredPlan":"pro"}`)
	resp, err := client.SuggestTerminalShareFactsWithResponse(context.Background(), terminalapi.ShareFactsRequest{Ticker: "AMZN"})
	require.NoError(t, err)
	assert.Nil(t, resp.JSON200)
	assert.Equal(t, http.StatusForbidden, resp.StatusCode())
	var body struct {
		Code string `json:"code"`
	}
	require.NoError(t, json.Unmarshal(resp.Body, &body))
	assert.Equal(t, "upgrade_required", body.Code)
	method, path, _, sent := got.get()
	assert.Equal(t, http.MethodPost, method)
	assert.Equal(t, "/v1/terminal-positions/ai/share-facts", path)
	assert.JSONEq(t, `{"ticker":"AMZN"}`, sent)
}
```

- [ ] **Step 6: Run the tests**

Run: `GOFLAGS=-mod=mod go test ./internal/api/terminalapi/ -count=1 -v`
Expected: PASS (6 tests). A compile failure here means the generated shapes differ from the assumptions above. Stop and report, as in Step 4.

- [ ] **Step 7: Commit**

```bash
git add oapi-codegen-terminal.yaml Makefile internal/api/terminalapi
git commit -m "feat(terminal): generate the terminal positions API client slice"
```

---

### Task 3: View models, DTO mapping and client helpers

**Files:**
- Create: `internal/pages/terminal/vm.go`
- Create: `internal/handlers/terminal_client.go`
- Create: `internal/handlers/terminal_map.go`
- Test: `internal/handlers/terminal_fixtures_test.go`
- Test: `internal/handlers/terminal_client_test.go`
- Test: `internal/handlers/terminal_map_test.go`

**Interfaces:**
- Consumes: `format.*` (Task 1) and `terminalapi.*` (Task 2).
- Produces:
  - Package `terminal`: types `Copy`, `PageVM`, `RowVM`, `FooterVM`, `CreateFormVM`, `AutobuysVM`, `AutobuyVM`, `AutobuyFormVM`; constants `CadenceWeekly`, `CadenceBiweekly`, `CadenceBimonthly`, `CadenceMonthly`, `CadencePercent`, `SampleTicker`, `SampleTerminalShareCount`, `SampleTerminalMarketCap`, `SampleValueWanted`, `SampleCreateVals`; `func IsKnownCadence(string) bool`. Field names are exactly as in the code below.
  - Package `handlers`:
    - Constants: `terminalActivePath`, `terminalClientTimeout`, `terminalAIClientTimeout`, `terminalSampleCookie`, `terminalUnavailable`, `terminalSaveFailed`, `terminalGone`, `terminalTickerProblem`.
    - Client helpers: `(h *AppHandler) terminalClient(time.Duration) (*terminalapi.ClientWithResponses, error)`, `(h *AppHandler) terminalClientOr502(http.ResponseWriter) (*terminalapi.ClientWithResponses, bool)`, `(h *AppHandler) terminalEditor(*http.Request) terminalapi.RequestEditorFn`, `terminalIdempotencyEditor(string) terminalapi.RequestEditorFn`, `terminalIDFrom(*http.Request) (uuid.UUID, bool)`.
    - Validation and error helpers: `normalizeTerminalTicker(string) (string, bool)`, `terminalReason([]byte) string`, `isUpgradeRequired(int, []byte) bool`, `terminalWriteProblem(status int, body []byte, want int) string`.
    - Page helpers: `terminalCopy(context.Context) terminal.Copy`, `(h *AppHandler) terminalSessionExpired(w, r)`.
    - Mapping: `terminalRowsVM([]terminalapi.TerminalPositionResponse, currency string, isPro bool) []terminal.RowVM`, `terminalRowVM(*terminalapi.TerminalPositionResponse, string, bool) terminal.RowVM`, `terminalFooterVM(*terminalapi.TerminalPositionsSummaryResponse) terminal.FooterVM`, `terminalSampleRow(currency string) terminal.RowVM`, `terminalAutobuysVM(*terminalapi.AutobuysListResponse) terminal.AutobuysVM`, `scenarioErrorCopy(string) string`.
    - Test fixtures (constants in `terminal_fixtures_test.go`) and `decodeTerminal[T any](t, raw) T`.

- [ ] **Step 1: Write the view models**

`internal/pages/terminal/vm.go`:
```go
// Package terminal renders /terminal, terminal position sizing: a planning
// table of "if this company reaches market cap D with share count C, how
// many shares make my position worth F", plus a panel of recurring autobuys.
//
// Every number on these pages is computed by the backend. View models carry
// display strings the handlers formatted from backend values; templates and
// Alpine never do the sizing arithmetic.
package terminal

// Copy is the page copy, resolved per request so pt-PT readers get theirs.
type Copy struct {
	Title      string
	Subtitle   string
	Disclaimer string
}

// PageVM is the whole /terminal page.
type PageVM struct {
	Copy           Copy
	Currency       string
	CurrencySymbol string
	Rows           []RowVM
	Footer         FooterVM
	ShowSample     bool
	Sample         RowVM
	Create         CreateFormVM
	Autobuys       AutobuysVM
	// Notice reports a row action that failed (delete, duplicate, move).
	Notice    string
	IsPro     bool
	LoadError bool
}

// RowVM is one scenario row. Input fields hold the full number the input
// submits ("10000000000000"); the *Compact fields are what shows over an
// unfocused input ("$10T").
type RowVM struct {
	ID             string
	Ticker         string
	CurrencySymbol string
	IsFirst        bool
	IsLast         bool
	IsSample       bool
	IsPro          bool
	DetailsOpen    bool

	SharesOutstanding  string
	TerminalShareCount string
	TerminalMarketCap  string
	ValueWanted        string
	SharesOwned        string
	CurrentSharePrice  string

	SharesOutstandingCompact  string
	TerminalShareCountCompact string
	TerminalMarketCapCompact  string
	ValueWantedCompact        string

	// Valid is false when the backend could not compute the scenario; the
	// derived strings below are then a dash and ScenarioError says why.
	Valid               bool
	TerminalSharePrice  string
	SharesNeeded        string
	SharesNeededWhole   string
	ProgressPct         float64 // 0-100, clamped: the bar width only
	ProgressLabel       string  // the real percent, which can pass 100%
	StillNeeded         string
	StillNeededWhole    string
	GapValueAtTerminal  string
	CapitalAtTodayPrice string // "" when the row has no current price

	ScenarioError string
	FieldError    string
}

// FooterVM holds the three totals from GET /v1/terminal-positions/summary.
type FooterVM struct {
	Visible           bool
	TotalValueWanted  string
	TotalStillNeeded  string
	TotalCapitalToday string
	PricedNote        string
}

// CreateFormVM is the "Add scenario" form. Values echo what was typed when a
// submit is rejected.
type CreateFormVM struct {
	Open               bool
	Ticker             string
	TerminalShareCount string
	TerminalMarketCap  string
	ValueWanted        string
	SharesOwned        string
	IdempotencyKey     string
	Error              string
}

// Autobuy cadences, as the backend's AutobuyCadence raw values.
const (
	CadenceWeekly    = "weekly"
	CadenceBiweekly  = "biweekly"
	CadenceBimonthly = "bimonthly"
	CadenceMonthly   = "monthly"
	CadencePercent   = "percentOfContribution"
)

// IsKnownCadence reports whether c is a cadence the add/edit form may send.
func IsKnownCadence(c string) bool {
	switch c {
	case CadenceWeekly, CadenceBiweekly, CadenceBimonthly, CadenceMonthly, CadencePercent:
		return true
	}
	return false
}

// AutobuysVM is the side panel.
type AutobuysVM struct {
	Items          []AutobuyVM
	MonthlyTotal   string
	CurrencySymbol string
	Form           AutobuyFormVM
	// EditingID names the item whose edit form reopens, with EditForm's
	// values and error, after a rejected save.
	EditingID string
	EditForm  AutobuyFormVM
	Notice    string
	LoadError bool
}

// AutobuyVM is one recurring buy. Amount and Percent are form values (Percent
// in percent: "4" for 4%); the *Label fields are display strings.
type AutobuyVM struct {
	ID                string
	Label             string
	Ticker            string
	Amount            string
	AmountLabel       string
	Cadence           string
	CadenceLabel      string
	Percent           string
	MonthlyEquivalent string
	Active            bool
	// NeedsBase marks a percent autobuy with no monthly base: the backend
	// leaves it out of the total, and the panel says so.
	NeedsBase bool
}

// AutobuyFormVM is the add form (ID "") or one item's edit form.
type AutobuyFormVM struct {
	ID             string
	Label          string
	Ticker         string
	Amount         string
	Cadence        string
	Percent        string
	IdempotencyKey string
	Error          string
}

// The sample row is the spec's worked example. It is shown (never stored)
// until the user adds a row or dismisses it; "Use this row" posts these values.
const (
	SampleTicker             = "AMZN"
	SampleTerminalShareCount = 11e9
	SampleTerminalMarketCap  = 10e12
	SampleValueWanted        = 1e6
	SampleCreateVals         = `{"ticker":"AMZN","terminalShareCount":"11000000000","terminalMarketCap":"10000000000000","valueWanted":"1000000"}`
)
```

- [ ] **Step 2: Write the shared test fixtures**

`internal/handlers/terminal_fixtures_test.go`:
```go
package handlers

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"
)

// Backend JSON for the terminal tests, shaped exactly as the contract's DTOs.
// Ids are lower case so they match what uuid.UUID.String() renders.
const (
	terminalAMZNID = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b"
	terminalVGID   = "7a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9"
	terminalSOFIID = "8b3c4d5e-6f70-4182-93a4-b5c6d7e8f9a0"

	weeklyAutobuyID    = "a1b2c3d4-e5f6-4071-8293-a4b5c6d7e8f9"
	percentAutobuyID   = "b2c3d4e5-f607-4182-93a4-b5c6d7e8f9a0"
	bimonthlyAutobuyID = "c3d4e5f6-0718-4293-a4b5-c6d7e8f9a0b1"

	terminalStamps = `"createdAt":"2026-10-09T10:00:00Z","updatedAt":"2026-10-09T10:00:00Z"`

	// AMZN: the spec's worked example. 10T / 11B = 909.09; 1M wanted = 1,100
	// shares; 750 owned = 68.18%.
	amznPositionJSON = `{"id":"` + terminalAMZNID + `","ticker":"AMZN","sharesOutstanding":10600000000,` +
		`"terminalShareCount":11000000000,"terminalMarketCap":10000000000000,"valueWanted":1000000,"sharesOwned":750,` +
		`"currentSharePrice":185.5,"notes":null,"sortOrder":0,"terminalSharePrice":909.0909090909091,"sharesNeeded":1100,` +
		`"capitalAtTodayPrice":204050,"progress":0.6818181818181818,"sharesStillNeeded":350,` +
		`"gapValueAtTerminal":318181.8181818182,"scenarioError":null,` + terminalStamps + `}`
	// VG: 62.5 / 8,000 (spec example), no price, nothing owned.
	vgPositionJSON = `{"id":"` + terminalVGID + `","ticker":"VG","sharesOutstanding":null,"terminalShareCount":4000000000,` +
		`"terminalMarketCap":250000000000,"valueWanted":500000,"sharesOwned":0,"currentSharePrice":null,"notes":null,` +
		`"sortOrder":1,"terminalSharePrice":62.5,"sharesNeeded":8000,"capitalAtTodayPrice":null,"progress":0,` +
		`"sharesStillNeeded":8000,"gapValueAtTerminal":500000,"scenarioError":null,` + terminalStamps + `}`
	// SOFI: a half-finished edit the backend stored with a zero share count.
	sofiPositionJSON = `{"id":"` + terminalSOFIID + `","ticker":"SOFI","sharesOutstanding":null,"terminalShareCount":0,` +
		`"terminalMarketCap":250000000000,"valueWanted":100000,"sharesOwned":10,"currentSharePrice":null,"notes":null,` +
		`"sortOrder":2,"terminalSharePrice":null,"sharesNeeded":null,"capitalAtTodayPrice":null,"progress":null,` +
		`"sharesStillNeeded":null,"gapValueAtTerminal":null,"scenarioError":"share_count_not_positive",` + terminalStamps + `}`

	terminalListJSON      = `{"currency":"USD","positions":[` + amznPositionJSON + `,` + vgPositionJSON + `,` + sofiPositionJSON + `]}`
	terminalEmptyListJSON = `{"currency":"USD","positions":[]}`

	terminalSummaryJSON = `{"currency":"USD","positionCount":3,"totalValueWanted":1500000,` +
		`"totalGapValueAtTerminal":818181.8181818182,"totalCapitalAtTodayPrice":204050,"pricedPositionCount":1,` +
		`"monthlyAutobuyTotal":216.66666666666666,"topPositions":[` + amznPositionJSON + `,` + vgPositionJSON + `]}`
	terminalEmptySummaryJSON = `{"currency":"USD","positionCount":0,"totalValueWanted":0,"totalGapValueAtTerminal":0,` +
		`"totalCapitalAtTodayPrice":null,"pricedPositionCount":0,"monthlyAutobuyTotal":0,"topPositions":[]}`

	weeklyAutobuyJSON = `{"id":"` + weeklyAutobuyID + `","ticker":"VOO","label":"Weekly buy","amount":50,"cadence":"weekly",` +
		`"percent":null,"active":true,"monthlyEquivalent":216.66666666666666,` + terminalStamps + `}`
	percentAutobuyJSON = `{"id":"` + percentAutobuyID + `","ticker":null,"label":"401k","amount":0,` +
		`"cadence":"percentOfContribution","percent":0.04,"active":true,"monthlyEquivalent":null,` + terminalStamps + `}`
	bimonthlyAutobuyJSON = `{"id":"` + bimonthlyAutobuyID + `","ticker":"AMZN","label":"Every two months","amount":275,` +
		`"cadence":"bimonthly","percent":null,"active":false,"monthlyEquivalent":137.5,` + terminalStamps + `}`
	autobuysJSON = `{"currency":"USD","autobuys":[` + weeklyAutobuyJSON + `,` + percentAutobuyJSON + `,` +
		bimonthlyAutobuyJSON + `],"monthlyTotal":216.66666666666666}`
	emptyAutobuysJSON = `{"currency":"USD","autobuys":[],"monthlyTotal":0}`

	shareFactsJSON = `{"ticker":"AMZN","sharesOutstanding":10600000000,"currentSharePrice":185.5,"currency":"USD",` +
		`"asOf":"2026-10-08","sources":["https://ir.aboutamazon.com/sec-filings","javascript:alert(1)","http://insecure.example/x"]}`
	scenarioSuggestionJSON = `{"ticker":"AMZN","terminalShareCount":11000000000,"terminalMarketCap":10000000000000,` +
		`"horizonYears":10,"rationale":"Buybacks offset dilution; cloud margins hold.","sources":["https://example.com/amzn-10k"]}`
	terminalUpgradeJSON = `{"success":false,"code":"upgrade_required","error":"Upgrade required.",` +
		`"feature":"terminal_position_ai","plan":"free","requiredPlan":"pro"}`
)

// decodeTerminal unmarshals backend JSON into a generated type, so tests build
// DTOs without depending on how oapi-codegen spells each field's Go type.
func decodeTerminal[T any](t *testing.T, raw string) T {
	t.Helper()
	var v T
	require.NoError(t, json.Unmarshal([]byte(raw), &v))
	return v
}
```

- [ ] **Step 3: Write the failing tests**

`internal/handlers/terminal_client_test.go`:
```go
package handlers

import (
	"net/http"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNormalizeTerminalTicker(t *testing.T) {
	t.Parallel()
	for raw, want := range map[string]string{" amzn ": "AMZN", "brk.b": "BRK.B", "rds-a": "RDS-A"} {
		got, ok := normalizeTerminalTicker(raw)
		assert.True(t, ok, raw)
		assert.Equal(t, want, got, raw)
	}
	for _, raw := range []string{"", "   ", "AMZN!", "<script>", "ABCDEFGHIJKLM"} {
		_, ok := normalizeTerminalTicker(raw)
		assert.False(t, ok, raw)
	}
}

func TestIsUpgradeRequiredNeedsTheCodeNotJustTheStatus(t *testing.T) {
	t.Parallel()
	assert.True(t, isUpgradeRequired(http.StatusForbidden, []byte(terminalUpgradeJSON)))
	assert.False(t, isUpgradeRequired(http.StatusForbidden, []byte(`{"error":true,"reason":"Missing scope planning:read"}`)))
	assert.False(t, isUpgradeRequired(http.StatusPaymentRequired, []byte(terminalUpgradeJSON)))
	assert.False(t, isUpgradeRequired(http.StatusForbidden, []byte(`not json`)))
}

func TestTerminalWriteProblem(t *testing.T) {
	t.Parallel()
	assert.Equal(t, "", terminalWriteProblem(http.StatusCreated, nil, http.StatusCreated))
	assert.Equal(t, "valueWanted must not be negative.",
		terminalWriteProblem(http.StatusUnprocessableEntity, []byte(`{"error":true,"reason":"valueWanted must not be negative."}`), http.StatusOK))
	assert.Equal(t, terminalGone, terminalWriteProblem(http.StatusNotFound, nil, http.StatusOK))
	assert.Equal(t, terminalSaveFailed, terminalWriteProblem(http.StatusInternalServerError, []byte(`{"error":true,"reason":"boom"}`), http.StatusOK))
	assert.Equal(t, terminalSaveFailed, terminalWriteProblem(http.StatusUnprocessableEntity, []byte(`{}`), http.StatusOK))
}

func TestTerminalReason(t *testing.T) {
	t.Parallel()
	assert.Equal(t, "Bad ticker", terminalReason([]byte(`{"error":true,"reason":" Bad ticker "}`)))
	assert.Equal(t, "", terminalReason([]byte(`<html>`)))
}
```

`internal/handlers/terminal_map_test.go`:
```go
package handlers

import (
	"strings"
	"testing"

	"github.com/FinancePlanner/StockPlanWeb/internal/api/terminalapi"
	"github.com/FinancePlanner/StockPlanWeb/internal/format"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTerminalRowVMFormatsBackendNumbers(t *testing.T) {
	t.Parallel()
	p := decodeTerminal[terminalapi.TerminalPositionResponse](t, amznPositionJSON)
	row := terminalRowVM(&p, "USD", true)

	assert.Equal(t, terminalAMZNID, row.ID)
	assert.Equal(t, "AMZN", row.Ticker)
	assert.Equal(t, "$", row.CurrencySymbol)
	assert.True(t, row.IsPro)
	assert.True(t, row.Valid)
	assert.Equal(t, "$909.09", row.TerminalSharePrice)
	assert.Equal(t, "1,100", row.SharesNeeded)
	assert.Equal(t, "1,100", row.SharesNeededWhole)
	assert.Equal(t, "68.18%", row.ProgressLabel)
	assert.InDelta(t, 68.18, row.ProgressPct, 0.01)
	assert.Equal(t, "350", row.StillNeeded)
	assert.Equal(t, "$318,181.82", row.GapValueAtTerminal)
	assert.Equal(t, "$204,050", row.CapitalAtTodayPrice)
	assert.Equal(t, "10600000000", row.SharesOutstanding)
	assert.Equal(t, "10.6B", row.SharesOutstandingCompact)
	assert.Equal(t, "11000000000", row.TerminalShareCount)
	assert.Equal(t, "11B", row.TerminalShareCountCompact)
	assert.Equal(t, "10000000000000", row.TerminalMarketCap)
	assert.Equal(t, "$10T", row.TerminalMarketCapCompact)
	assert.Equal(t, "1000000", row.ValueWanted)
	assert.Equal(t, "$1M", row.ValueWantedCompact)
	assert.Equal(t, "750", row.SharesOwned)
	assert.Equal(t, "185.5", row.CurrentSharePrice)
	assert.Empty(t, row.ScenarioError)
}

func TestTerminalRowVMRoundsDownForTheWholeSharesToggle(t *testing.T) {
	t.Parallel()
	raw := strings.NewReplacer(`"sharesNeeded":1100`, `"sharesNeeded":1099.6`,
		`"sharesStillNeeded":350`, `"sharesStillNeeded":349.6`).Replace(amznPositionJSON)
	p := decodeTerminal[terminalapi.TerminalPositionResponse](t, raw)
	row := terminalRowVM(&p, "USD", false)
	assert.Equal(t, "1,099.6", row.SharesNeeded)
	assert.Equal(t, "1,099", row.SharesNeededWhole)
	assert.Equal(t, "349.6", row.StillNeeded)
	assert.Equal(t, "349", row.StillNeededWhole)
}

// Review Focus 3: owning more than needed fills the bar without lying about
// the percent.
func TestTerminalRowVMClampsTheBarButNotTheLabelWhenOverFunded(t *testing.T) {
	t.Parallel()
	raw := strings.NewReplacer(`"sharesOwned":750`, `"sharesOwned":1320`,
		`"progress":0.6818181818181818`, `"progress":1.2`,
		`"sharesStillNeeded":350`, `"sharesStillNeeded":0`,
		`"gapValueAtTerminal":318181.8181818182`, `"gapValueAtTerminal":0`).Replace(amznPositionJSON)
	p := decodeTerminal[terminalapi.TerminalPositionResponse](t, raw)
	row := terminalRowVM(&p, "USD", false)
	assert.InDelta(t, 100.0, row.ProgressPct, 0)
	assert.Equal(t, "120%", row.ProgressLabel)
	assert.Equal(t, "0", row.StillNeeded)
	assert.Equal(t, "$0", row.GapValueAtTerminal)
}

func TestTerminalRowsVMMarksEdgesAndInvalidRows(t *testing.T) {
	t.Parallel()
	list := decodeTerminal[terminalapi.TerminalPositionsListResponse](t, terminalListJSON)
	rows := terminalRowsVM(list.Positions, list.Currency, false)
	require.Len(t, rows, 3)

	assert.True(t, rows[0].IsFirst)
	assert.False(t, rows[0].IsLast)
	assert.False(t, rows[1].IsFirst)
	assert.False(t, rows[1].IsLast)
	assert.True(t, rows[2].IsLast)

	assert.Empty(t, rows[1].CapitalAtTodayPrice, "no current price, no capital at today's price")
	assert.Empty(t, rows[1].SharesOutstanding)
	assert.Equal(t, "0%", rows[1].ProgressLabel)
	assert.Equal(t, "$62.50", rows[1].TerminalSharePrice)

	sofi := rows[2]
	assert.False(t, sofi.Valid)
	assert.Equal(t, "Terminal share count must be above zero.", sofi.ScenarioError)
	assert.Equal(t, format.Dash, sofi.TerminalSharePrice)
	assert.Equal(t, format.Dash, sofi.SharesNeeded)
	assert.Equal(t, format.Dash, sofi.ProgressLabel)
	assert.Equal(t, "0", sofi.TerminalShareCount, "the stored input still shows so it can be fixed")
}

func TestScenarioErrorCopy(t *testing.T) {
	t.Parallel()
	assert.Equal(t, "Terminal market cap must be above zero.", scenarioErrorCopy("market_cap_not_positive"))
	assert.Equal(t, "This scenario cannot be calculated. Check its numbers.", scenarioErrorCopy("something_new"))
}

func TestTerminalFooterVM(t *testing.T) {
	t.Parallel()
	summary := decodeTerminal[terminalapi.TerminalPositionsSummaryResponse](t, terminalSummaryJSON)
	footer := terminalFooterVM(&summary)
	assert.True(t, footer.Visible)
	assert.Equal(t, "$1,500,000", footer.TotalValueWanted)
	assert.Equal(t, "$818,181.82", footer.TotalStillNeeded)
	assert.Equal(t, "$204,050", footer.TotalCapitalToday)
	assert.Equal(t, "1 of 3 rows have a price", footer.PricedNote)

	empty := decodeTerminal[terminalapi.TerminalPositionsSummaryResponse](t, terminalEmptySummaryJSON)
	none := terminalFooterVM(&empty)
	assert.False(t, none.Visible)
	assert.Equal(t, format.Dash, none.TotalCapitalToday)
	assert.Equal(t, "Add a current price to a row to see this.", none.PricedNote)
}

func TestTerminalSampleRowIsTheWorkedExampleInTheUsersCurrency(t *testing.T) {
	t.Parallel()
	row := terminalSampleRow("EUR")
	assert.True(t, row.IsSample)
	assert.True(t, row.Valid)
	assert.Equal(t, "AMZN", row.Ticker)
	assert.Equal(t, "€909.09", row.TerminalSharePrice)
	assert.Equal(t, "€10T", row.TerminalMarketCapCompact)
	assert.Equal(t, "11B", row.TerminalShareCountCompact)
	assert.Equal(t, "€1M", row.ValueWantedCompact)
	assert.Equal(t, "1,100", row.SharesNeeded)
	assert.Equal(t, "0%", row.ProgressLabel)
}

func TestTerminalAutobuysVM(t *testing.T) {
	t.Parallel()
	list := decodeTerminal[terminalapi.AutobuysListResponse](t, autobuysJSON)
	vm := terminalAutobuysVM(&list)
	require.Len(t, vm.Items, 3)
	assert.Equal(t, "$216.67", vm.MonthlyTotal)
	assert.Equal(t, "$", vm.CurrencySymbol)
	assert.Equal(t, "monthly", vm.Form.Cadence)

	weekly := vm.Items[0]
	assert.Equal(t, weeklyAutobuyID, weekly.ID)
	assert.Equal(t, "VOO", weekly.Ticker)
	assert.Equal(t, "$50", weekly.AmountLabel)
	assert.Equal(t, "50", weekly.Amount)
	assert.Equal(t, "Weekly", weekly.CadenceLabel)
	assert.Equal(t, "$216.67", weekly.MonthlyEquivalent)
	assert.True(t, weekly.Active)

	percent := vm.Items[1]
	assert.True(t, percent.NeedsBase)
	assert.Equal(t, "4", percent.Percent)
	assert.Equal(t, "4% of monthly base", percent.CadenceLabel)
	assert.Empty(t, percent.Ticker)

	bimonthly := vm.Items[2]
	assert.False(t, bimonthly.Active)
	assert.Equal(t, "Every two months", bimonthly.CadenceLabel)
	assert.Equal(t, "$137.50", bimonthly.MonthlyEquivalent)
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `GOFLAGS=-mod=mod go test ./internal/handlers/ -run 'Terminal|ScenarioError|IsUpgradeRequired|NormalizeTerminal' -count=1`
Expected: FAIL to compile with `undefined: normalizeTerminalTicker`, `undefined: terminalRowVM`, and so on.

- [ ] **Step 5: Write `terminal_client.go`**

`internal/handlers/terminal_client.go`:
```go
package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/FinancePlanner/StockPlanWeb/internal/api/terminalapi"
	"github.com/FinancePlanner/StockPlanWeb/internal/i18n"
	"github.com/FinancePlanner/StockPlanWeb/internal/middleware"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/terminal"
	"github.com/FinancePlanner/StockPlanWeb/internal/session"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
)

const (
	// terminalActivePath is the nav entry /terminal renders under.
	terminalActivePath    = "/terminal"
	terminalClientTimeout = 15 * time.Second
	// The AI lookups run a web search on the backend before they answer.
	terminalAIClientTimeout = 60 * time.Second
	// terminalSampleCookie remembers that the sample row was dismissed. The
	// sample is never stored as user data, so a cookie is all there is.
	terminalSampleCookie = "nq_terminal_sample_dismissed"

	terminalTitle      = "Terminal position sizing"
	terminalSubtitle   = "Decide the future market cap and share count. Norviq tells you how many shares that target is."
	terminalDisclaimer = "Terminal prices are your assumptions, not forecasts. Not financial advice."

	terminalUnavailable   = "Terminal sizing is unavailable right now. Try again shortly."
	terminalSaveFailed    = "Could not save that. Try again."
	terminalGone          = "That item no longer exists. Reload the page."
	terminalTickerProblem = "Use a ticker like AMZN or BRK.B."
)

// terminalTickerPattern is the backend's ticker rule (contract): trimmed,
// upper case, 1-12 of A-Z 0-9 . -
var terminalTickerPattern = regexp.MustCompile(`^[A-Z0-9.\-]{1,12}$`)

// terminalClient builds the terminal-only API client against the same backend
// as the main client. See oapi-codegen-terminal.yaml for why it is separate.
func (h *AppHandler) terminalClient(timeout time.Duration) (*terminalapi.ClientWithResponses, error) {
	if h.deps == nil || h.deps.API == nil || h.deps.API.BaseURL == "" {
		return nil, errors.New("terminal client unavailable")
	}
	return terminalapi.NewClientWithResponses(h.deps.API.BaseURL, terminalapi.WithHTTPClient(&http.Client{Timeout: timeout}))
}

// terminalClientOr502 returns the client, or answers 502 itself and false.
func (h *AppHandler) terminalClientOr502(w http.ResponseWriter) (*terminalapi.ClientWithResponses, bool) {
	client, err := h.terminalClient(terminalClientTimeout)
	if err != nil {
		slog.Warn("terminal client", "error", err)
		http.Error(w, terminalUnavailable, http.StatusBadGateway)
		return nil, false
	}
	return client, true
}

func (h *AppHandler) terminalEditor(r *http.Request) terminalapi.RequestEditorFn {
	return terminalapi.RequestEditorFn(middleware.BearerEditor(h.deps.Session, r))
}

// terminalIdempotencyEditor sends the form's Idempotency-Key, so a double
// submit of a create form makes one row, not two.
func terminalIdempotencyEditor(key string) terminalapi.RequestEditorFn {
	return func(_ context.Context, req *http.Request) error {
		if key != "" {
			req.Header.Set("Idempotency-Key", key)
		}
		return nil
	}
}

func terminalIDFrom(r *http.Request) (uuid.UUID, bool) {
	id, err := uuid.Parse(strings.TrimSpace(chi.URLParam(r, "id")))
	if err != nil {
		return uuid.UUID{}, false
	}
	return id, true
}

// normalizeTerminalTicker trims and upper-cases raw and reports whether the
// result passes the backend's ticker rule.
func normalizeTerminalTicker(raw string) (string, bool) {
	ticker := strings.ToUpper(strings.TrimSpace(raw))
	return ticker, terminalTickerPattern.MatchString(ticker)
}

// terminalReason pulls the human reason out of a backend Abort body.
func terminalReason(body []byte) string {
	var payload struct {
		Reason string `json:"reason"`
	}
	if json.Unmarshal(body, &payload) != nil {
		return ""
	}
	return strings.TrimSpace(payload.Reason)
}

// isUpgradeRequired reports the backend's Pro gate. BillingErrorMiddleware
// answers 403 with code "upgrade_required"; a bare 403 can also be a missing
// scope, so the status alone is not enough.
func isUpgradeRequired(status int, body []byte) bool {
	if status != http.StatusForbidden {
		return false
	}
	var payload struct {
		Code string `json:"code"`
	}
	return json.Unmarshal(body, &payload) == nil && payload.Code == "upgrade_required"
}

// terminalWriteProblem turns a backend write's status into the message to
// show, or "" when it got the status it wanted. Only validation failures carry
// the backend's reason through; anything else gets a generic retry message.
func terminalWriteProblem(status int, body []byte, want int) string {
	switch status {
	case want:
		return ""
	case http.StatusNotFound:
		return terminalGone
	case http.StatusUnprocessableEntity, http.StatusBadRequest:
		if reason := terminalReason(body); reason != "" {
			return reason
		}
	}
	return terminalSaveFailed
}

// terminalCopy is the copy every terminal surface shows, translated.
func terminalCopy(ctx context.Context) terminal.Copy {
	return terminal.Copy{
		Title:      i18n.T(ctx, terminalTitle),
		Subtitle:   i18n.T(ctx, terminalSubtitle),
		Disclaimer: i18n.T(ctx, terminalDisclaimer),
	}
}

// terminalSessionExpired handles a token the backend rejected: an expired
// session, not an outage. Same treatment as the pilot pages.
func (h *AppHandler) terminalSessionExpired(w http.ResponseWriter, r *http.Request) {
	if err := session.ClearAuth(h.deps.Session, r); err != nil {
		slog.Warn("clear rejected session", "error", err)
	}
	middleware.RedirectLogin(w, r)
}
```

- [ ] **Step 6: Write `terminal_map.go`**

`internal/handlers/terminal_map.go`:
```go
package handlers

import (
	"fmt"
	"math"

	"github.com/FinancePlanner/StockPlanWeb/internal/api/terminalapi"
	"github.com/FinancePlanner/StockPlanWeb/internal/format"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/terminal"
)

// terminalRowsVM formats the backend's rows, in the backend's order.
func terminalRowsVM(positions []terminalapi.TerminalPositionResponse, currency string, isPro bool) []terminal.RowVM {
	rows := make([]terminal.RowVM, 0, len(positions))
	for i := range positions {
		row := terminalRowVM(&positions[i], currency, isPro)
		row.IsFirst = i == 0
		row.IsLast = i == len(positions)-1
		rows = append(rows, row)
	}
	return rows
}

// terminalRowVM formats one backend row. It never computes a derived value:
// when the backend sent none (scenarioError, or a missing field) the derived
// columns show a dash.
func terminalRowVM(p *terminalapi.TerminalPositionResponse, currency string, isPro bool) terminal.RowVM {
	row := terminal.RowVM{
		ID:             fmt.Sprint(p.Id),
		Ticker:         p.Ticker,
		CurrencySymbol: format.CurrencySymbol(currency),
		IsPro:          isPro,

		SharesOutstanding:  optionalInput(p.SharesOutstanding),
		TerminalShareCount: format.InputNumber(p.TerminalShareCount),
		TerminalMarketCap:  format.InputNumber(p.TerminalMarketCap),
		ValueWanted:        format.InputNumber(p.ValueWanted),
		SharesOwned:        format.InputNumber(p.SharesOwned),
		CurrentSharePrice:  optionalInput(p.CurrentSharePrice),

		SharesOutstandingCompact:  optionalCompact(p.SharesOutstanding),
		TerminalShareCountCompact: format.Compact(p.TerminalShareCount),
		TerminalMarketCapCompact:  format.CompactCurrency(p.TerminalMarketCap, currency),
		ValueWantedCompact:        format.CompactCurrency(p.ValueWanted, currency),
	}
	if p.ScenarioError != nil && *p.ScenarioError != "" {
		row.ScenarioError = scenarioErrorCopy(*p.ScenarioError)
		return markUncomputed(row)
	}
	if p.TerminalSharePrice == nil || p.SharesNeeded == nil || p.Progress == nil ||
		p.SharesStillNeeded == nil || p.GapValueAtTerminal == nil {
		row.ScenarioError = scenarioErrorCopy("")
		return markUncomputed(row)
	}
	row.Valid = true
	row.TerminalSharePrice = format.Currency(*p.TerminalSharePrice, currency)
	row.SharesNeeded = format.Number(*p.SharesNeeded, 2)
	row.SharesNeededWhole = format.Number(format.WholeShares(*p.SharesNeeded), 0)
	row.ProgressPct = clampPct(*p.Progress * 100)
	row.ProgressLabel = format.Percent(*p.Progress)
	row.StillNeeded = format.Number(*p.SharesStillNeeded, 2)
	row.StillNeededWhole = format.Number(format.WholeShares(*p.SharesStillNeeded), 0)
	row.GapValueAtTerminal = format.Currency(*p.GapValueAtTerminal, currency)
	if p.CapitalAtTodayPrice != nil {
		row.CapitalAtTodayPrice = format.Currency(*p.CapitalAtTodayPrice, currency)
	}
	return row
}

func markUncomputed(row terminal.RowVM) terminal.RowVM {
	row.Valid = false
	for _, s := range []*string{
		&row.TerminalSharePrice, &row.SharesNeeded, &row.SharesNeededWhole, &row.ProgressLabel,
		&row.StillNeeded, &row.StillNeededWhole, &row.GapValueAtTerminal,
	} {
		*s = format.Dash
	}
	return row
}

func optionalInput(v *float64) string {
	if v == nil {
		return ""
	}
	return format.InputNumber(*v)
}

func optionalCompact(v *float64) string {
	if v == nil {
		return ""
	}
	return format.Compact(*v)
}

func clampPct(v float64) float64 {
	if math.IsNaN(v) || v < 0 {
		return 0
	}
	return math.Min(v, 100)
}

// scenarioErrorCopy explains the backend's TerminalScenarioError raw values.
func scenarioErrorCopy(code string) string {
	switch code {
	case "share_count_not_positive":
		return "Terminal share count must be above zero."
	case "market_cap_not_positive":
		return "Terminal market cap must be above zero."
	case "invalid_number":
		return "Check the numbers: value wanted and shares owned cannot be negative."
	default:
		return "This scenario cannot be calculated. Check its numbers."
	}
}

// terminalFooterVM formats the summary's three totals (spec: total value
// wanted, total still needed at terminal prices, total capital at today's
// price for rows that have one).
func terminalFooterVM(s *terminalapi.TerminalPositionsSummaryResponse) terminal.FooterVM {
	footer := terminal.FooterVM{
		Visible:           s.PositionCount > 0,
		TotalValueWanted:  format.Currency(s.TotalValueWanted, s.Currency),
		TotalStillNeeded:  format.Currency(s.TotalGapValueAtTerminal, s.Currency),
		TotalCapitalToday: format.Dash,
		PricedNote:        "Add a current price to a row to see this.",
	}
	if s.TotalCapitalAtTodayPrice != nil {
		footer.TotalCapitalToday = format.Currency(*s.TotalCapitalAtTodayPrice, s.Currency)
		footer.PricedNote = fmt.Sprintf("%d of %d rows have a price", s.PricedPositionCount, s.PositionCount)
	}
	return footer
}

// terminalSampleRow is the empty-state example. Its derived values are the
// spec's worked example written out as copy (AMZN 909.0909… / 1,100); nothing
// is computed here, and the row is never stored unless "Use this row" posts it.
func terminalSampleRow(currency string) terminal.RowVM {
	symbol := format.CurrencySymbol(currency)
	return terminal.RowVM{
		ID:                        "sample",
		Ticker:                    terminal.SampleTicker,
		CurrencySymbol:            symbol,
		IsSample:                  true,
		Valid:                     true,
		SharesOutstandingCompact:  format.Dash,
		TerminalShareCountCompact: format.Compact(terminal.SampleTerminalShareCount),
		TerminalMarketCapCompact:  format.CompactCurrency(terminal.SampleTerminalMarketCap, currency),
		ValueWantedCompact:        format.CompactCurrency(terminal.SampleValueWanted, currency),
		TerminalSharePrice:        symbol + "909.09",
		SharesNeeded:              "1,100",
		SharesNeededWhole:         "1,100",
		SharesOwned:               "0",
		ProgressLabel:             "0%",
		StillNeeded:               "1,100",
		StillNeededWhole:          "1,100",
		GapValueAtTerminal:        format.CompactCurrency(terminal.SampleValueWanted, currency),
	}
}

// terminalAutobuysVM formats the panel. The monthly equivalents and the total
// come from the backend (AutobuyMath); this only formats them.
func terminalAutobuysVM(l *terminalapi.AutobuysListResponse) terminal.AutobuysVM {
	vm := terminal.AutobuysVM{
		MonthlyTotal:   format.Currency(l.MonthlyTotal, l.Currency),
		CurrencySymbol: format.CurrencySymbol(l.Currency),
		Form:           terminal.AutobuyFormVM{Cadence: terminal.CadenceMonthly},
	}
	for i := range l.Autobuys {
		vm.Items = append(vm.Items, terminalAutobuyVM(&l.Autobuys[i], l.Currency))
	}
	return vm
}

func terminalAutobuyVM(a *terminalapi.AutobuyResponse, currency string) terminal.AutobuyVM {
	cadence := string(a.Cadence)
	item := terminal.AutobuyVM{
		ID:                fmt.Sprint(a.Id),
		Label:             a.Label,
		Amount:            format.InputNumber(a.Amount),
		AmountLabel:       format.Currency(a.Amount, currency),
		Cadence:           cadence,
		CadenceLabel:      cadenceLabel(cadence, a.Percent),
		MonthlyEquivalent: format.Dash,
		Active:            a.Active,
	}
	if a.Ticker != nil {
		item.Ticker = *a.Ticker
	}
	if a.Percent != nil {
		item.Percent = percentInput(*a.Percent)
	}
	switch {
	case a.MonthlyEquivalent != nil:
		item.MonthlyEquivalent = format.Currency(*a.MonthlyEquivalent, currency)
	case cadence == terminal.CadencePercent:
		item.NeedsBase = true
	}
	return item
}

func cadenceLabel(cadence string, percent *float64) string {
	switch cadence {
	case terminal.CadenceWeekly:
		return "Weekly"
	case terminal.CadenceBiweekly:
		return "Every two weeks"
	case terminal.CadenceBimonthly:
		return "Every two months"
	case terminal.CadenceMonthly:
		return "Monthly"
	case terminal.CadencePercent:
		if percent == nil {
			return "Percent of monthly base"
		}
		return format.Number(*percent*100, 2) + "% of monthly base"
	default:
		return "Other"
	}
}

// percentInput renders a stored ratio (0.04) as the percent the form edits
// ("4"), rounded so float noise never shows as 4.000000000000001.
func percentInput(ratio float64) string {
	return format.InputNumber(math.Round(ratio*1e6) / 1e4)
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `GOFLAGS=-mod=mod go test ./internal/handlers/ -run 'Terminal|ScenarioError|IsUpgradeRequired|NormalizeTerminal' -count=1 -v`
Expected: PASS for all tests from Step 3.

- [ ] **Step 8: Commit**

```bash
git add internal/pages/terminal/vm.go internal/handlers/terminal_client.go internal/handlers/terminal_map.go internal/handlers/terminal_*_test.go
git commit -m "feat(terminal): view models and backend-to-view formatting"
```

---

### Task 4: `/terminal` page: nav, i18n, table render, sample row, create form, Alpine compact labels

**Files:**
- Modify: `internal/nav/nav.go`: the path constants block (lines 28-44), the Portfolio children (after the `Retire` item, ~line 160), and `ActiveTab` (~line 423)
- Modify: `internal/nav/nav_test.go`
- Modify: `scripts/generate-i18n.py` (the `WEB_STRINGS` map), `internal/i18n/locales/active.en.json`, `internal/i18n/locales/active.pt-PT.json`
- Create: `internal/pages/terminal/helpers.go`
- Create: `internal/pages/terminal/page.templ`
- Create: `internal/pages/terminal/row.templ`
- Create: `internal/handlers/terminal.go`
- Create: `internal/server/assets/terminal.js`
- Modify: `internal/server/assets/scripts.js` (imports ~line 24, registration ~line 222)
- Modify: `internal/server/server.go`: right after `appHandler.MountSocialRoutes(r)` (~line 290)
- Modify: `internal/handlers/app_routes_test.go` (`TestAppRoutesRequireAuth` route list)
- Test: `internal/handlers/terminal_helpers_test.go`, `internal/handlers/terminal_page_test.go`, `internal/server/terminal_routes_test.go`

**Interfaces:**
- Consumes: everything from Task 3.
- Produces:
  - `nav.PathTerminal = "/terminal"`.
  - `(h *AppHandler) MountTerminalRoutes(r chi.Router)`. Later tasks add lines to it.
  - Handlers and loaders: `(h *AppHandler) Terminal`, `(h *AppHandler) fillTerminalWorkspace(r, client, *terminal.PageVM) int`, `(h *AppHandler) loadTerminalSummary(r, client) *terminalapi.TerminalPositionsSummaryResponse`, `(h *AppHandler) renderTerminalPage(w, r, terminal.PageVM)`, `newTerminalCreateForm(ticker string) terminal.CreateFormVM`, `terminalSampleDismissed(*http.Request) bool`.
  - templ (package `terminal`): `Page(PageVM)`, `Workspace(PageVM)` (root `id="terminal-workspace"`), `WorkspaceUnavailable()`, `CreateForm(CreateFormVM)`, `Footer(FooterVM, oob bool)` (root `id="terminal-footer"`), `Row(RowVM)` (root `<tbody id="terminal-row-{id}">`), `SampleRow(RowVM)`, `RowUpdate(RowVM, FooterVM, withFooter bool)`.
  - Input ids: `tp-{rowID}-{field}`.
  - Test helpers: `terminalReply`, `newTerminalBackend(t, overrides) (*api.Service, *terminalBackend)` with methods `called`, `body`, `query`, `header`; `terminalTestOpts{pro, hx bool; cookies []*http.Cookie}`; `serveTerminal(t, svc, opts, method, target string, form url.Values) *httptest.ResponseRecorder`.
  - Server test: `var terminalRoutes []string`.
  - JS: `registerTerminal(Alpine)` with `Alpine.data('terminalCompact', (symbol, initial) => ...)`.

- [ ] **Step 1: Write the test helpers**

`internal/handlers/terminal_helpers_test.go`:
```go
package handlers

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FinancePlanner/StockPlanWeb/internal/api"
	"github.com/FinancePlanner/StockPlanWeb/internal/config"
	"github.com/FinancePlanner/StockPlanWeb/internal/middleware"
	"github.com/alexedwards/scs/v2"
	"github.com/go-chi/chi/v5"
	"github.com/stretchr/testify/require"
)

type terminalReply struct {
	status int
	body   string
}

// terminalBackend fakes /v1 for the terminal pages. Keys are "METHOD /path";
// unknown keys answer 404 like the backend does.
type terminalBackend struct {
	mu      sync.Mutex
	calls   []string
	bodies  map[string]string
	queries map[string]string
	headers map[string]http.Header
	replies map[string]terminalReply
}

func newTerminalBackend(t *testing.T, overrides map[string]terminalReply) (*api.Service, *terminalBackend) {
	t.Helper()
	b := &terminalBackend{
		bodies:  map[string]string{},
		queries: map[string]string{},
		headers: map[string]http.Header{},
		replies: map[string]terminalReply{
			"GET /v1/terminal-positions":                                   {http.StatusOK, terminalListJSON},
			"GET /v1/terminal-positions/summary":                           {http.StatusOK, terminalSummaryJSON},
			"POST /v1/terminal-positions":                                  {http.StatusCreated, amznPositionJSON},
			"PATCH /v1/terminal-positions/" + terminalAMZNID:               {http.StatusOK, amznPositionJSON},
			"DELETE /v1/terminal-positions/" + terminalAMZNID:              {http.StatusNoContent, ""},
			"POST /v1/terminal-positions/" + terminalAMZNID + "/duplicate": {http.StatusCreated, amznPositionJSON},
			"PUT /v1/terminal-positions/order":                             {http.StatusOK, terminalListJSON},
			"POST /v1/terminal-positions/ai/share-facts":                   {http.StatusOK, shareFactsJSON},
			"POST /v1/terminal-positions/ai/scenario":                      {http.StatusOK, scenarioSuggestionJSON},
			"GET /v1/autobuys":                                             {http.StatusOK, autobuysJSON},
			"POST /v1/autobuys":                                            {http.StatusCreated, weeklyAutobuyJSON},
			"PATCH /v1/autobuys/" + weeklyAutobuyID:                        {http.StatusOK, weeklyAutobuyJSON},
			"DELETE /v1/autobuys/" + weeklyAutobuyID:                       {http.StatusNoContent, ""},
		},
	}
	for key, reply := range overrides {
		b.replies[key] = reply
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		key := r.Method + " " + r.URL.Path
		b.mu.Lock()
		b.calls = append(b.calls, key)
		b.bodies[key] = string(raw)
		b.queries[key] = r.URL.RawQuery
		b.headers[key] = r.Header.Clone()
		reply, ok := b.replies[key]
		b.mu.Unlock()
		if !ok {
			reply = terminalReply{http.StatusNotFound, `{"error":true,"reason":"Not found"}`}
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(reply.status)
		if reply.body != "" {
			_, _ = w.Write([]byte(reply.body))
		}
	}))
	t.Cleanup(srv.Close)
	svc, err := api.NewService(srv.URL)
	require.NoError(t, err)
	return svc, b
}

func (b *terminalBackend) called(key string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, call := range b.calls {
		if call == key {
			return true
		}
	}
	return false
}

func (b *terminalBackend) body(key string) string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.bodies[key]
}

func (b *terminalBackend) query(key string) string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.queries[key]
}

func (b *terminalBackend) header(key, name string) string {
	b.mu.Lock()
	defer b.mu.Unlock()
	if h, ok := b.headers[key]; ok {
		return h.Get(name)
	}
	return ""
}

type terminalTestOpts struct {
	pro     bool
	hx      bool
	cookies []*http.Cookie
}

// serveTerminal mounts MountTerminalRoutes, the same table server.go mounts,
// with the Pro status AttachProStatus would have cached.
func serveTerminal(t *testing.T, svc *api.Service, opts terminalTestOpts, method, target string, form url.Values) *httptest.ResponseRecorder {
	t.Helper()
	sm := scs.New()
	sm.Lifetime = time.Hour
	app := NewAppHandler(&Deps{API: svc, Session: sm, Config: &config.Config{}})
	r := chi.NewRouter()
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			next.ServeHTTP(w, req.WithContext(middleware.WithCachedProStatus(req.Context(), opts.pro)))
		})
	})
	app.MountTerminalRoutes(r)

	var body io.Reader = http.NoBody
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	req := httptest.NewRequestWithContext(context.Background(), method, target, body)
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if opts.hx {
		req.Header.Set("HX-Request", "true")
	}
	for _, c := range opts.cookies {
		req.AddCookie(c)
	}
	rec := httptest.NewRecorder()
	sm.LoadAndSave(r).ServeHTTP(rec, req)
	return rec
}
```

- [ ] **Step 2: Write the failing page, nav and route tests**

`internal/handlers/terminal_page_test.go`:
```go
package handlers

import (
	"net/http"
	"net/url"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTerminalPageRendersRowsFooterAndDisclaimer(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, nil)
	rec := serveTerminal(t, svc, terminalTestOpts{}, http.MethodGet, "/terminal", nil)

	require.Equal(t, http.StatusOK, rec.Code)
	body := rec.Body.String()
	assert.Contains(t, body, "Terminal position sizing")
	assert.Contains(t, body, "Decide the future market cap and share count. Norviq tells you how many shares that target is.")
	assert.Contains(t, body, "Terminal prices are your assumptions, not forecasts. Not financial advice.")
	assert.Contains(t, body, `id="terminal-row-`+terminalAMZNID+`"`)
	assert.Contains(t, body, "$909.09")
	assert.Contains(t, body, "68.18%")
	assert.Contains(t, body, "Round down to whole shares")
	assert.Contains(t, body, "$1,500,000")
	assert.Contains(t, body, "$818,181.82")
	assert.Contains(t, body, "1 of 3 rows have a price")
	assert.Contains(t, body, "Terminal share count must be above zero.")
	assert.NotContains(t, body, "Use this row", "no sample once real rows exist")
}

func TestTerminalCellsPatchTheirRowAndKeepStableIDs(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, nil)
	body := serveTerminal(t, svc, terminalTestOpts{}, http.MethodGet, "/terminal", nil).Body.String()

	assert.Contains(t, body, `id="tp-`+terminalAMZNID+`-valueWanted"`)
	assert.Contains(t, body, `id="tp-`+terminalAMZNID+`-ticker"`)
	assert.Contains(t, body, `hx-patch="/terminal/positions/`+terminalAMZNID+`"`)
	assert.Contains(t, body, `hx-trigger="change delay:400ms"`)
	assert.Contains(t, body, `hx-target="#terminal-row-`+terminalAMZNID+`"`)
	assert.Contains(t, body, `value="10000000000000"`, "the input holds the full number")
	assert.Contains(t, body, `>$10T</span>`, "the compact label sits over it")
	assert.Contains(t, body, `terminalCompact(`)
}

func TestTerminalPageShowsTheSampleRowWhenEmpty(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, map[string]terminalReply{
		"GET /v1/terminal-positions":         {http.StatusOK, terminalEmptyListJSON},
		"GET /v1/terminal-positions/summary": {http.StatusOK, terminalEmptySummaryJSON},
	})
	body := serveTerminal(t, svc, terminalTestOpts{}, http.MethodGet, "/terminal", nil).Body.String()

	assert.Contains(t, body, "Sample")
	assert.Contains(t, body, "Use this row")
	assert.Contains(t, body, "Dismiss")
	assert.Contains(t, body, "$909.09")
	assert.Contains(t, body, `hx-post="/terminal/positions"`)
	assert.False(t, backend.called("POST /v1/terminal-positions"), "the sample is never stored by rendering it")
}

func TestTerminalPageHidesTheSampleOnceDismissed(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{
		"GET /v1/terminal-positions":         {http.StatusOK, terminalEmptyListJSON},
		"GET /v1/terminal-positions/summary": {http.StatusOK, terminalEmptySummaryJSON},
	})
	opts := terminalTestOpts{cookies: []*http.Cookie{{Name: terminalSampleCookie, Value: "1"}}}
	body := serveTerminal(t, svc, opts, http.MethodGet, "/terminal", nil).Body.String()

	assert.NotContains(t, body, "Use this row")
	assert.Contains(t, body, "No scenarios yet.")
}

func TestTerminalPagePreopensTheCreateFormForATicker(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, nil)
	body := serveTerminal(t, svc, terminalTestOpts{}, http.MethodGet, "/terminal?ticker=nvda", nil).Body.String()
	assert.Contains(t, body, `id="terminal-create" x-data="{ open: true }"`)
	assert.Contains(t, body, `value="NVDA"`)

	bad := serveTerminal(t, svc, terminalTestOpts{}, http.MethodGet, "/terminal?ticker="+url.QueryEscape("<b>x</b>"), nil).Body.String()
	assert.Contains(t, bad, `id="terminal-create" x-data="{ open: false }"`)
}

func TestTerminalPageSaysUnavailableOnBackendFailure(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{
		"GET /v1/terminal-positions": {http.StatusBadGateway, `{"error":true,"reason":"upstream"}`},
	})
	rec := serveTerminal(t, svc, terminalTestOpts{}, http.MethodGet, "/terminal", nil)
	require.Equal(t, http.StatusOK, rec.Code)
	assert.Contains(t, rec.Body.String(), "Terminal sizing is unavailable right now.")
	assert.Contains(t, rec.Body.String(), "Not financial advice.", "the disclaimer stays even when the table cannot load")
}

func TestTerminalPageSendsARejectedSessionToLogin(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{
		"GET /v1/terminal-positions": {http.StatusUnauthorized, `{"error":true,"reason":"Unauthorized"}`},
	})
	rec := serveTerminal(t, svc, terminalTestOpts{}, http.MethodGet, "/terminal", nil)
	assert.Equal(t, http.StatusSeeOther, rec.Code)
	assert.Equal(t, "/login?next="+url.QueryEscape("/terminal"), rec.Header().Get("Location"))
}
```

Append to `internal/nav/nav_test.go`:
```go
func TestPortfolioGroupLinksTerminalSizing(t *testing.T) {
	t.Parallel()

	item, ok := flattenSidebarItems(SidebarItemsFor(context.Background(), nil))[PathTerminal]
	if !ok {
		t.Fatal("terminal sizing is missing from the sidebar")
	}
	if item.Label != "Terminal sizing" || item.Tab != TabPortfolio || item.FeatureKey != "" {
		t.Fatalf("unexpected terminal nav item: %+v", item)
	}
	if ActiveTab("/terminal") != TabPortfolio {
		t.Fatal("expected /terminal to light the portfolio tab")
	}
}
```

`internal/server/terminal_routes_test.go`:
```go
package server

import (
	"net/http"
	"strings"
	"testing"

	"github.com/FinancePlanner/StockPlanWeb/internal/config"
	"github.com/FinancePlanner/StockPlanWeb/internal/handlers"
	"github.com/alexedwards/scs/v2"
	"github.com/go-chi/chi/v5"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// terminalRoutes is every route the terminal templates call. Each task that
// adds a route adds it here, so a handler can never ship unrouted.
var terminalRoutes = []string{
	"GET /terminal",
}

func TestTerminalRoutesAreMounted(t *testing.T) {
	t.Parallel()
	mux, ok := setupRouter(&handlers.Deps{Session: scs.New(), Config: &config.Config{}}).(*chi.Mux)
	require.True(t, ok, "setupRouter must return a *chi.Mux for route introspection")
	registered := map[string]bool{}
	require.NoError(t, chi.Walk(mux, func(method, route string, _ http.Handler, _ ...func(http.Handler) http.Handler) error {
		registered[method+" "+strings.TrimSuffix(route, "/")] = true
		return nil
	}))
	for _, route := range terminalRoutes {
		assert.True(t, registered[route], "route %q is not mounted", route)
	}
}
```

In `internal/handlers/app_routes_test.go`, in `TestAppRoutesRequireAuth`, add one line to the `routes` slice after `{"portfolio/one-page/share-link", app.PortfolioShareLinkCreate},`:
```go
		{"terminal", app.Terminal},
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `GOFLAGS=-mod=mod go test ./internal/handlers/ ./internal/nav/ ./internal/server/ -run 'Terminal|AppRoutesRequireAuth' -count=1`
Expected: FAIL to compile (`app.MountTerminalRoutes undefined`, `undefined: PathTerminal`).

- [ ] **Step 4: Add the nav entry**

In `internal/nav/nav.go`, add a constant to the `const (` block that holds `PathDashboard`, right after `PathArticles         = "/articles"`:
```go
	// PathTerminal is terminal position sizing, a planning tool in Portfolio.
	PathTerminal = "/terminal"
```
In the Portfolio `Children`, right after `{Label: t("Retire"), Path: "/planning/retire", Tab: TabPortfolio},`, add:
```go
				{Label: t("Terminal sizing"), Path: PathTerminal, Tab: TabPortfolio},
```
In `ActiveTab`, extend the portfolio case. Change the line starting `case strings.HasPrefix(path, "/portfolio")` so that it ends with `|| strings.HasPrefix(path, "/research") || strings.HasPrefix(path, PathTerminal):`.

- [ ] **Step 5: Add translations**

In `scripts/generate-i18n.py`, add these entries to `WEB_STRINGS` just before its closing `}`:
```python
    "Terminal sizing": "Dimensionamento terminal",
    "Terminal position sizing": "Dimensionamento de posições terminais",
    "Decide the future market cap and share count. Norviq tells you how many shares that target is.": "Define a capitalização bolsista e o número de ações futuros. O Norviq diz-te quantas ações esse objetivo representa.",
    "Terminal prices are your assumptions, not forecasts. Not financial advice.": "Os preços terminais são pressupostos teus, não previsões. Não é aconselhamento financeiro.",
```
The generator reads an iOS checkout that may not exist here, so add the same entries to the two JSON files directly, in the generator's exact output format:
```bash
python3 - <<'PY'
import json, pathlib
add = {
    "Terminal sizing": "Dimensionamento terminal",
    "Terminal position sizing": "Dimensionamento de posições terminais",
    "Decide the future market cap and share count. Norviq tells you how many shares that target is.": "Define a capitalização bolsista e o número de ações futuros. O Norviq diz-te quantas ações esse objetivo representa.",
    "Terminal prices are your assumptions, not forecasts. Not financial advice.": "Os preços terminais são pressupostos teus, não previsões. Não é aconselhamento financeiro.",
}
root = pathlib.Path("internal/i18n/locales")
for name, lang in (("active.en.json", "en"), ("active.pt-PT.json", "pt-PT")):
    path = root / name
    entries = {e["id"]: e["translation"] for e in json.loads(path.read_text())}
    for key, pt in add.items():
        entries[key] = pt if lang == "pt-PT" else key
    path.write_text(json.dumps([{"id": k, "translation": entries[k]} for k in sorted(entries)], ensure_ascii=False, indent=2) + "\n")
PY
git diff --stat -- internal/i18n/locales
```
Expected: each file shows only about `+16` insertions (four entries of four lines). If the stat shows deletions or hundreds of changed lines, the files were not in the generator's format. In that case run `git checkout -- internal/i18n/locales` and insert the four `{"id": ..., "translation": ...}` objects by hand at their sorted positions.

- [ ] **Step 6: Write the template helpers**

`internal/pages/terminal/helpers.go`:
```go
package terminal

import (
	"encoding/json"
	"fmt"

	"github.com/a-h/templ"
)

const iconButtonClass = "inline-flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground " +
	"hover:bg-muted hover:text-foreground disabled:pointer-events-none disabled:opacity-40"

// cellID is the stable id htmx restores focus to after a row swap.
func cellID(rowID, field string) string { return "tp-" + rowID + "-" + field }

func openState(open bool) string { return fmt.Sprintf("{ open: %t }", open) }

// jsString renders s as a JavaScript string literal for an Alpine expression.
func jsString(s string) string {
	raw, err := json.Marshal(s)
	if err != nil {
		return `""`
	}
	return string(raw)
}

func compactState(symbol, compact string) string {
	return fmt.Sprintf("terminalCompact(%s, %s)", jsString(symbol), jsString(compact))
}

// cellAttrs wires a cell to PATCH its row on change. hx-target and hx-swap are
// on every control because htmx 4 does not inherit them.
func cellAttrs(rowID, label string) templ.Attributes {
	return templ.Attributes{
		"aria-label":   label,
		"autocomplete": "off",
		"hx-patch":     "/terminal/positions/" + rowID,
		"hx-trigger":   "change delay:400ms",
		"hx-target":    "#terminal-row-" + rowID,
		"hx-swap":      "outerHTML",
		"hx-include":   "this",
	}
}

func numericCellAttrs(rowID, label string) templ.Attributes {
	attrs := cellAttrs(rowID, label)
	attrs["inputmode"] = "decimal"
	return attrs
}

func compactAttrs(rowID, label string) templ.Attributes {
	attrs := numericCellAttrs(rowID, label)
	attrs["@blur"] = "blur($event.target.value)"
	return attrs
}

// detailAttrs is a cell inside the details row; "details=open" tells the
// handler to re-render the row with the details still showing.
func detailAttrs(rowID, label string) templ.Attributes {
	attrs := numericCellAttrs(rowID, label)
	attrs["hx-vals"] = `{"details":"open"}`
	return attrs
}

// workspaceAction is a row action that answers with the whole workspace
// (create, duplicate, delete, move, sample).
func workspaceAction(method, path, vals, label string) templ.Attributes {
	attrs := templ.Attributes{
		method:       path,
		"hx-target":  "#terminal-workspace",
		"hx-swap":    "outerHTML",
		"aria-label": label,
	}
	if vals != "" {
		attrs["hx-vals"] = vals
	}
	return attrs
}

func moveAction(row RowVM, dir string) templ.Attributes {
	return workspaceAction("hx-post", "/terminal/positions/"+row.ID+"/move", `{"dir":"`+dir+`"}`, "Move "+row.Ticker+" "+dir)
}

func deleteAction(row RowVM) templ.Attributes {
	attrs := workspaceAction("hx-delete", "/terminal/positions/"+row.ID, "", "Delete "+row.Ticker)
	attrs["hx-confirm"] = "Delete the " + row.Ticker + " scenario?"
	return attrs
}
```

- [ ] **Step 7: Write the row templates**

`internal/pages/terminal/row.templ`:
```templ
package terminal

import (
	"fmt"

	"github.com/FinancePlanner/StockPlanWeb/internal/components/icon"
	"github.com/FinancePlanner/StockPlanWeb/internal/components/input"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/components"
)

// Row is one scenario, rendered as its own <tbody> so the cells, the inline
// error and the details row swap together on every edit.
//
// Every input has a stable id. After an outerHTML swap htmx puts focus back on
// the element with the same id, so tabbing across a row while it re-renders
// keeps the cursor where the reader is.
templ Row(row RowVM) {
	<tbody id={ "terminal-row-" + row.ID } class="terminal-row" x-data={ openState(row.DetailsOpen) }>
		<tr>
			<td>
				@components.Field(components.FieldProps{
					ID:         cellID(row.ID, "ticker"),
					Name:       "ticker",
					Type:       input.TypeText,
					Value:      row.Ticker,
					Class:      "w-24 uppercase",
					Attributes: cellAttrs(row.ID, "Ticker"),
				})
			</td>
			<td>
				@compactCell(row.ID, "sharesOutstanding", "Shares outstanding", row.SharesOutstanding, row.SharesOutstandingCompact, "")
			</td>
			<td>
				@compactCell(row.ID, "terminalShareCount", "Terminal share count", row.TerminalShareCount, row.TerminalShareCountCompact, "")
			</td>
			<td>
				@compactCell(row.ID, "terminalMarketCap", "Terminal market cap", row.TerminalMarketCap, row.TerminalMarketCapCompact, row.CurrencySymbol)
			</td>
			<td class="tabular-nums">{ row.TerminalSharePrice }</td>
			<td>
				@compactCell(row.ID, "valueWanted", "Value wanted", row.ValueWanted, row.ValueWantedCompact, row.CurrencySymbol)
			</td>
			<td class="tabular-nums">
				@shareCount(row.SharesNeeded, row.SharesNeededWhole)
			</td>
			<td>
				@components.Field(components.FieldProps{
					ID:         cellID(row.ID, "sharesOwned"),
					Name:       "sharesOwned",
					Type:       input.TypeText,
					Value:      row.SharesOwned,
					Class:      "w-24 tabular-nums",
					Attributes: numericCellAttrs(row.ID, "Shares owned"),
				})
			</td>
			<td>
				@progress(row.ProgressPct, row.ProgressLabel, row.Valid)
			</td>
			<td class="tabular-nums">
				@shareCount(row.StillNeeded, row.StillNeededWhole)
				if row.Valid {
					<span class="block text-footnote text-muted-foreground">≈ { row.GapValueAtTerminal } at terminal</span>
				}
			</td>
			<td>
				@rowActions(row)
			</td>
		</tr>
		if row.FieldError != "" {
			@rowError(row.FieldError)
		} else if row.ScenarioError != "" {
			@rowError(row.ScenarioError)
		}
		<tr class="terminal-row-details" x-show="open" x-cloak?={ !row.DetailsOpen }>
			<td colspan="11">
				@rowDetails(row)
			</td>
		</tr>
	</tbody>
}

templ rowError(message string) {
	<tr class="terminal-row-error">
		<td colspan="11" role="alert" class="text-footnote text-destructive">{ message }</td>
	</tr>
}

// compactCell shows "$10T" over the input while it is not focused; focusing
// it reveals the full number the input actually holds and submits. The
// show/hide is pure CSS (group-focus-within), so a row re-render that restores
// focus can never leave the label covering what is being typed. Alpine only
// refreshes the label text on blur, until the server's re-render replaces it.
templ compactCell(rowID, name, label, value, compact, symbol string) {
	<div class="group relative" x-data={ compactState(symbol, compact) }>
		@components.Field(components.FieldProps{
			ID:         cellID(rowID, name),
			Name:       name,
			Type:       input.TypeText,
			Value:      value,
			Class:      "w-32 tabular-nums text-transparent focus:text-foreground",
			Attributes: compactAttrs(rowID, label),
		})
		<span class="pointer-events-none absolute inset-y-0 left-3 flex items-center tabular-nums group-focus-within:hidden" aria-hidden="true" x-text="label">{ compact }</span>
	</div>
}

// shareCount renders both the exact and the whole-share figure; the page's
// roundDown flag picks one. Display only: nothing is recomputed.
templ shareCount(full, whole string) {
	<span x-show="!roundDown">{ full }</span>
	<span x-show="roundDown" x-cloak>{ whole }</span>
}

templ progress(pct float64, label string, valid bool) {
	if valid {
		<div class="flex min-w-24 items-center gap-2">
			<div class="h-1 flex-1 overflow-hidden rounded-full bg-muted" role="progressbar" aria-label="Progress" aria-valuemin="0" aria-valuemax="100" aria-valuenow={ fmt.Sprintf("%.0f", pct) }>
				<div class="h-full rounded-full bg-primary" style={ fmt.Sprintf("width:%.1f%%", pct) }></div>
			</div>
			<span class="text-footnote tabular-nums">{ label }</span>
		</div>
	} else {
		<span class="text-muted-foreground">{ label }</span>
	}
}

templ rowActions(row RowVM) {
	<div class="flex items-center gap-1">
		@components.NativeButton(components.ButtonProps{Class: iconButtonClass, Attributes: templ.Attributes{"@click": "open = !open", ":aria-expanded": "open", "aria-label": "Details for " + row.Ticker}}) {
			@icon.Icon("chevron-down")(icon.Props{Class: "h-4 w-4"})
		}
		@components.NativeButton(components.ButtonProps{Class: iconButtonClass, Disabled: row.IsFirst, Attributes: moveAction(row, "up")}) {
			@icon.Icon("arrow-up")(icon.Props{Class: "h-4 w-4"})
		}
		@components.NativeButton(components.ButtonProps{Class: iconButtonClass, Disabled: row.IsLast, Attributes: moveAction(row, "down")}) {
			@icon.Icon("arrow-down")(icon.Props{Class: "h-4 w-4"})
		}
		@components.NativeButton(components.ButtonProps{Class: iconButtonClass, Attributes: workspaceAction("hx-post", "/terminal/positions/"+row.ID+"/duplicate", "", "Duplicate "+row.Ticker)}) {
			@icon.Icon("copy")(icon.Props{Class: "h-4 w-4"})
		}
		@components.NativeButton(components.ButtonProps{Class: iconButtonClass, Attributes: deleteAction(row)}) {
			@icon.Icon("trash-2")(icon.Props{Class: "h-4 w-4"})
		}
	</div>
}

templ rowDetails(row RowVM) {
	<div class="grid gap-4 py-2 md:grid-cols-[16rem_minmax(0,1fr)]">
		<div class="space-y-2">
			@components.Field(components.FieldProps{
				ID:          cellID(row.ID, "currentSharePrice"),
				Name:        "currentSharePrice",
				Label:       "Current share price (optional)",
				Type:        input.TypeText,
				Value:       row.CurrentSharePrice,
				Placeholder: "185.50",
				Class:       "tabular-nums",
				Attributes:  detailAttrs(row.ID, "Current share price"),
			})
			if row.CapitalAtTodayPrice != "" {
				<p class="text-footnote">Capital at today's price: <span class="font-semibold tabular-nums">{ row.CapitalAtTodayPrice }</span></p>
			} else {
				<p class="text-footnote text-muted-foreground">Add a current price to see what these shares cost today.</p>
			}
		</div>
	</div>
}

// SampleRow is the empty-state example: static text, never stored. "Use this
// row" posts its values to the create route; "Dismiss" sets a cookie.
templ SampleRow(row RowVM) {
	<tbody id="terminal-sample" class="terminal-row terminal-row-sample">
		<tr>
			<td>
				<span class="font-semibold">{ row.Ticker }</span>
				<span class="ml-1 rounded bg-muted px-1.5 py-0.5 text-[0.65rem] font-semibold uppercase">Sample</span>
			</td>
			<td class="tabular-nums text-muted-foreground">{ row.SharesOutstandingCompact }</td>
			<td class="tabular-nums">{ row.TerminalShareCountCompact }</td>
			<td class="tabular-nums">{ row.TerminalMarketCapCompact }</td>
			<td class="tabular-nums">{ row.TerminalSharePrice }</td>
			<td class="tabular-nums">{ row.ValueWantedCompact }</td>
			<td class="tabular-nums">
				@shareCount(row.SharesNeeded, row.SharesNeededWhole)
			</td>
			<td class="tabular-nums">{ row.SharesOwned }</td>
			<td>
				@progress(row.ProgressPct, row.ProgressLabel, row.Valid)
			</td>
			<td class="tabular-nums">
				@shareCount(row.StillNeeded, row.StillNeededWhole)
			</td>
			<td>
				<div class="flex flex-wrap gap-1">
					@components.PrimaryButton(components.ButtonProps{Attributes: workspaceAction("hx-post", "/terminal/positions", SampleCreateVals, "Use this row")}) {
						Use this row
					}
					@components.GhostButton(components.ButtonProps{Attributes: workspaceAction("hx-post", "/terminal/sample/dismiss", "", "Dismiss the sample")}) {
						Dismiss
					}
				</div>
			</td>
		</tr>
	</tbody>
}

// RowUpdate answers a cell edit: the row, plus the footer out of band when the
// summary loaded.
templ RowUpdate(row RowVM, footer FooterVM, withFooter bool) {
	@Row(row)
	if withFooter {
		@Footer(footer, true)
	}
}
```

- [ ] **Step 8: Write the page templates**

`internal/pages/terminal/page.templ`:
```templ
package terminal

import (
	"github.com/FinancePlanner/StockPlanWeb/internal/components/icon"
	"github.com/FinancePlanner/StockPlanWeb/internal/components/input"
	"github.com/FinancePlanner/StockPlanWeb/internal/components/vigil"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/components"
)

// Page is /terminal. The root carries the CSRF header for every htmx write
// below it, and the round-down flag, which lives above every swapped region so
// a swap never resets it.
templ Page(vm PageVM) {
	<div
		class="app-page-content terminal-page"
		hx-headers:inherited={ components.HXCSRFHeaders(ctx) }
		x-data="{ roundDown: false }"
	>
		@vigil.ModernPageHeader(vm.Copy.Title, vm.Copy.Subtitle, nil)
		if vm.LoadError {
			@WorkspaceUnavailable()
		} else {
			<div class="terminal-layout grid gap-6">
				<div class="min-w-0 space-y-3">
					@components.SwitchField(components.SwitchFieldProps{
						ID:          "terminal-round-down",
						Label:       "Round down to whole shares",
						Description: "Display only. Saved numbers keep their decimals.",
						Attributes:  templ.Attributes{"x-model": "roundDown"},
					})
					@Workspace(vm)
				</div>
			</div>
		}
		<p class="mt-4 text-footnote text-muted-foreground">{ vm.Copy.Disclaimer }</p>
	</div>
}

// Workspace is the region row actions re-render: the create form, the table
// and the footer.
templ Workspace(vm PageVM) {
	<section id="terminal-workspace" class="space-y-4" aria-label="Terminal scenarios">
		if vm.Notice != "" {
			<p role="alert" class="text-footnote text-destructive">{ vm.Notice }</p>
		}
		@CreateForm(vm.Create)
		@vigil.DataTable("terminal-table") {
			<thead>
				<tr>
					<th scope="col">Ticker</th>
					<th scope="col">Shares outstanding</th>
					<th scope="col">Terminal share count</th>
					<th scope="col">Terminal market cap</th>
					<th scope="col">Terminal share price</th>
					<th scope="col">Value wanted</th>
					<th scope="col">Shares needed</th>
					<th scope="col">Owned</th>
					<th scope="col">Progress</th>
					<th scope="col">Still needed</th>
					<th scope="col"><span class="sr-only">Actions</span></th>
				</tr>
			</thead>
			if vm.ShowSample {
				@SampleRow(vm.Sample)
			}
			for _, row := range vm.Rows {
				@Row(row)
			}
		}
		if len(vm.Rows) == 0 && !vm.ShowSample {
			<p class="text-subhead text-muted-foreground">No scenarios yet. Add one to see how many shares your target takes.</p>
		}
		@Footer(vm.Footer, false)
	</section>
}

templ WorkspaceUnavailable() {
	<section id="terminal-workspace" aria-label="Terminal scenarios">
		@vigil.Panel("p-5", "") {
			<p role="alert" class="text-subhead">Terminal sizing is unavailable right now. Try again shortly.</p>
		}
	</section>
}

templ CreateForm(vm CreateFormVM) {
	<div id="terminal-create" x-data={ openState(vm.Open) }>
		@components.SecondaryButton(components.ButtonProps{Attributes: templ.Attributes{"@click": "open = !open", ":aria-expanded": "open", "aria-controls": "terminal-create-form"}}) {
			@icon.Icon("plus")(icon.Props{Class: "h-4 w-4"})
			Add scenario
		}
		<form
			id="terminal-create-form"
			class="mt-3 grid items-end gap-3 sm:grid-cols-2 lg:grid-cols-6"
			hx-post="/terminal/positions"
			hx-target="#terminal-workspace"
			hx-swap="outerHTML"
			x-show="open"
			x-cloak?={ !vm.Open }
		>
			@components.CSRFField()
			<input type="hidden" name="idempotency_key" value={ vm.IdempotencyKey }/>
			@components.Field(components.FieldProps{ID: "terminal-create-ticker", Name: "ticker", Label: "Ticker", Type: input.TypeText, Value: vm.Ticker, Placeholder: "AMZN", Required: true, Autocomplete: "off", Class: "uppercase"})
			@components.Field(components.FieldProps{ID: "terminal-create-share-count", Name: "terminalShareCount", Label: "Terminal share count", Type: input.TypeText, Value: vm.TerminalShareCount, Placeholder: "11B", Required: true, Attributes: templ.Attributes{"inputmode": "decimal"}})
			@components.Field(components.FieldProps{ID: "terminal-create-market-cap", Name: "terminalMarketCap", Label: "Terminal market cap", Type: input.TypeText, Value: vm.TerminalMarketCap, Placeholder: "10T", Required: true, Attributes: templ.Attributes{"inputmode": "decimal"}})
			@components.Field(components.FieldProps{ID: "terminal-create-value-wanted", Name: "valueWanted", Label: "Value wanted", Type: input.TypeText, Value: vm.ValueWanted, Placeholder: "1M", Required: true, Attributes: templ.Attributes{"inputmode": "decimal"}})
			@components.Field(components.FieldProps{ID: "terminal-create-owned", Name: "sharesOwned", Label: "Shares owned (optional)", Type: input.TypeText, Value: vm.SharesOwned, Placeholder: "0", Attributes: templ.Attributes{"inputmode": "decimal"}})
			@components.SubmitButton(components.ButtonProps{}) {
				Add
			}
			if vm.Error != "" {
				<p role="alert" class="text-footnote text-destructive sm:col-span-2 lg:col-span-6">{ vm.Error }</p>
			}
		</form>
	</div>
}

// Footer shows the summary's three totals. Cell edits replace it out of band.
templ Footer(vm FooterVM, oob bool) {
	<div id="terminal-footer" class="grid gap-3 sm:grid-cols-3" hx-swap-oob?={ oob } hidden?={ !vm.Visible }>
		@footerStat("Total value wanted", vm.TotalValueWanted, "")
		@footerStat("Still needed at terminal prices", vm.TotalStillNeeded, "")
		@footerStat("Capital at today's price", vm.TotalCapitalToday, vm.PricedNote)
	</div>
}

templ footerStat(label, value, note string) {
	<div class="rounded-xl border border-border p-3">
		<p class="text-footnote text-muted-foreground">{ label }</p>
		<p class="text-title3 font-semibold tabular-nums">{ value }</p>
		if note != "" {
			<p class="text-footnote text-muted-foreground">{ note }</p>
		}
	</div>
}
```

- [ ] **Step 9: Write the page handler**

`internal/handlers/terminal.go`:
```go
package handlers

import (
	"log/slog"
	"net/http"

	"github.com/FinancePlanner/StockPlanWeb/internal/api/terminalapi"
	"github.com/FinancePlanner/StockPlanWeb/internal/format"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/terminal"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
)

// MountTerminalRoutes registers terminal position sizing. server.go and the
// handler tests mount this same table, so a route cannot exist in one and not
// the other.
func (h *AppHandler) MountTerminalRoutes(r chi.Router) {
	r.Get("/terminal", h.Terminal)
}

// Terminal renders /terminal. ?ticker=X (the stock page's "Add terminal
// scenario" link) opens the create form with that ticker filled in.
func (h *AppHandler) Terminal(w http.ResponseWriter, r *http.Request) {
	vm := terminal.PageVM{Copy: terminalCopy(r.Context()), IsPro: h.isPro(r)}
	ticker, ok := normalizeTerminalTicker(r.URL.Query().Get("ticker"))
	if !ok {
		ticker = ""
	}
	vm.Create = newTerminalCreateForm(ticker)
	client, err := h.terminalClient(terminalClientTimeout)
	if err != nil {
		slog.Warn("terminal client", "error", err)
		vm.LoadError = true
		h.renderTerminalPage(w, r, vm)
		return
	}
	if status := h.fillTerminalWorkspace(r, client, &vm); status == http.StatusUnauthorized {
		h.terminalSessionExpired(w, r)
		return
	}
	h.renderTerminalPage(w, r, vm)
}

func (h *AppHandler) renderTerminalPage(w http.ResponseWriter, r *http.Request, vm terminal.PageVM) {
	h.renderShell(w, r, vm.Copy.Title+" - Norviq", nil, terminalActivePath, terminal.Page(vm))
}

// fillTerminalWorkspace loads the rows and the footer totals into vm and
// returns the list call's HTTP status (0 when the call never completed).
func (h *AppHandler) fillTerminalWorkspace(r *http.Request, client *terminalapi.ClientWithResponses, vm *terminal.PageVM) int {
	resp, err := client.ListTerminalPositionsWithResponse(r.Context(), nil, h.terminalEditor(r))
	if err != nil {
		slog.Warn("list terminal positions", "error", err)
		vm.LoadError = true
		return 0
	}
	if resp.JSON200 == nil {
		slog.Warn("list terminal positions", "status", resp.StatusCode())
		vm.LoadError = true
		return resp.StatusCode()
	}
	vm.Currency = resp.JSON200.Currency
	vm.CurrencySymbol = format.CurrencySymbol(vm.Currency)
	vm.Rows = terminalRowsVM(resp.JSON200.Positions, vm.Currency, vm.IsPro)
	vm.ShowSample = len(vm.Rows) == 0 && !terminalSampleDismissed(r)
	if vm.ShowSample {
		vm.Sample = terminalSampleRow(vm.Currency)
	}
	if summary := h.loadTerminalSummary(r, client); summary != nil {
		vm.Footer = terminalFooterVM(summary)
	}
	return resp.StatusCode()
}

// loadTerminalSummary is best effort: a page without totals still works.
func (h *AppHandler) loadTerminalSummary(r *http.Request, client *terminalapi.ClientWithResponses) *terminalapi.TerminalPositionsSummaryResponse {
	resp, err := client.GetTerminalPositionsSummaryWithResponse(r.Context(), h.terminalEditor(r))
	if err != nil {
		slog.Warn("terminal summary", "error", err)
		return nil
	}
	if resp.JSON200 == nil {
		slog.Warn("terminal summary", "status", resp.StatusCode())
		return nil
	}
	return resp.JSON200
}

func newTerminalCreateForm(ticker string) terminal.CreateFormVM {
	return terminal.CreateFormVM{Open: ticker != "", Ticker: ticker, IdempotencyKey: uuid.NewString()}
}

func terminalSampleDismissed(r *http.Request) bool {
	c, err := r.Cookie(terminalSampleCookie)
	return err == nil && c.Value == "1"
}
```

- [ ] **Step 10: Mount the routes in the server**

In `internal/server/server.go`, in the authenticated `router.Group`, add one line right after `appHandler.MountSocialRoutes(r)`:
```go
		appHandler.MountTerminalRoutes(r)
```

- [ ] **Step 11: Add the Alpine component**

`internal/server/assets/terminal.js`:
```js
// Terminal position sizing. Display only: every number on the page comes from
// the server, which is the only place the sizing formulas run. This file only
// formats what is already there and prefills forms.

const UNITS = [
  [1e12, 'T'],
  [1e9, 'B'],
  [1e6, 'M'],
  [1e3, 'K'],
]

// compactLabel approximates internal/format.CompactCurrency for the moment
// between blur and the server's re-render, which replaces it.
export function compactLabel(raw, symbol = '') {
  const text = String(raw ?? '').trim()
  if (text === '') return ''
  const n = Number(text.replace(/[\s,$€£¥]/g, ''))
  if (!Number.isFinite(n)) return text
  const sign = n < 0 ? '-' : ''
  const abs = Math.abs(n)
  for (const [size, suffix] of UNITS) {
    if (abs >= size) {
      return sign + symbol + String(Math.round((abs / size) * 100) / 100) + suffix
    }
  }
  return sign + symbol + String(Math.round(abs * 100) / 100)
}

export function registerTerminal(Alpine) {
  Alpine.data('terminalCompact', (symbol = '', initial = '') => ({
    label: initial,
    blur(value) {
      this.label = compactLabel(value, symbol)
    },
  }))
}
```
In `internal/server/assets/scripts.js`, add `import { registerTerminal } from './terminal.js'` right after the line `import { registerGuidedStart } from './guided-start.js'`. Then add `registerTerminal(Alpine)` right after the line `registerGuidedStart(Alpine)`.

- [ ] **Step 12: Generate and run the tests**

```bash
templ generate
bun run build
GOFLAGS=-mod=mod go test ./internal/handlers/ ./internal/nav/ ./internal/server/ -run 'Terminal|AppRoutesRequireAuth' -count=1 -v
```
Expected: PASS for the seven page tests, the nav test, the route test and the auth test.

- [ ] **Step 13: Check controls and commit**

```bash
bash scripts/check-no-bare-controls.sh
git add internal/nav internal/i18n scripts/generate-i18n.py internal/pages/terminal internal/handlers/terminal.go internal/handlers/terminal_helpers_test.go internal/handlers/terminal_page_test.go internal/handlers/app_routes_test.go internal/server/server.go internal/server/terminal_routes_test.go internal/server/assets/terminal.js internal/server/assets/scripts.js
git commit -m "feat(terminal): /terminal page with the planning table, sample row and nav entry"
```
Expected: the bare-controls check passes, meaning the count did not go up.

---

### Task 5: Cell edits (row PATCH, OOB footer, inline errors)

**Files:**
- Create: `internal/handlers/terminal_update.go`
- Modify: `internal/handlers/terminal.go` (`MountTerminalRoutes`)
- Modify: `internal/server/terminal_routes_test.go` (`terminalRoutes`)
- Test: `internal/handlers/terminal_update_test.go`

**Interfaces:**
- Consumes: `terminalRowVM`, `terminalFooterVM`, `loadTerminalSummary`, `terminalWriteProblem`, `normalizeTerminalTicker`, `format.ParseAmount`, `terminal.RowUpdate`.
- Produces:
  - Route `PATCH /terminal/positions/{id}` → `(h *AppHandler) TerminalPositionUpdate`. Form keys are the backend field names: `ticker`, `sharesOutstanding`, `terminalShareCount`, `terminalMarketCap`, `valueWanted`, `sharesOwned`, `currentSharePrice`, plus optional `details=open`.
  - `(h *AppHandler) renderTerminalFragment(w, r, templ.Component)`.
  - `(h *AppHandler) findTerminalPosition(r, client, uuid.UUID) (*terminalapi.TerminalPositionResponse, string)`.
  - `parseTerminalUpdateForm(url.Values) (terminalapi.TerminalPositionUpdateRequest, string)`.
  - Task 8's Accept reuses this route.

- [ ] **Step 1: Write the failing tests**

`internal/handlers/terminal_update_test.go`:
```go
package handlers

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"github.com/FinancePlanner/StockPlanWeb/internal/api"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const amznPatchKey = "PATCH /v1/terminal-positions/" + terminalAMZNID

func patchTerminalRow(t *testing.T, svc *api.Service, form url.Values) *httptest.ResponseRecorder {
	t.Helper()
	return serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPatch, "/terminal/positions/"+terminalAMZNID, form)
}

func TestTerminalCellEditSendsOnlyThatFieldAndRerendersTheRow(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := patchTerminalRow(t, svc, url.Values{"valueWanted": {"2,000,000"}})

	require.Equal(t, http.StatusOK, rec.Code)
	assert.JSONEq(t, `{"valueWanted":2000000}`, backend.body(amznPatchKey))
	body := rec.Body.String()
	assert.Contains(t, body, `id="terminal-row-`+terminalAMZNID+`"`)
	assert.Contains(t, body, "$909.09", "derived values come from the backend's answer")
	assert.Contains(t, body, `id="terminal-footer"`)
	assert.Contains(t, body, "hx-swap-oob")
	assert.Contains(t, body, "$1,500,000")
}

// Review Focus 1.
func TestTerminalCellEditParsesCompactAndPtPTAmounts(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	patchTerminalRow(t, svc, url.Values{"terminalMarketCap": {"10T"}})
	assert.JSONEq(t, `{"terminalMarketCap":10000000000000}`, backend.body(amznPatchKey))

	patchTerminalRow(t, svc, url.Values{"sharesOwned": {"1.234,5"}})
	assert.JSONEq(t, `{"sharesOwned":1234.5}`, backend.body(amznPatchKey))
}

// Review Focus 2.
func TestTerminalCellEditClearsAnEmptiedOptionalField(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	patchTerminalRow(t, svc, url.Values{"sharesOutstanding": {""}})
	assert.JSONEq(t, `{"clear":["sharesOutstanding"]}`, backend.body(amznPatchKey))
}

func TestTerminalCellEditUppercasesTheTicker(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	patchTerminalRow(t, svc, url.Values{"ticker": {" brk.b "}})
	assert.JSONEq(t, `{"ticker":"BRK.B"}`, backend.body(amznPatchKey))
}

func TestTerminalCellEditRejectsTextWithoutCallingTheBackend(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := patchTerminalRow(t, svc, url.Values{"valueWanted": {"lots"}})

	require.Equal(t, http.StatusOK, rec.Code, "htmx 4 drops 4xx bodies, so the inline error answers 200")
	assert.False(t, backend.called(amznPatchKey))
	body := rec.Body.String()
	assert.Contains(t, body, "Value wanted needs a number.")
	assert.Contains(t, body, `id="terminal-row-`+terminalAMZNID+`"`, "the stored row is re-rendered under the error")
}

func TestTerminalCellEditRejectsAnEmptiedRequiredField(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := patchTerminalRow(t, svc, url.Values{"terminalShareCount": {""}})
	assert.False(t, backend.called(amznPatchKey))
	assert.Contains(t, rec.Body.String(), "Terminal share count needs a number.")
}

func TestTerminalCellEditShowsTheBackendReason(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, map[string]terminalReply{
		amznPatchKey: {http.StatusUnprocessableEntity, `{"error":true,"reason":"valueWanted must not be negative."}`},
	})
	rec := patchTerminalRow(t, svc, url.Values{"valueWanted": {"-5"}})

	require.Equal(t, http.StatusOK, rec.Code)
	assert.True(t, backend.called("GET /v1/terminal-positions"))
	body := rec.Body.String()
	assert.Contains(t, body, "valueWanted must not be negative.")
	assert.Contains(t, body, `id="terminal-row-`+terminalAMZNID+`"`)
}

func TestTerminalCellEditKeepsTheDetailsOpen(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := patchTerminalRow(t, svc, url.Values{"currentSharePrice": {"190"}, "details": {"open"}})
	assert.JSONEq(t, `{"currentSharePrice":190}`, backend.body(amznPatchKey))
	assert.Contains(t, rec.Body.String(), `id="terminal-row-`+terminalAMZNID+`" class="terminal-row" x-data="{ open: true }"`)
}

func TestTerminalCellEditOnADeletedRowRemovesIt(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{
		amznPatchKey:                 {http.StatusNotFound, `{"error":true,"reason":"Not found"}`},
		"GET /v1/terminal-positions": {http.StatusOK, terminalEmptyListJSON},
	})
	rec := patchTerminalRow(t, svc, url.Values{"valueWanted": {"5"}})
	require.Equal(t, http.StatusOK, rec.Code)
	assert.NotContains(t, rec.Body.String(), "terminal-row-")
}

func TestTerminalCellEditWithABadIDIsNotFound(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, nil)
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPatch, "/terminal/positions/not-a-uuid", url.Values{"valueWanted": {"5"}})
	assert.Equal(t, http.StatusNotFound, rec.Code)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `GOFLAGS=-mod=mod go test ./internal/handlers/ -run TerminalCellEdit -count=1`
Expected: FAIL. The PATCH route is not mounted, so requests answer 405, assertions fail, and the backend body is empty.

- [ ] **Step 3: Write the handler**

`internal/handlers/terminal_update.go`:
```go
package handlers

import (
	"log/slog"
	"net/http"
	"net/url"
	"strings"

	"github.com/FinancePlanner/StockPlanWeb/internal/api/terminalapi"
	"github.com/FinancePlanner/StockPlanWeb/internal/format"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/terminal"
	"github.com/a-h/templ"
	"github.com/google/uuid"
)

// terminalNumberField is one numeric cell the row PATCH accepts.
type terminalNumberField struct {
	name     string
	label    string
	nullable bool // emptying it clears it instead of being an error
}

var terminalNumberFields = []terminalNumberField{
	{name: "sharesOutstanding", label: "Shares outstanding", nullable: true},
	{name: "terminalShareCount", label: "Terminal share count"},
	{name: "terminalMarketCap", label: "Terminal market cap"},
	{name: "valueWanted", label: "Value wanted"},
	{name: "sharesOwned", label: "Shares owned"},
	{name: "currentSharePrice", label: "Current share price", nullable: true},
}

// TerminalPositionUpdate saves the cells one edit carries and answers with the
// re-rendered row plus the footer out of band. The backend computes every
// derived value; this handler only formats what it returns. Every outcome is
// a 200 with markup, because htmx 4 does not swap 4xx bodies.
func (h *AppHandler) TerminalPositionUpdate(w http.ResponseWriter, r *http.Request) {
	id, ok := terminalIDFrom(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	client, ok := h.terminalClientOr502(w)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Could not read that edit.", http.StatusBadRequest)
		return
	}
	body, problem := parseTerminalUpdateForm(r.PostForm)
	var saved *terminalapi.TerminalPositionResponse
	if problem == "" {
		saved, problem = h.patchTerminalPosition(r, client, id, body)
	}
	summary := h.loadTerminalSummary(r, client)
	currency := ""
	if summary != nil {
		currency = summary.Currency
	}
	if saved == nil {
		var listCurrency string
		saved, listCurrency = h.findTerminalPosition(r, client, id)
		if currency == "" {
			currency = listCurrency
		}
	}
	if saved == nil {
		// Deleted elsewhere: an empty answer swaps the row away.
		setHTMLContentType(w)
		return
	}
	row := terminalRowVM(saved, currency, h.isPro(r))
	row.FieldError = problem
	row.DetailsOpen = r.PostForm.Get("details") == "open"
	var footer terminal.FooterVM
	if summary != nil {
		footer = terminalFooterVM(summary)
	}
	h.renderTerminalFragment(w, r, terminal.RowUpdate(row, footer, summary != nil))
}

// parseTerminalUpdateForm turns the cells a request carries into a PATCH that
// changes exactly those fields. A cell left out of the form is left alone; an
// emptied optional cell is cleared, never sent as 0.
func parseTerminalUpdateForm(form url.Values) (terminalapi.TerminalPositionUpdateRequest, string) {
	var body terminalapi.TerminalPositionUpdateRequest
	if form.Has("ticker") {
		ticker, ok := normalizeTerminalTicker(form.Get("ticker"))
		if !ok {
			return body, terminalTickerProblem
		}
		body.Ticker = &ticker
	}
	var cleared []string
	for _, field := range terminalNumberFields {
		if !form.Has(field.name) {
			continue
		}
		raw := strings.TrimSpace(form.Get(field.name))
		if raw == "" && field.nullable {
			cleared = append(cleared, field.name)
			continue
		}
		value, err := format.ParseAmount(raw)
		if err != nil {
			return body, field.label + " needs a number."
		}
		setTerminalNumber(&body, field.name, value)
	}
	if len(cleared) > 0 {
		body.Clear = &cleared
	}
	return body, ""
}

func setTerminalNumber(body *terminalapi.TerminalPositionUpdateRequest, name string, value float64) {
	switch name {
	case "sharesOutstanding":
		body.SharesOutstanding = &value
	case "terminalShareCount":
		body.TerminalShareCount = &value
	case "terminalMarketCap":
		body.TerminalMarketCap = &value
	case "valueWanted":
		body.ValueWanted = &value
	case "sharesOwned":
		body.SharesOwned = &value
	case "currentSharePrice":
		body.CurrentSharePrice = &value
	}
}

func (h *AppHandler) patchTerminalPosition(r *http.Request, client *terminalapi.ClientWithResponses, id uuid.UUID, body terminalapi.TerminalPositionUpdateRequest) (*terminalapi.TerminalPositionResponse, string) {
	resp, err := client.UpdateTerminalPositionWithResponse(r.Context(), id, body, h.terminalEditor(r))
	if err != nil {
		slog.Warn("update terminal position", "error", err)
		return nil, terminalSaveFailed
	}
	if resp.JSON200 != nil {
		return resp.JSON200, ""
	}
	return nil, terminalWriteProblem(resp.StatusCode(), resp.Body, http.StatusOK)
}

// findTerminalPosition re-reads a row after a rejected edit, so the error can
// render under the values that are actually stored. It also returns the list
// currency for formatting.
func (h *AppHandler) findTerminalPosition(r *http.Request, client *terminalapi.ClientWithResponses, id uuid.UUID) (*terminalapi.TerminalPositionResponse, string) {
	resp, err := client.ListTerminalPositionsWithResponse(r.Context(), nil, h.terminalEditor(r))
	if err != nil || resp.JSON200 == nil {
		return nil, ""
	}
	for i := range resp.JSON200.Positions {
		if resp.JSON200.Positions[i].Id == id {
			return &resp.JSON200.Positions[i], resp.JSON200.Currency
		}
	}
	return nil, resp.JSON200.Currency
}

func (h *AppHandler) renderTerminalFragment(w http.ResponseWriter, r *http.Request, component templ.Component) {
	setHTMLContentType(w)
	if err := component.Render(r.Context(), w); err != nil {
		slog.Error("render terminal fragment", "path", r.URL.Path, "error", err)
		http.Error(w, "Failed to render", http.StatusInternalServerError)
	}
}
```

- [ ] **Step 4: Mount the route and pin it**

In `MountTerminalRoutes` (`internal/handlers/terminal.go`), add a line after `r.Get("/terminal", h.Terminal)`:
```go
	r.Patch("/terminal/positions/{id}", h.TerminalPositionUpdate)
```
In `internal/server/terminal_routes_test.go`, add to `terminalRoutes`:
```go
	"PATCH /terminal/positions/{id}",
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `GOFLAGS=-mod=mod go test ./internal/handlers/ ./internal/server/ -run 'TerminalCellEdit|TerminalRoutes' -count=1 -v`
Expected: PASS for 11 tests.

- [ ] **Step 6: Commit**

```bash
git add internal/handlers/terminal_update.go internal/handlers/terminal_update_test.go internal/handlers/terminal.go internal/server/terminal_routes_test.go
git commit -m "feat(terminal): inline cell edits re-render the row and footer from the backend"
```

---

### Task 6: Row actions: create, duplicate, delete, reorder, sample use and dismiss

**Files:**
- Create: `internal/handlers/terminal_actions.go`
- Modify: `internal/handlers/terminal.go` (`MountTerminalRoutes`)
- Modify: `internal/server/terminal_routes_test.go`
- Test: `internal/handlers/terminal_actions_test.go`

**Interfaces:**
- Consumes: `fillTerminalWorkspace`, `newTerminalCreateForm`, `renderTerminalFragment`, `terminalIdempotencyEditor`, `terminalWriteProblem`, `terminal.Workspace`, `terminal.WorkspaceUnavailable`.
- Produces:
  - Routes: `POST /terminal/positions` → `TerminalPositionCreate` (form `ticker`, `terminalShareCount`, `terminalMarketCap`, `valueWanted`, optional `sharesOwned`, `idempotency_key`); `POST /terminal/positions/{id}/duplicate` → `TerminalPositionDuplicate`; `DELETE /terminal/positions/{id}` → `TerminalPositionDelete`; `POST /terminal/positions/{id}/move` (form `dir=up|down`) → `TerminalPositionMove`; `POST /terminal/sample/dismiss` → `TerminalSampleDismiss`. All answer with `terminal.Workspace`.
  - `(h *AppHandler) renderTerminalWorkspace(w, r, client, mutate func(*terminal.PageVM))`.
  - `moveIndex[T any](items []T, i int, dir string) ([]T, bool)`.
  - `parseTerminalCreateForm(url.Values) (terminal.CreateFormVM, terminalapi.TerminalPositionCreateRequest, string)`.

- [ ] **Step 1: Write the failing tests**

`internal/handlers/terminal_actions_test.go`:
```go
package handlers

import (
	"net/http"
	"net/url"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTerminalCreateParsesAmountsAndSendsTheIdempotencyKey(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/positions", url.Values{
		"ticker": {"amzn"}, "terminalShareCount": {"11B"}, "terminalMarketCap": {"10T"},
		"valueWanted": {"1M"}, "sharesOwned": {""}, "idempotency_key": {"k1"},
	})

	require.Equal(t, http.StatusOK, rec.Code)
	assert.JSONEq(t, `{"ticker":"AMZN","terminalShareCount":11000000000,"terminalMarketCap":10000000000000,"valueWanted":1000000}`,
		backend.body("POST /v1/terminal-positions"))
	assert.Equal(t, "k1", backend.header("POST /v1/terminal-positions", "Idempotency-Key"))
	body := rec.Body.String()
	assert.Contains(t, body, `id="terminal-workspace"`)
	assert.Contains(t, body, `id="terminal-create" x-data="{ open: false }"`, "a successful create closes the form")
}

func TestTerminalCreateUsesTheSampleValues(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	form := url.Values{"ticker": {"AMZN"}, "terminalShareCount": {"11000000000"}, "terminalMarketCap": {"10000000000000"}, "valueWanted": {"1000000"}}
	serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/positions", form)
	assert.JSONEq(t, `{"ticker":"AMZN","terminalShareCount":11000000000,"terminalMarketCap":10000000000000,"valueWanted":1000000}`,
		backend.body("POST /v1/terminal-positions"))
}

func TestTerminalCreateKeepsTheFormOpenOnBadInput(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/positions", url.Values{
		"ticker": {"amzn"}, "terminalShareCount": {"11B"}, "terminalMarketCap": {"10T"}, "valueWanted": {""},
	})
	require.Equal(t, http.StatusOK, rec.Code)
	assert.False(t, backend.called("POST /v1/terminal-positions"))
	body := rec.Body.String()
	assert.Contains(t, body, "Value wanted needs a number.")
	assert.Contains(t, body, `id="terminal-create" x-data="{ open: true }"`)
	assert.Contains(t, body, `value="11B"`, "what was typed survives the error")
}

func TestTerminalCreateShowsTheBackendReason(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{
		"POST /v1/terminal-positions": {http.StatusUnprocessableEntity, `{"error":true,"reason":"sharesOwned must not be negative."}`},
	})
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/positions", url.Values{
		"ticker": {"amzn"}, "terminalShareCount": {"11B"}, "terminalMarketCap": {"10T"}, "valueWanted": {"1M"}, "sharesOwned": {"-1"},
	})
	assert.Contains(t, rec.Body.String(), "sharesOwned must not be negative.")
}

func TestTerminalDuplicateAndDeleteCallTheBackend(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	dup := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/positions/"+terminalAMZNID+"/duplicate", url.Values{})
	assert.True(t, backend.called("POST /v1/terminal-positions/"+terminalAMZNID+"/duplicate"))
	assert.Contains(t, dup.Body.String(), `id="terminal-workspace"`)

	del := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodDelete, "/terminal/positions/"+terminalAMZNID, nil)
	assert.True(t, backend.called("DELETE /v1/terminal-positions/"+terminalAMZNID))
	assert.Contains(t, del.Body.String(), `id="terminal-workspace"`)
	assert.NotContains(t, del.Body.String(), "Could not delete")
}

func TestTerminalDeleteFailureSaysSo(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{
		"DELETE /v1/terminal-positions/" + terminalAMZNID: {http.StatusInternalServerError, ""},
	})
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodDelete, "/terminal/positions/"+terminalAMZNID, nil)
	assert.Contains(t, rec.Body.String(), "Could not delete that row. Try again.")
}

func TestTerminalMoveDownSendsTheNewOrder(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/positions/"+terminalAMZNID+"/move", url.Values{"dir": {"down"}})
	assert.JSONEq(t, `{"ids":["`+terminalVGID+`","`+terminalAMZNID+`","`+terminalSOFIID+`"]}`, backend.body("PUT /v1/terminal-positions/order"))
}

func TestTerminalMoveUpAtTheTopDoesNothing(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/positions/"+terminalAMZNID+"/move", url.Values{"dir": {"up"}})
	assert.False(t, backend.called("PUT /v1/terminal-positions/order"))
	assert.Contains(t, rec.Body.String(), `id="terminal-workspace"`)
}

func TestMoveIndex(t *testing.T) {
	t.Parallel()
	got, ok := moveIndex([]string{"a", "b", "c"}, 1, "up")
	assert.True(t, ok)
	assert.Equal(t, []string{"b", "a", "c"}, got)
	got, ok = moveIndex([]string{"a", "b", "c"}, 1, "down")
	assert.True(t, ok)
	assert.Equal(t, []string{"a", "c", "b"}, got)
	_, ok = moveIndex([]string{"a", "b"}, 1, "down")
	assert.False(t, ok)
	_, ok = moveIndex([]string{"a", "b"}, -1, "up")
	assert.False(t, ok)
	_, ok = moveIndex([]string{"a", "b"}, 0, "sideways")
	assert.False(t, ok)
}

func TestTerminalSampleDismissSetsACookieAndHidesTheSample(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{
		"GET /v1/terminal-positions":         {http.StatusOK, terminalEmptyListJSON},
		"GET /v1/terminal-positions/summary": {http.StatusOK, terminalEmptySummaryJSON},
	})
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/sample/dismiss", url.Values{})
	require.Equal(t, http.StatusOK, rec.Code)
	dismissed := false
	for _, c := range rec.Result().Cookies() { // the session cookie is set too, so look by name
		if c.Name == terminalSampleCookie && c.Value == "1" {
			dismissed = true
		}
	}
	assert.True(t, dismissed)
	assert.NotContains(t, rec.Body.String(), "Use this row")
	assert.Contains(t, rec.Body.String(), "No scenarios yet.")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `GOFLAGS=-mod=mod go test ./internal/handlers/ -run 'TerminalCreate|TerminalDuplicate|TerminalDelete|TerminalMove|MoveIndex|TerminalSample' -count=1`
Expected: FAIL to compile with `undefined: moveIndex`.

- [ ] **Step 3: Write the handlers**

`internal/handlers/terminal_actions.go`:
```go
package handlers

import (
	"log/slog"
	"net/http"
	"net/url"
	"slices"
	"strings"

	"github.com/FinancePlanner/StockPlanWeb/internal/api/terminalapi"
	"github.com/FinancePlanner/StockPlanWeb/internal/format"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/terminal"
	"github.com/google/uuid"
)

const (
	terminalSampleCookieMaxAge = 60 * 60 * 24 * 365
	terminalMoveFailed         = "Could not move that row. Try again."
)

// renderTerminalWorkspace reloads the rows and totals and answers with the
// workspace region. mutate runs after the load, for form state and notices.
func (h *AppHandler) renderTerminalWorkspace(w http.ResponseWriter, r *http.Request, client *terminalapi.ClientWithResponses, mutate func(*terminal.PageVM)) {
	vm := terminal.PageVM{Copy: terminalCopy(r.Context()), IsPro: h.isPro(r), Create: newTerminalCreateForm("")}
	h.fillTerminalWorkspace(r, client, &vm)
	if mutate != nil {
		mutate(&vm)
	}
	if vm.LoadError {
		h.renderTerminalFragment(w, r, terminal.WorkspaceUnavailable())
		return
	}
	h.renderTerminalFragment(w, r, terminal.Workspace(vm))
}

// TerminalPositionCreate adds a row from the create form or the sample's
// "Use this row". A rejected submit re-opens the form with what was typed.
func (h *AppHandler) TerminalPositionCreate(w http.ResponseWriter, r *http.Request) {
	client, ok := h.terminalClientOr502(w)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Could not read that form.", http.StatusBadRequest)
		return
	}
	form, body, problem := parseTerminalCreateForm(r.PostForm)
	if problem == "" {
		resp, err := client.CreateTerminalPositionWithResponse(r.Context(), body, h.terminalEditor(r), terminalIdempotencyEditor(form.IdempotencyKey))
		if err != nil {
			slog.Warn("create terminal position", "error", err)
			problem = terminalSaveFailed
		} else {
			problem = terminalWriteProblem(resp.StatusCode(), resp.Body, http.StatusCreated)
		}
	}
	h.renderTerminalWorkspace(w, r, client, func(vm *terminal.PageVM) {
		if problem != "" {
			form.Open = true
			form.Error = problem
			vm.Create = form
		}
	})
}

// parseTerminalCreateForm validates the create form. Share count and market
// cap may be zero or negative: the backend stores them and reports a
// scenarioError, so a half-finished row still saves (spec).
func parseTerminalCreateForm(form url.Values) (terminal.CreateFormVM, terminalapi.TerminalPositionCreateRequest, string) {
	vm := terminal.CreateFormVM{
		Ticker:             strings.TrimSpace(form.Get("ticker")),
		TerminalShareCount: strings.TrimSpace(form.Get("terminalShareCount")),
		TerminalMarketCap:  strings.TrimSpace(form.Get("terminalMarketCap")),
		ValueWanted:        strings.TrimSpace(form.Get("valueWanted")),
		SharesOwned:        strings.TrimSpace(form.Get("sharesOwned")),
		IdempotencyKey:     strings.TrimSpace(form.Get("idempotency_key")),
	}
	if vm.IdempotencyKey == "" {
		vm.IdempotencyKey = uuid.NewString()
	}
	var body terminalapi.TerminalPositionCreateRequest
	ticker, ok := normalizeTerminalTicker(vm.Ticker)
	if !ok {
		return vm, body, terminalTickerProblem
	}
	count, err := format.ParseAmount(vm.TerminalShareCount)
	if err != nil {
		return vm, body, "Terminal share count needs a number."
	}
	marketCap, err := format.ParseAmount(vm.TerminalMarketCap)
	if err != nil {
		return vm, body, "Terminal market cap needs a number."
	}
	wanted, err := format.ParseAmount(vm.ValueWanted)
	if err != nil {
		return vm, body, "Value wanted needs a number."
	}
	body = terminalapi.TerminalPositionCreateRequest{Ticker: ticker, TerminalShareCount: count, TerminalMarketCap: marketCap, ValueWanted: wanted}
	if vm.SharesOwned != "" {
		owned, ownedErr := format.ParseAmount(vm.SharesOwned)
		if ownedErr != nil {
			return vm, body, "Shares owned needs a number."
		}
		body.SharesOwned = &owned
	}
	return vm, body, ""
}

// TerminalPositionDuplicate copies a row as a scenario variant; the backend
// places the copy right after the source.
func (h *AppHandler) TerminalPositionDuplicate(w http.ResponseWriter, r *http.Request) {
	id, ok := terminalIDFrom(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	client, ok := h.terminalClientOr502(w)
	if !ok {
		return
	}
	notice := ""
	resp, err := client.DuplicateTerminalPositionWithResponse(r.Context(), id, h.terminalEditor(r))
	if err != nil || resp.JSON201 == nil {
		slog.Warn("duplicate terminal position", "error", err)
		notice = "Could not duplicate that row. Try again."
	}
	h.renderTerminalWorkspace(w, r, client, func(vm *terminal.PageVM) { vm.Notice = notice })
}

// TerminalPositionDelete removes a row. A 404 means it is already gone, which
// is the outcome the reader asked for.
func (h *AppHandler) TerminalPositionDelete(w http.ResponseWriter, r *http.Request) {
	id, ok := terminalIDFrom(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	client, ok := h.terminalClientOr502(w)
	if !ok {
		return
	}
	notice := ""
	resp, err := client.DeleteTerminalPositionWithResponse(r.Context(), id, h.terminalEditor(r))
	if err != nil || (resp.StatusCode() != http.StatusNoContent && resp.StatusCode() != http.StatusNotFound) {
		slog.Warn("delete terminal position", "error", err)
		notice = "Could not delete that row. Try again."
	}
	h.renderTerminalWorkspace(w, r, client, func(vm *terminal.PageVM) { vm.Notice = notice })
}

// TerminalPositionMove moves a row one step up or down by sending the full new
// order (PUT /v1/terminal-positions/order). There is no drag library here, so
// drag-and-drop is left for later (spec).
func (h *AppHandler) TerminalPositionMove(w http.ResponseWriter, r *http.Request) {
	id, ok := terminalIDFrom(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	client, ok := h.terminalClientOr502(w)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Could not read that request.", http.StatusBadRequest)
		return
	}
	notice := h.moveTerminalPosition(r, client, id, r.PostForm.Get("dir"))
	h.renderTerminalWorkspace(w, r, client, func(vm *terminal.PageVM) { vm.Notice = notice })
}

func (h *AppHandler) moveTerminalPosition(r *http.Request, client *terminalapi.ClientWithResponses, id uuid.UUID, dir string) string {
	resp, err := client.ListTerminalPositionsWithResponse(r.Context(), nil, h.terminalEditor(r))
	if err != nil || resp.JSON200 == nil {
		return terminalMoveFailed
	}
	positions := resp.JSON200.Positions
	ids := make([]uuid.UUID, 0, len(positions))
	from := -1
	for i := range positions {
		ids = append(ids, positions[i].Id)
		if positions[i].Id == id {
			from = i
		}
	}
	order, moved := moveIndex(ids, from, dir)
	if !moved {
		return ""
	}
	put, err := client.ReorderTerminalPositionsWithResponse(r.Context(), terminalapi.TerminalPositionOrderRequest{Ids: order}, h.terminalEditor(r))
	if err != nil || put.JSON200 == nil {
		slog.Warn("reorder terminal positions", "error", err)
		return terminalMoveFailed
	}
	return ""
}

// moveIndex returns items with the one at i swapped one step "up" or "down",
// or ok=false when it is already at that edge (or i/dir is not valid).
func moveIndex[T any](items []T, i int, dir string) ([]T, bool) {
	j := i - 1
	if dir == "down" {
		j = i + 1
	}
	if (dir != "up" && dir != "down") || i < 0 || i >= len(items) || j < 0 || j >= len(items) {
		return items, false
	}
	out := slices.Clone(items)
	out[i], out[j] = out[j], out[i]
	return out, true
}

// TerminalSampleDismiss hides the sample row for a year. It is a cookie
// because the sample is never stored as user data.
func (h *AppHandler) TerminalSampleDismiss(w http.ResponseWriter, r *http.Request) {
	client, ok := h.terminalClientOr502(w)
	if !ok {
		return
	}
	http.SetCookie(w, &http.Cookie{ // #nosec G124 -- Secure follows COOKIE_SECURE so local HTTP development still works.
		Name:     terminalSampleCookie,
		Value:    "1",
		Path:     terminalActivePath,
		MaxAge:   terminalSampleCookieMaxAge,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   h.deps.Config != nil && h.deps.Config.CookieSecure,
	})
	h.renderTerminalWorkspace(w, r, client, func(vm *terminal.PageVM) { vm.ShowSample = false })
}
```

- [ ] **Step 4: Mount the routes and pin them**

In `MountTerminalRoutes`, after the PATCH line, add:
```go
	r.Post("/terminal/positions", h.TerminalPositionCreate)
	r.Delete("/terminal/positions/{id}", h.TerminalPositionDelete)
	r.Post("/terminal/positions/{id}/duplicate", h.TerminalPositionDuplicate)
	r.Post("/terminal/positions/{id}/move", h.TerminalPositionMove)
	r.Post("/terminal/sample/dismiss", h.TerminalSampleDismiss)
```
Add these to `terminalRoutes` in `internal/server/terminal_routes_test.go`:
```go
	"POST /terminal/positions",
	"DELETE /terminal/positions/{id}",
	"POST /terminal/positions/{id}/duplicate",
	"POST /terminal/positions/{id}/move",
	"POST /terminal/sample/dismiss",
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `GOFLAGS=-mod=mod go test ./internal/handlers/ ./internal/server/ -run 'TerminalCreate|TerminalDuplicate|TerminalDelete|TerminalMove|MoveIndex|TerminalSample|TerminalRoutes' -count=1 -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/handlers/terminal_actions.go internal/handlers/terminal_actions_test.go internal/handlers/terminal.go internal/server/terminal_routes_test.go
git commit -m "feat(terminal): create, duplicate, delete, reorder and sample-row actions"
```

---

### Task 7: Autobuys side panel

**Files:**
- Create: `internal/pages/terminal/autobuys.go`
- Create: `internal/pages/terminal/autobuys.templ`
- Create: `internal/handlers/terminal_autobuys.go`
- Modify: `internal/pages/terminal/page.templ` (`Page`: add the aside)
- Modify: `internal/handlers/terminal.go` (`Terminal`: load autobuys; `MountTerminalRoutes`)
- Modify: `internal/server/assets/terminal.js` (`registerTerminal`)
- Modify: `internal/server/terminal_routes_test.go`
- Test: `internal/handlers/terminal_autobuys_test.go`

**Interfaces:**
- Consumes: `terminalAutobuysVM`, `terminal.AutobuysVM` / `AutobuyVM` / `AutobuyFormVM`, `terminal.IsKnownCadence`, `terminal.Cadence*`, `format.ParseAmount`, `normalizeTerminalTicker`, `terminalWriteProblem`, `terminalIdempotencyEditor`, `renderTerminalFragment`.
- Produces:
  - templ `AutobuysPanel(AutobuysVM)` (root `id="terminal-autobuys"`).
  - Package `terminal`: `AutobuyChip`, `AutobuyChips(symbol string) []AutobuyChip`, `(AutobuyChip) Prefill() string`, `(AutobuyFormVM) AlpineState() string`, `(AutobuysVM) FormFor(AutobuyVM) AutobuyFormVM`.
  - Routes: `POST /terminal/autobuys` → `TerminalAutobuyCreate`; `PATCH /terminal/autobuys/{id}` → `TerminalAutobuyUpdate`; `POST /terminal/autobuys/{id}/active` → `TerminalAutobuyActive`; `DELETE /terminal/autobuys/{id}` → `TerminalAutobuyDelete`. All answer with `AutobuysPanel`.
  - `(h *AppHandler) loadTerminalAutobuys(r, client) terminal.AutobuysVM`.
  - `parseAutobuyForm(url.Values) (terminal.AutobuyFormVM, autobuyInput, string)`.
  - JS: `Alpine.data('terminalAutobuyForm', initial => ...)`.

- [ ] **Step 1: Write the failing tests**

`internal/handlers/terminal_autobuys_test.go`:
```go
package handlers

import (
	"net/http"
	"net/url"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTerminalPageShowsAutobuysWithMonthlyEquivalents(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, nil)
	body := serveTerminal(t, svc, terminalTestOpts{}, http.MethodGet, "/terminal", nil).Body.String()

	assert.Contains(t, body, `id="terminal-autobuys"`)
	assert.Contains(t, body, "Weekly buy")
	assert.Contains(t, body, "$216.67 a month")
	assert.Contains(t, body, "Add a monthly base to count this one.")
	assert.Contains(t, body, "Paused")
	assert.Contains(t, body, "Every two months")
	assert.Contains(t, body, "Monthly total")
	assert.NotContains(t, body, "401k 4%", "example chips are for the empty state only")
}

func TestTerminalAutobuyChipsOnlyPrefill(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, map[string]terminalReply{"GET /v1/autobuys": {http.StatusOK, emptyAutobuysJSON}})
	body := serveTerminal(t, svc, terminalTestOpts{}, http.MethodGet, "/terminal", nil).Body.String()

	assert.Contains(t, body, "401k 4%")
	assert.Contains(t, body, "$50 weekly")
	assert.Contains(t, body, "$275 every two months")
	assert.Contains(t, body, "prefill(")
	assert.False(t, backend.called("POST /v1/autobuys"), "a chip never creates anything by itself")
}

func TestTerminalAutobuyCreateWeekly(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/autobuys", url.Values{
		"label": {"Weekly buy"}, "amount": {"50"}, "cadence": {"weekly"}, "ticker": {""}, "percent": {"9"}, "idempotency_key": {"a1"},
	})
	require.Equal(t, http.StatusOK, rec.Code)
	assert.JSONEq(t, `{"label":"Weekly buy","amount":50,"cadence":"weekly","active":true}`, backend.body("POST /v1/autobuys"))
	assert.Equal(t, "a1", backend.header("POST /v1/autobuys", "Idempotency-Key"))
	assert.Contains(t, rec.Body.String(), `id="terminal-autobuys"`)
}

func TestTerminalAutobuyCreatePercentConvertsToARatio(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/autobuys", url.Values{
		"label": {"401k"}, "amount": {"4,000"}, "cadence": {"percentOfContribution"}, "percent": {"4"}, "ticker": {"voo"},
	})
	assert.JSONEq(t, `{"label":"401k","amount":4000,"cadence":"percentOfContribution","percent":0.04,"ticker":"VOO","active":true}`,
		backend.body("POST /v1/autobuys"))
}

func TestTerminalAutobuyCreatePercentWithoutBaseIsAllowed(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/autobuys", url.Values{
		"label": {"401k"}, "amount": {""}, "cadence": {"percentOfContribution"}, "percent": {"4"},
	})
	assert.JSONEq(t, `{"label":"401k","amount":0,"cadence":"percentOfContribution","percent":0.04,"active":true}`,
		backend.body("POST /v1/autobuys"))
}

func TestTerminalAutobuyCreateRejectsAMissingPercent(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/autobuys", url.Values{
		"label": {"401k"}, "amount": {"4000"}, "cadence": {"percentOfContribution"}, "percent": {""},
	})
	assert.False(t, backend.called("POST /v1/autobuys"))
	assert.Contains(t, rec.Body.String(), "Enter a percent between 0 and 100.")
}

func TestTerminalAutobuyCreateShowsTheBackendReason(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{
		"POST /v1/autobuys": {http.StatusUnprocessableEntity, `{"error":true,"reason":"amount must not be negative."}`},
	})
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/autobuys", url.Values{
		"label": {"x"}, "amount": {"5"}, "cadence": {"monthly"},
	})
	assert.Contains(t, rec.Body.String(), "amount must not be negative.")
}

func TestTerminalAutobuyUpdateClearsTickerAndPercent(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPatch, "/terminal/autobuys/"+weeklyAutobuyID, url.Values{
		"label": {"Monthly buy"}, "amount": {"100"}, "cadence": {"monthly"}, "ticker": {""}, "percent": {""},
	})
	assert.JSONEq(t, `{"label":"Monthly buy","amount":100,"cadence":"monthly","clear":["ticker","percent"]}`,
		backend.body("PATCH /v1/autobuys/"+weeklyAutobuyID))
}

func TestTerminalAutobuyUpdateErrorReopensThatItemsForm(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPatch, "/terminal/autobuys/"+weeklyAutobuyID, url.Values{
		"label": {""}, "amount": {"100"}, "cadence": {"monthly"},
	})
	assert.False(t, backend.called("PATCH /v1/autobuys/"+weeklyAutobuyID))
	body := rec.Body.String()
	assert.Contains(t, body, "Give this autobuy a name.")
	assert.Contains(t, body, `id="terminal-autobuy-`+weeklyAutobuyID+`" class="rounded-xl border border-border p-3" x-data="{ editing: true }"`)
}

func TestTerminalAutobuyActiveToggle(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	key := "PATCH /v1/autobuys/" + weeklyAutobuyID
	serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/autobuys/"+weeklyAutobuyID+"/active", url.Values{})
	assert.JSONEq(t, `{"active":false}`, backend.body(key), "an unchecked switch sends nothing, which means off")

	serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/autobuys/"+weeklyAutobuyID+"/active", url.Values{"active": {"true"}})
	assert.JSONEq(t, `{"active":true}`, backend.body(key))
}

func TestTerminalAutobuyDelete(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodDelete, "/terminal/autobuys/"+weeklyAutobuyID, nil)
	assert.True(t, backend.called("DELETE /v1/autobuys/"+weeklyAutobuyID))
	assert.Contains(t, rec.Body.String(), `id="terminal-autobuys"`)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `GOFLAGS=-mod=mod go test ./internal/handlers/ -run 'TerminalAutobuy|TerminalPageShowsAutobuys' -count=1`
Expected: FAIL. The page has no `terminal-autobuys`, and the routes answer 405.

- [ ] **Step 3: Write the panel helpers**

`internal/pages/terminal/autobuys.go`:
```go
package terminal

import (
	"encoding/json"
	"fmt"

	"github.com/FinancePlanner/StockPlanWeb/internal/pages/components"
	"github.com/a-h/templ"
)

// AutobuyChip is a one-click example in the empty panel. It only fills the
// add form; nothing is created until the user submits it.
type AutobuyChip struct {
	Label   string
	Name    string
	Amount  string
	Cadence string
	Percent string
}

// AutobuyChips are the spec's three examples, in the user's currency.
func AutobuyChips(symbol string) []AutobuyChip {
	return []AutobuyChip{
		{Label: "401k 4%", Name: "401k", Cadence: CadencePercent, Percent: "4"},
		{Label: symbol + "50 weekly", Name: "Weekly buy", Amount: "50", Cadence: CadenceWeekly},
		{Label: symbol + "275 every two months", Name: "Every two months", Amount: "275", Cadence: CadenceBimonthly},
	}
}

type autobuyFormState struct {
	Label   string `json:"label"`
	Ticker  string `json:"ticker"`
	Amount  string `json:"amount"`
	Cadence string `json:"cadence"`
	Percent string `json:"percent"`
}

// Prefill is the chip's Alpine click expression.
func (c AutobuyChip) Prefill() string {
	return "prefill(" + jsonObject(autobuyFormState{Label: c.Name, Amount: c.Amount, Cadence: c.Cadence, Percent: c.Percent}) + ")"
}

// AlpineState seeds terminalAutobuyForm with the form's values, so x-model
// starts from what the server rendered.
func (f AutobuyFormVM) AlpineState() string {
	return "terminalAutobuyForm(" + jsonObject(autobuyFormState{
		Label: f.Label, Ticker: f.Ticker, Amount: f.Amount, Cadence: f.Cadence, Percent: f.Percent,
	}) + ")"
}

// FormFor is item's edit form: the rejected values when that item's save just
// failed, otherwise the item as stored.
func (vm AutobuysVM) FormFor(item AutobuyVM) AutobuyFormVM {
	if vm.EditingID == item.ID {
		return vm.EditForm
	}
	return AutobuyFormVM{ID: item.ID, Label: item.Label, Ticker: item.Ticker, Amount: item.Amount, Cadence: item.Cadence, Percent: item.Percent}
}

func jsonObject(v any) string {
	raw, err := json.Marshal(v)
	if err != nil {
		return "{}"
	}
	return string(raw)
}

func editingState(open bool) string { return fmt.Sprintf("{ editing: %t }", open) }

func autobuyFormID(id string) string {
	if id == "" {
		return "terminal-autobuy-add"
	}
	return "terminal-autobuy-form-" + id
}

func cadenceOptions(selected string) []components.Option {
	options := []components.Option{
		{Value: CadenceWeekly, Label: "Weekly"},
		{Value: CadenceBiweekly, Label: "Every two weeks"},
		{Value: CadenceMonthly, Label: "Monthly"},
		{Value: CadenceBimonthly, Label: "Every two months"},
		{Value: CadencePercent, Label: "Percent of a monthly base"},
	}
	for i := range options {
		options[i].Selected = options[i].Value == selected
	}
	return options
}

// autobuyActiveAttrs wires the per-row switch to the active toggle route.
func autobuyActiveAttrs(item AutobuyVM) templ.Attributes {
	return templ.Attributes{
		"aria-label": "Active",
		"hx-post":    "/terminal/autobuys/" + item.ID + "/active",
		"hx-trigger": "change",
		"hx-target":  "#terminal-autobuys",
		"hx-swap":    "outerHTML",
		"hx-include": "this",
	}
}
```

- [ ] **Step 4: Write the panel template**

`internal/pages/terminal/autobuys.templ`:
```templ
package terminal

import (
	"github.com/FinancePlanner/StockPlanWeb/internal/components/icon"
	"github.com/FinancePlanner/StockPlanWeb/internal/components/input"
	"github.com/FinancePlanner/StockPlanWeb/internal/components/vigil"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/components"
)

// AutobuysPanel is the side panel. Every write answers with the whole panel,
// so the list, the per-row monthly amounts and the total always agree.
templ AutobuysPanel(vm AutobuysVM) {
	<div id="terminal-autobuys">
		@vigil.Panel("p-5 space-y-4", "terminal-autobuys-title") {
			@vigil.PanelHeader("terminal-autobuys-title", "Autobuys", "Recurring buys, shown as a monthly amount.", nil)
			if vm.LoadError {
				<p class="text-footnote text-muted-foreground">Autobuys are unavailable right now.</p>
			} else {
				if vm.Notice != "" {
					<p role="alert" class="text-footnote text-destructive">{ vm.Notice }</p>
				}
				if len(vm.Items) > 0 {
					<ul class="space-y-2">
						for _, item := range vm.Items {
							@autobuyItem(item, vm.FormFor(item), vm.EditingID == item.ID)
						}
					</ul>
					<p class="flex justify-between border-t border-border pt-2 text-subhead font-semibold">
						<span>Monthly total</span>
						<span class="tabular-nums">{ vm.MonthlyTotal }</span>
					</p>
					@autobuyForm(vm.Form, nil)
				} else {
					<p class="text-footnote text-muted-foreground">No autobuys yet. Start from an example, then adjust it.</p>
					@autobuyForm(vm.Form, AutobuyChips(vm.CurrencySymbol))
				}
			}
		}
	</div>
}

templ autobuyItem(item AutobuyVM, form AutobuyFormVM, editing bool) {
	<li id={ "terminal-autobuy-" + item.ID } class="rounded-xl border border-border p-3" x-data={ editingState(editing) }>
		<div class="flex items-start justify-between gap-3" x-show="!editing">
			<div class="min-w-0">
				<p class="font-semibold">
					{ item.Label }
					if item.Ticker != "" {
						<span class="text-muted-foreground">· { item.Ticker }</span>
					}
					if !item.Active {
						<span class="ml-1 rounded bg-muted px-1.5 py-0.5 text-[0.65rem] font-semibold uppercase">Paused</span>
					}
				</p>
				<p class="text-footnote text-muted-foreground">{ item.AmountLabel } · { item.CadenceLabel }</p>
				if item.NeedsBase {
					<p class="text-footnote text-muted-foreground">Add a monthly base to count this one.</p>
				} else {
					<p class="text-footnote tabular-nums">{ item.MonthlyEquivalent } a month</p>
				}
			</div>
			<div class="flex items-center gap-1">
				@components.SwitchField(components.SwitchFieldProps{
					ID:         "terminal-autobuy-active-" + item.ID,
					Name:       "active",
					Value:      "true",
					Checked:    item.Active,
					Attributes: autobuyActiveAttrs(item),
				})
				@components.NativeButton(components.ButtonProps{Class: iconButtonClass, Attributes: templ.Attributes{"@click": "editing = true", "aria-label": "Edit " + item.Label}}) {
					@icon.Icon("pencil")(icon.Props{Class: "h-4 w-4"})
				}
				@components.NativeButton(components.ButtonProps{Class: iconButtonClass, Attributes: templ.Attributes{
					"hx-delete":  "/terminal/autobuys/" + item.ID,
					"hx-confirm": "Delete the " + item.Label + " autobuy?",
					"hx-target":  "#terminal-autobuys",
					"hx-swap":    "outerHTML",
					"aria-label": "Delete " + item.Label,
				}}) {
					@icon.Icon("trash-2")(icon.Props{Class: "h-4 w-4"})
				}
			</div>
		</div>
		<div x-show="editing" x-cloak?={ !editing }>
			@autobuyForm(form, nil)
		</div>
	</li>
}

// autobuyForm is the add form (form.ID == "") or an item's edit form. Alpine
// only mirrors the fields so the example chips can fill them and the percent
// field can show for percent cadence; the server validates everything.
templ autobuyForm(form AutobuyFormVM, chips []AutobuyChip) {
	<form
		id={ autobuyFormID(form.ID) }
		class="space-y-3"
		if form.ID == "" {
			hx-post="/terminal/autobuys"
		} else {
			hx-patch={ "/terminal/autobuys/" + form.ID }
		}
		hx-target="#terminal-autobuys"
		hx-swap="outerHTML"
		x-data={ form.AlpineState() }
	>
		@components.CSRFField()
		if form.ID == "" {
			<input type="hidden" name="idempotency_key" value={ form.IdempotencyKey }/>
		}
		if len(chips) > 0 {
			<div class="flex flex-wrap gap-2">
				for _, chip := range chips {
					@components.SecondaryButton(components.ButtonProps{Attributes: templ.Attributes{"@click": chip.Prefill()}}) {
						{ chip.Label }
					}
				}
			</div>
		}
		@components.Field(components.FieldProps{ID: autobuyFormID(form.ID) + "-label", Name: "label", Label: "Name", Type: input.TypeText, Value: form.Label, Placeholder: "Weekly buy", Required: true, Attributes: templ.Attributes{"x-model": "label"}})
		@components.SelectField(components.SelectFieldProps{ID: autobuyFormID(form.ID) + "-cadence", Name: "cadence", Label: "How often", Options: cadenceOptions(form.Cadence), Attributes: templ.Attributes{"x-model": "cadence"}})
		@components.Field(components.FieldProps{ID: autobuyFormID(form.ID) + "-amount", Name: "amount", Label: "Amount", Type: input.TypeText, Value: form.Amount, Placeholder: "50", Attributes: templ.Attributes{"x-model": "amount", "inputmode": "decimal"}})
		<div class="space-y-2" x-show="cadence === 'percentOfContribution'" x-cloak?={ form.Cadence != CadencePercent }>
			<p class="text-footnote text-muted-foreground">For a percent, the amount is the monthly base it is taken from.</p>
			@components.Field(components.FieldProps{ID: autobuyFormID(form.ID) + "-percent", Name: "percent", Label: "Percent of base (%)", Type: input.TypeText, Value: form.Percent, Placeholder: "4", Attributes: templ.Attributes{"x-model": "percent", "inputmode": "decimal"}})
		</div>
		@components.Field(components.FieldProps{ID: autobuyFormID(form.ID) + "-ticker", Name: "ticker", Label: "Ticker (optional)", Type: input.TypeText, Value: form.Ticker, Placeholder: "VOO", Class: "uppercase", Autocomplete: "off", Attributes: templ.Attributes{"x-model": "ticker"}})
		if form.Error != "" {
			<p role="alert" class="text-footnote text-destructive">{ form.Error }</p>
		}
		<div class="flex gap-2">
			if form.ID == "" {
				@components.SubmitButton(components.ButtonProps{}) {
					Add autobuy
				}
			} else {
				@components.SubmitButton(components.ButtonProps{}) {
					Save
				}
				@components.GhostButton(components.ButtonProps{Attributes: templ.Attributes{"@click": "editing = false"}}) {
					Cancel
				}
			}
		</div>
	</form>
}
```

- [ ] **Step 5: Put the panel on the page**

In `internal/pages/terminal/page.templ`, inside `Page`, replace this block:
```templ
			<div class="terminal-layout grid gap-6">
				<div class="min-w-0 space-y-3">
					@components.SwitchField(components.SwitchFieldProps{
						ID:          "terminal-round-down",
						Label:       "Round down to whole shares",
						Description: "Display only. Saved numbers keep their decimals.",
						Attributes:  templ.Attributes{"x-model": "roundDown"},
					})
					@Workspace(vm)
				</div>
			</div>
```
with:
```templ
			<div class="terminal-layout grid gap-6 xl:grid-cols-[minmax(0,1fr)_20rem]">
				<div class="min-w-0 space-y-3">
					@components.SwitchField(components.SwitchFieldProps{
						ID:          "terminal-round-down",
						Label:       "Round down to whole shares",
						Description: "Display only. Saved numbers keep their decimals.",
						Attributes:  templ.Attributes{"x-model": "roundDown"},
					})
					@Workspace(vm)
				</div>
				<aside class="min-w-0" aria-label="Autobuys">
					@AutobuysPanel(vm.Autobuys)
				</aside>
			</div>
```
In `internal/handlers/terminal.go`, in `Terminal`, replace the last line `h.renderTerminalPage(w, r, vm)` (the one after the `fillTerminalWorkspace` check) with:
```go
	if !vm.LoadError {
		vm.Autobuys = h.loadTerminalAutobuys(r, client)
	}
	h.renderTerminalPage(w, r, vm)
```

- [ ] **Step 6: Write the handlers**

`internal/handlers/terminal_autobuys.go`:
```go
package handlers

import (
	"errors"
	"log/slog"
	"net/http"
	"net/url"
	"strings"

	"github.com/FinancePlanner/StockPlanWeb/internal/api/terminalapi"
	"github.com/FinancePlanner/StockPlanWeb/internal/format"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/terminal"
	"github.com/google/uuid"
)

const percentMax = 100

// autobuyInput is a validated add/edit form.
type autobuyInput struct {
	Label   string
	Ticker  string
	Amount  float64
	Cadence string
	Percent *float64 // ratio (0.04), set only for percent cadence
}

// loadTerminalAutobuys is best effort: the table works without the panel.
func (h *AppHandler) loadTerminalAutobuys(r *http.Request, client *terminalapi.ClientWithResponses) terminal.AutobuysVM {
	resp, err := client.ListAutobuysWithResponse(r.Context(), h.terminalEditor(r))
	if err != nil || resp.JSON200 == nil {
		slog.Warn("list autobuys", "error", err)
		return terminal.AutobuysVM{LoadError: true}
	}
	vm := terminalAutobuysVM(resp.JSON200)
	vm.Form.IdempotencyKey = uuid.NewString()
	return vm
}

func (h *AppHandler) renderAutobuysPanel(w http.ResponseWriter, r *http.Request, client *terminalapi.ClientWithResponses, mutate func(*terminal.AutobuysVM)) {
	vm := h.loadTerminalAutobuys(r, client)
	if mutate != nil && !vm.LoadError {
		mutate(&vm)
	}
	h.renderTerminalFragment(w, r, terminal.AutobuysPanel(vm))
}

// parseAutobuyForm validates the add/edit form. For percent cadence the
// amount is the monthly base and may be empty (then 0): the backend leaves a
// base-less row out of the total, per spec.
func parseAutobuyForm(form url.Values) (terminal.AutobuyFormVM, autobuyInput, string) {
	vm := terminal.AutobuyFormVM{
		Label:          strings.TrimSpace(form.Get("label")),
		Ticker:         strings.TrimSpace(form.Get("ticker")),
		Amount:         strings.TrimSpace(form.Get("amount")),
		Cadence:        strings.TrimSpace(form.Get("cadence")),
		Percent:        strings.TrimSpace(form.Get("percent")),
		IdempotencyKey: strings.TrimSpace(form.Get("idempotency_key")),
	}
	in := autobuyInput{Label: vm.Label, Cadence: vm.Cadence}
	if in.Label == "" {
		return vm, in, "Give this autobuy a name."
	}
	if !terminal.IsKnownCadence(in.Cadence) {
		return vm, in, "Pick how often it buys."
	}
	if vm.Ticker != "" {
		ticker, ok := normalizeTerminalTicker(vm.Ticker)
		if !ok {
			return vm, in, terminalTickerProblem
		}
		in.Ticker = ticker
	}
	isPercent := in.Cadence == terminal.CadencePercent
	amount, err := format.ParseAmount(vm.Amount)
	switch {
	case errors.Is(err, format.ErrEmpty) && isPercent:
		in.Amount = 0
	case err != nil || amount < 0:
		return vm, in, "Enter an amount of zero or more."
	default:
		in.Amount = amount
	}
	if isPercent {
		pct, pctErr := format.ParseAmount(vm.Percent)
		if pctErr != nil || pct <= 0 || pct > percentMax {
			return vm, in, "Enter a percent between 0 and 100."
		}
		ratio := pct / percentMax
		in.Percent = &ratio
	}
	return vm, in, ""
}

// TerminalAutobuyCreate adds an autobuy. A rejected submit keeps the add form's
// values and shows why.
func (h *AppHandler) TerminalAutobuyCreate(w http.ResponseWriter, r *http.Request) {
	client, ok := h.terminalClientOr502(w)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Could not read that form.", http.StatusBadRequest)
		return
	}
	form, in, problem := parseAutobuyForm(r.PostForm)
	if problem == "" {
		active := true
		body := terminalapi.AutobuyCreateRequest{Label: in.Label, Amount: in.Amount, Cadence: terminalapi.AutobuyCadence(in.Cadence), Percent: in.Percent, Active: &active}
		if in.Ticker != "" {
			body.Ticker = &in.Ticker
		}
		resp, err := client.CreateAutobuyWithResponse(r.Context(), body, h.terminalEditor(r), terminalIdempotencyEditor(form.IdempotencyKey))
		if err != nil {
			slog.Warn("create autobuy", "error", err)
			problem = terminalSaveFailed
		} else {
			problem = terminalWriteProblem(resp.StatusCode(), resp.Body, http.StatusCreated)
		}
	}
	h.renderAutobuysPanel(w, r, client, func(vm *terminal.AutobuysVM) {
		if problem != "" {
			form.Error = problem
			vm.Form = form
		}
	})
}

// TerminalAutobuyUpdate saves an edit form. An emptied ticker and a
// non-percent cadence clear the stored ticker and percent.
func (h *AppHandler) TerminalAutobuyUpdate(w http.ResponseWriter, r *http.Request) {
	id, ok := terminalIDFrom(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	client, ok := h.terminalClientOr502(w)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Could not read that form.", http.StatusBadRequest)
		return
	}
	form, in, problem := parseAutobuyForm(r.PostForm)
	form.ID = id.String()
	if problem == "" {
		cadence := terminalapi.AutobuyCadence(in.Cadence)
		body := terminalapi.AutobuyUpdateRequest{Label: &in.Label, Amount: &in.Amount, Cadence: &cadence}
		var cleared []string
		if in.Ticker != "" {
			body.Ticker = &in.Ticker
		} else {
			cleared = append(cleared, "ticker")
		}
		if in.Percent != nil {
			body.Percent = in.Percent
		} else {
			cleared = append(cleared, "percent")
		}
		if len(cleared) > 0 {
			body.Clear = &cleared
		}
		resp, err := client.UpdateAutobuyWithResponse(r.Context(), id, body, h.terminalEditor(r))
		if err != nil {
			slog.Warn("update autobuy", "error", err)
			problem = terminalSaveFailed
		} else {
			problem = terminalWriteProblem(resp.StatusCode(), resp.Body, http.StatusOK)
		}
	}
	h.renderAutobuysPanel(w, r, client, func(vm *terminal.AutobuysVM) {
		if problem != "" {
			form.Error = problem
			vm.EditingID = form.ID
			vm.EditForm = form
		}
	})
}

// TerminalAutobuyActive is the per-row switch. An unchecked checkbox submits
// nothing, so a missing "active" means off.
func (h *AppHandler) TerminalAutobuyActive(w http.ResponseWriter, r *http.Request) {
	id, ok := terminalIDFrom(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	client, ok := h.terminalClientOr502(w)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Could not read that request.", http.StatusBadRequest)
		return
	}
	active := r.PostForm.Get("active") == "true"
	notice := ""
	resp, err := client.UpdateAutobuyWithResponse(r.Context(), id, terminalapi.AutobuyUpdateRequest{Active: &active}, h.terminalEditor(r))
	if err != nil {
		notice = terminalSaveFailed
	} else {
		notice = terminalWriteProblem(resp.StatusCode(), resp.Body, http.StatusOK)
	}
	h.renderAutobuysPanel(w, r, client, func(vm *terminal.AutobuysVM) { vm.Notice = notice })
}

// TerminalAutobuyDelete removes an autobuy; a 404 means it is already gone.
func (h *AppHandler) TerminalAutobuyDelete(w http.ResponseWriter, r *http.Request) {
	id, ok := terminalIDFrom(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	client, ok := h.terminalClientOr502(w)
	if !ok {
		return
	}
	notice := ""
	resp, err := client.DeleteAutobuyWithResponse(r.Context(), id, h.terminalEditor(r))
	if err != nil || (resp.StatusCode() != http.StatusNoContent && resp.StatusCode() != http.StatusNotFound) {
		notice = "Could not delete that autobuy. Try again."
	}
	h.renderAutobuysPanel(w, r, client, func(vm *terminal.AutobuysVM) { vm.Notice = notice })
}
```

- [ ] **Step 7: Add the Alpine form component**

In `internal/server/assets/terminal.js`, inside `registerTerminal(Alpine)`, after the `terminalCompact` registration, add:
```js
  // Mirrors the autobuy form so the example chips can fill it and the
  // percent field can follow the cadence. The server validates on submit.
  Alpine.data('terminalAutobuyForm', (initial = {}) => ({
    label: initial.label ?? '',
    ticker: initial.ticker ?? '',
    amount: initial.amount ?? '',
    cadence: initial.cadence || 'monthly',
    percent: initial.percent ?? '',
    prefill(values) {
      this.label = values.label ?? ''
      this.amount = values.amount ?? ''
      this.cadence = values.cadence || 'monthly'
      this.percent = values.percent ?? ''
      this.$nextTick(() => this.$root.querySelector('[name="amount"]')?.focus())
    },
  }))
```

- [ ] **Step 8: Mount the routes and pin them**

In `MountTerminalRoutes`, add:
```go
	r.Post("/terminal/autobuys", h.TerminalAutobuyCreate)
	r.Patch("/terminal/autobuys/{id}", h.TerminalAutobuyUpdate)
	r.Post("/terminal/autobuys/{id}/active", h.TerminalAutobuyActive)
	r.Delete("/terminal/autobuys/{id}", h.TerminalAutobuyDelete)
```
Add these to `terminalRoutes`:
```go
	"POST /terminal/autobuys",
	"PATCH /terminal/autobuys/{id}",
	"POST /terminal/autobuys/{id}/active",
	"DELETE /terminal/autobuys/{id}",
```

- [ ] **Step 9: Generate and run the tests**

```bash
templ generate
bun run build
GOFLAGS=-mod=mod go test ./internal/handlers/ ./internal/server/ -run 'TerminalAutobuy|TerminalPageShowsAutobuys|TerminalRoutes|TerminalPage' -count=1 -v
```
Expected: PASS, including the Task 4 page tests, which still hold.

- [ ] **Step 10: Check controls and commit**

```bash
bash scripts/check-no-bare-controls.sh
git add internal/pages/terminal internal/handlers/terminal_autobuys.go internal/handlers/terminal_autobuys_test.go internal/handlers/terminal.go internal/server/assets/terminal.js internal/server/terminal_routes_test.go
git commit -m "feat(terminal): autobuys side panel with monthly equivalents and example chips"
```

---

### Task 8: AI suggestions (Pro): Fill with AI and Suggest scenario

**Files:**
- Create: `internal/pages/terminal/ai_vm.go`
- Create: `internal/pages/terminal/ai.templ`
- Create: `internal/handlers/terminal_ai.go`
- Modify: `internal/pages/terminal/row.templ` (replace `rowDetails`)
- Modify: `internal/handlers/terminal.go` (`MountTerminalRoutes`)
- Modify: `internal/server/terminal_routes_test.go`
- Test: `internal/handlers/terminal_ai_test.go`

**Interfaces:**
- Consumes: `isUpgradeRequired`, `normalizeTerminalTicker`, `terminalClient(terminalAIClientTimeout)`, `renderTerminalFragment`, `h.isPro(r)`, `format.*`, and Task 5's `PATCH /terminal/positions/{id}` (Accept).
- Produces:
  - Package `terminal`: `SuggestionVM`, `SuggestionLine`; constants `SuggestionReady`, `SuggestionUpgrade`, `SuggestionUnavailable`, `SuggestionUnusable`, `SuggestionInvalid`; templ `Suggestion(SuggestionVM)`; helper `aiAction(RowVM, kind string) templ.Attributes`.
  - Routes: `POST /terminal/positions/{id}/ai/facts` → `TerminalAIFacts`; `POST /terminal/positions/{id}/ai/scenario` → `TerminalAIScenario`. Form: `ticker`, `symbol`. Both always answer 200 with `Suggestion` into `#terminal-ai-{id}`.
  - `httpsSources([]string) []string`.

- [ ] **Step 1: Write the failing tests**

`internal/handlers/terminal_ai_test.go`:
```go
package handlers

import (
	"net/http"
	"net/url"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	factsKey    = "POST /v1/terminal-positions/ai/share-facts"
	scenarioKey = "POST /v1/terminal-positions/ai/scenario"
)

func aiForm() url.Values { return url.Values{"ticker": {"AMZN"}, "symbol": {"$"}} }

func TestTerminalAIFactsAsksNonProUsersToUpgradeWithoutCallingTheBackend(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodPost, "/terminal/positions/"+terminalAMZNID+"/ai/facts", aiForm())
	require.Equal(t, http.StatusOK, rec.Code)
	assert.Contains(t, rec.Body.String(), "AI lookups are a Pro feature.")
	assert.Contains(t, rec.Body.String(), `href="/settings/subscription"`)
	assert.False(t, backend.called(factsKey))
}

func TestTerminalAIFactsShowsTheSuggestionWithAnAcceptPatch(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := serveTerminal(t, svc, terminalTestOpts{pro: true, hx: true}, http.MethodPost, "/terminal/positions/"+terminalAMZNID+"/ai/facts", aiForm())

	require.Equal(t, http.StatusOK, rec.Code)
	assert.JSONEq(t, `{"ticker":"AMZN"}`, backend.body(factsKey))
	body := rec.Body.String()
	assert.Contains(t, body, "Suggested facts for AMZN")
	assert.Contains(t, body, "10.6B")
	assert.Contains(t, body, "$185.50")
	assert.Contains(t, body, "As of 2026-10-08")
	assert.Contains(t, body, `hx-patch="/terminal/positions/`+terminalAMZNID+`"`)
	assert.Contains(t, body, `&#34;sharesOutstanding&#34;:&#34;10600000000&#34;`)
	assert.Contains(t, body, `&#34;currentSharePrice&#34;:&#34;185.5&#34;`)
	assert.Contains(t, body, `&#34;details&#34;:&#34;open&#34;`)
}

// Review Focus 4.
func TestTerminalAIFactsShowsOnlyHTTPSSources(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, nil)
	body := serveTerminal(t, svc, terminalTestOpts{pro: true, hx: true}, http.MethodPost, "/terminal/positions/"+terminalAMZNID+"/ai/facts", aiForm()).Body.String()
	assert.Contains(t, body, `href="https://ir.aboutamazon.com/sec-filings"`)
	assert.NotContains(t, body, "javascript:")
	assert.NotContains(t, body, "insecure.example")
}

func TestTerminalAIFactsTreatsTheBackendUpgradeBodyAsUpgrade(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{factsKey: {http.StatusForbidden, terminalUpgradeJSON}})
	body := serveTerminal(t, svc, terminalTestOpts{pro: true, hx: true}, http.MethodPost, "/terminal/positions/"+terminalAMZNID+"/ai/facts", aiForm()).Body.String()
	assert.Contains(t, body, "AI lookups are a Pro feature.")
}

func TestTerminalAIFactsSaysUnavailableOn503(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{factsKey: {http.StatusServiceUnavailable, `{"error":true,"reason":"AI lookup unavailable"}`}})
	rec := serveTerminal(t, svc, terminalTestOpts{pro: true, hx: true}, http.MethodPost, "/terminal/positions/"+terminalAMZNID+"/ai/facts", aiForm())
	require.Equal(t, http.StatusOK, rec.Code)
	assert.Contains(t, rec.Body.String(), "AI lookup unavailable")
	assert.NotContains(t, rec.Body.String(), "hx-patch")
}

func TestTerminalAIFactsSaysUnusableOn422(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{factsKey: {http.StatusUnprocessableEntity, `{"error":true,"reason":"no usable answer"}`}})
	body := serveTerminal(t, svc, terminalTestOpts{pro: true, hx: true}, http.MethodPost, "/terminal/positions/"+terminalAMZNID+"/ai/facts", aiForm()).Body.String()
	assert.Contains(t, body, "did not return usable numbers for AMZN")
}

func TestTerminalAIFactsNeedsATicker(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	body := serveTerminal(t, svc, terminalTestOpts{pro: true, hx: true}, http.MethodPost, "/terminal/positions/"+terminalAMZNID+"/ai/facts", url.Values{"ticker": {""}}).Body.String()
	assert.Contains(t, body, "Set a ticker on this row first.")
	assert.False(t, backend.called(factsKey))
}

func TestTerminalAIScenarioShowsCountCapRationaleAndAccept(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	body := serveTerminal(t, svc, terminalTestOpts{pro: true, hx: true}, http.MethodPost, "/terminal/positions/"+terminalAMZNID+"/ai/scenario", aiForm()).Body.String()

	assert.JSONEq(t, `{"ticker":"AMZN"}`, backend.body(scenarioKey))
	assert.Contains(t, body, "Suggested scenario for AMZN over 10 years")
	assert.Contains(t, body, "11B")
	assert.Contains(t, body, "$10T")
	assert.Contains(t, body, "Buybacks offset dilution; cloud margins hold.")
	assert.Contains(t, body, `href="https://example.com/amzn-10k"`)
	assert.Contains(t, body, `&#34;terminalShareCount&#34;:&#34;11000000000&#34;`)
	assert.Contains(t, body, `&#34;terminalMarketCap&#34;:&#34;10000000000000&#34;`)
}

// Accept reuses the row PATCH with every suggested field at once.
func TestTerminalAcceptingFactsPatchesBothFieldsAndKeepsDetailsOpen(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := patchTerminalRow(t, svc, url.Values{"sharesOutstanding": {"10600000000"}, "currentSharePrice": {"185.5"}, "details": {"open"}})
	assert.JSONEq(t, `{"sharesOutstanding":10600000000,"currentSharePrice":185.5}`, backend.body(amznPatchKey))
	assert.Contains(t, rec.Body.String(), `x-data="{ open: true }"`)
}

func TestTerminalRowDetailsOfferAIButtons(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, nil)
	body := serveTerminal(t, svc, terminalTestOpts{}, http.MethodGet, "/terminal", nil).Body.String()
	assert.Contains(t, body, "Fill with AI")
	assert.Contains(t, body, "Suggest scenario")
	assert.Contains(t, body, `hx-post="/terminal/positions/`+terminalAMZNID+`/ai/facts"`)
	assert.Contains(t, body, `id="terminal-ai-`+terminalAMZNID+`"`)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `GOFLAGS=-mod=mod go test ./internal/handlers/ -run 'TerminalAI|TerminalAccepting|TerminalRowDetailsOfferAI' -count=1`
Expected: FAIL. The routes answer 405, and the page lacks "Fill with AI".

- [ ] **Step 3: Write the suggestion view model**

`internal/pages/terminal/ai_vm.go`:
```go
package terminal

import (
	"encoding/json"

	"github.com/a-h/templ"
)

// Suggestion states.
const (
	SuggestionReady       = "ready"
	SuggestionUpgrade     = "upgrade"
	SuggestionUnavailable = "unavailable"
	SuggestionUnusable    = "unusable"
	SuggestionInvalid     = "invalid"
)

// SuggestionLine is one suggested value, formatted.
type SuggestionLine struct {
	Label string
	Value string
}

// SuggestionVM is an AI answer for one row. AcceptVals is the JSON hx-vals of
// the PATCH that applies it; nothing is written until the user clicks Accept.
type SuggestionVM struct {
	RowID      string
	Kind       string
	Ticker     string
	State      string
	Heading    string
	Lines      []SuggestionLine
	Rationale  string
	AsOf       string
	Sources    []string
	AcceptVals string
	Message    string
}

// aiAction asks for a suggestion for row; the answer lands in the row's slot.
func aiAction(row RowVM, kind string) templ.Attributes {
	vals, err := json.Marshal(map[string]string{"ticker": row.Ticker, "symbol": row.CurrencySymbol})
	if err != nil {
		vals = []byte("{}")
	}
	return templ.Attributes{
		"hx-post":   "/terminal/positions/" + row.ID + "/ai/" + kind,
		"hx-vals":   string(vals),
		"hx-target": "#terminal-ai-" + row.ID,
		"hx-swap":   "innerHTML",
	}
}
```

- [ ] **Step 4: Write the suggestion template**

`internal/pages/terminal/ai.templ`:
```templ
package terminal

import "github.com/FinancePlanner/StockPlanWeb/internal/pages/components"

// Suggestion renders an AI answer in a row's details. It never writes: Accept
// sends the row PATCH with the suggested values, the same as typing them in.
templ Suggestion(vm SuggestionVM) {
	<div data-terminal-suggestion class="space-y-2 rounded-xl border border-border p-3">
		switch vm.State {
			case SuggestionReady:
				<p class="text-footnote font-semibold">{ vm.Heading }</p>
				<dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-subhead">
					for _, line := range vm.Lines {
						<dt class="text-muted-foreground">{ line.Label }</dt>
						<dd class="tabular-nums">{ line.Value }</dd>
					}
				</dl>
				if vm.Rationale != "" {
					<p class="text-footnote">{ vm.Rationale }</p>
				}
				if vm.AsOf != "" {
					<p class="text-footnote text-muted-foreground">As of { vm.AsOf }</p>
				}
				if len(vm.Sources) > 0 {
					<ul class="space-y-1 text-footnote">
						for _, source := range vm.Sources {
							<li><a href={ templ.SafeURL(source) } target="_blank" rel="noopener noreferrer" class="link-tint break-all">{ source }</a></li>
						}
					</ul>
				}
				<p class="text-footnote text-muted-foreground">An AI suggestion. Check it against the sources before you accept it.</p>
				<div class="flex gap-2">
					@components.PrimaryButton(components.ButtonProps{Attributes: templ.Attributes{
						"hx-patch":  "/terminal/positions/" + vm.RowID,
						"hx-vals":   vm.AcceptVals,
						"hx-target": "#terminal-row-" + vm.RowID,
						"hx-swap":   "outerHTML",
					}}) {
						Accept
					}
					@dismissSuggestion()
				</div>
			case SuggestionUpgrade:
				<p class="text-subhead font-semibold">AI lookups are a Pro feature.</p>
				<p class="text-footnote text-muted-foreground">The table and autobuys stay free.</p>
				@components.PrimaryButton(components.ButtonProps{Href: "/settings/subscription"}) {
					See plans
				}
			default:
				<p role="alert" class="text-footnote">{ vm.Message }</p>
				@dismissSuggestion()
		}
	</div>
}

templ dismissSuggestion() {
	@components.GhostButton(components.ButtonProps{Attributes: templ.Attributes{"@click": "$el.closest('[data-terminal-suggestion]').remove()"}}) {
		Dismiss
	}
}
```

- [ ] **Step 5: Add the AI buttons to the row details**

In `internal/pages/terminal/row.templ`, replace the whole `templ rowDetails(row RowVM) { ... }` with:
```templ
templ rowDetails(row RowVM) {
	<div class="grid gap-4 py-2 md:grid-cols-[16rem_minmax(0,1fr)]">
		<div class="space-y-2">
			@components.Field(components.FieldProps{
				ID:          cellID(row.ID, "currentSharePrice"),
				Name:        "currentSharePrice",
				Label:       "Current share price (optional)",
				Type:        input.TypeText,
				Value:       row.CurrentSharePrice,
				Placeholder: "185.50",
				Class:       "tabular-nums",
				Attributes:  detailAttrs(row.ID, "Current share price"),
			})
			if row.CapitalAtTodayPrice != "" {
				<p class="text-footnote">Capital at today's price: <span class="font-semibold tabular-nums">{ row.CapitalAtTodayPrice }</span></p>
			} else {
				<p class="text-footnote text-muted-foreground">Add a current price to see what these shares cost today.</p>
			}
		</div>
		<div class="space-y-2">
			<div class="flex flex-wrap gap-2">
				@components.SecondaryButton(components.ButtonProps{Attributes: aiAction(row, "facts")}) {
					Fill with AI
					if !row.IsPro {
						<span class="ml-1 rounded bg-muted px-1 text-[0.65rem] font-semibold uppercase">Pro</span>
					}
				}
				@components.SecondaryButton(components.ButtonProps{Attributes: aiAction(row, "scenario")}) {
					Suggest scenario
					if !row.IsPro {
						<span class="ml-1 rounded bg-muted px-1 text-[0.65rem] font-semibold uppercase">Pro</span>
					}
				}
			</div>
			<div id={ "terminal-ai-" + row.ID } aria-live="polite"></div>
		</div>
	</div>
}
```

- [ ] **Step 6: Write the handlers**

`internal/handlers/terminal_ai.go`:
```go
package handlers

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"net/url"
	"strings"
	"unicode/utf8"

	"github.com/FinancePlanner/StockPlanWeb/internal/api/terminalapi"
	"github.com/FinancePlanner/StockPlanWeb/internal/format"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/terminal"
)

const (
	terminalAIFacts    = "facts"
	terminalAIScenario = "scenario"
	maxSymbolRunes     = 5
)

// TerminalAIFacts suggests shares outstanding and the current price (Pro).
func (h *AppHandler) TerminalAIFacts(w http.ResponseWriter, r *http.Request) {
	h.terminalAISuggest(w, r, terminalAIFacts)
}

// TerminalAIScenario suggests a terminal share count and market cap (Pro).
func (h *AppHandler) TerminalAIScenario(w http.ResponseWriter, r *http.Request) {
	h.terminalAISuggest(w, r, terminalAIScenario)
}

// terminalAISuggest answers 200 in every case: htmx 4 discards 4xx/5xx bodies
// (see HtmxConfigMeta), and every outcome here is a message for the reader.
// Non-Pro readers get the upgrade prompt without spending a backend call; a
// stale Pro cache is still caught by the backend's own 403.
func (h *AppHandler) terminalAISuggest(w http.ResponseWriter, r *http.Request, kind string) {
	id, ok := terminalIDFrom(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Could not read that request.", http.StatusBadRequest)
		return
	}
	vm := terminal.SuggestionVM{RowID: id.String(), Kind: kind}
	ticker, valid := normalizeTerminalTicker(r.PostForm.Get("ticker"))
	vm.Ticker = ticker
	symbol := r.PostForm.Get("symbol")
	if utf8.RuneCountInString(symbol) > maxSymbolRunes {
		symbol = ""
	}
	switch {
	case !valid:
		vm.State = terminal.SuggestionInvalid
		vm.Message = "Set a ticker on this row first."
	case !h.isPro(r):
		vm.State = terminal.SuggestionUpgrade
	case kind == terminalAIFacts:
		h.fillShareFactsSuggestion(r, &vm, symbol)
	default:
		h.fillScenarioSuggestion(r, &vm, symbol)
	}
	h.renderTerminalFragment(w, r, terminal.Suggestion(vm))
}

func (h *AppHandler) fillShareFactsSuggestion(r *http.Request, vm *terminal.SuggestionVM, symbol string) {
	client, err := h.terminalClient(terminalAIClientTimeout)
	if err != nil {
		setSuggestionUnavailable(vm)
		return
	}
	resp, err := client.SuggestTerminalShareFactsWithResponse(r.Context(), terminalapi.ShareFactsRequest{Ticker: vm.Ticker}, h.terminalEditor(r))
	switch {
	case err != nil:
		slog.Warn("terminal share facts", "error", err)
		setSuggestionUnavailable(vm)
	case resp.JSON200 != nil:
		shareFactsSuggestionVM(vm, resp.JSON200, symbol)
	default:
		suggestionFailure(vm, resp.StatusCode(), resp.Body)
	}
}

func (h *AppHandler) fillScenarioSuggestion(r *http.Request, vm *terminal.SuggestionVM, symbol string) {
	client, err := h.terminalClient(terminalAIClientTimeout)
	if err != nil {
		setSuggestionUnavailable(vm)
		return
	}
	resp, err := client.SuggestTerminalScenarioWithResponse(r.Context(), terminalapi.TerminalScenarioSuggestionRequest{Ticker: vm.Ticker}, h.terminalEditor(r))
	switch {
	case err != nil:
		slog.Warn("terminal scenario suggestion", "error", err)
		setSuggestionUnavailable(vm)
	case resp.JSON200 != nil:
		scenarioSuggestionVM(vm, resp.JSON200, symbol)
	default:
		suggestionFailure(vm, resp.StatusCode(), resp.Body)
	}
}

func suggestionFailure(vm *terminal.SuggestionVM, status int, body []byte) {
	switch {
	case isUpgradeRequired(status, body):
		vm.State = terminal.SuggestionUpgrade
	case status == http.StatusUnprocessableEntity:
		setSuggestionUnusable(vm)
	default: // 503 "AI lookup unavailable", and anything unexpected
		setSuggestionUnavailable(vm)
	}
}

func setSuggestionUnavailable(vm *terminal.SuggestionVM) {
	vm.State = terminal.SuggestionUnavailable
	vm.Message = "AI lookup unavailable. Enter the numbers yourself, or try again later."
}

func setSuggestionUnusable(vm *terminal.SuggestionVM) {
	vm.State = terminal.SuggestionUnusable
	vm.Message = "The AI lookup did not return usable numbers for " + vm.Ticker + ". Enter them yourself."
}

func shareFactsSuggestionVM(vm *terminal.SuggestionVM, s *terminalapi.ShareFactsSuggestion, symbol string) {
	if s.Currency != nil && strings.TrimSpace(*s.Currency) != "" {
		symbol = format.CurrencySymbol(*s.Currency)
	}
	accept := map[string]string{"details": "open"}
	if s.SharesOutstanding != nil && positiveFinite(*s.SharesOutstanding) {
		vm.Lines = append(vm.Lines, terminal.SuggestionLine{
			Label: "Shares outstanding",
			Value: format.Compact(*s.SharesOutstanding) + " (" + format.Number(*s.SharesOutstanding, 0) + ")",
		})
		accept["sharesOutstanding"] = format.InputNumber(*s.SharesOutstanding)
	}
	if s.CurrentSharePrice != nil && positiveFinite(*s.CurrentSharePrice) {
		vm.Lines = append(vm.Lines, terminal.SuggestionLine{Label: "Current share price", Value: symbol + format.Currency(*s.CurrentSharePrice, "")})
		accept["currentSharePrice"] = format.InputNumber(*s.CurrentSharePrice)
	}
	if len(vm.Lines) == 0 {
		setSuggestionUnusable(vm)
		return
	}
	vm.State = terminal.SuggestionReady
	vm.Heading = "Suggested facts for " + vm.Ticker
	if s.AsOf != nil {
		vm.AsOf = strings.TrimSpace(*s.AsOf)
	}
	vm.Sources = httpsSources(s.Sources)
	vm.AcceptVals = jsonVals(accept)
}

func scenarioSuggestionVM(vm *terminal.SuggestionVM, s *terminalapi.TerminalScenarioSuggestion, symbol string) {
	if !positiveFinite(s.TerminalShareCount) || !positiveFinite(s.TerminalMarketCap) {
		setSuggestionUnusable(vm)
		return
	}
	vm.State = terminal.SuggestionReady
	vm.Heading = fmt.Sprintf("Suggested scenario for %s over %d years", vm.Ticker, s.HorizonYears)
	vm.Lines = []terminal.SuggestionLine{
		{Label: "Terminal share count", Value: format.Compact(s.TerminalShareCount)},
		{Label: "Terminal market cap", Value: symbol + format.Compact(s.TerminalMarketCap)},
	}
	vm.Rationale = strings.TrimSpace(s.Rationale)
	vm.Sources = httpsSources(s.Sources)
	vm.AcceptVals = jsonVals(map[string]string{
		"terminalShareCount": format.InputNumber(s.TerminalShareCount),
		"terminalMarketCap":  format.InputNumber(s.TerminalMarketCap),
		"details":            "open",
	})
}

// httpsSources keeps only absolute https links. An AI answer is untrusted
// text; anything else (javascript:, http:, relative paths) is dropped rather
// than rendered as a link.
func httpsSources(in []string) []string {
	out := make([]string, 0, len(in))
	for _, raw := range in {
		u, err := url.Parse(strings.TrimSpace(raw))
		if err != nil || u.Scheme != "https" || u.Host == "" {
			continue
		}
		out = append(out, u.String())
	}
	return out
}

func positiveFinite(v float64) bool { return v > 0 && !math.IsInf(v, 0) && !math.IsNaN(v) }

func jsonVals(values map[string]string) string {
	raw, err := json.Marshal(values)
	if err != nil {
		return "{}"
	}
	return string(raw)
}
```

- [ ] **Step 7: Mount the routes and pin them**

In `MountTerminalRoutes`, add:
```go
	r.Post("/terminal/positions/{id}/ai/facts", h.TerminalAIFacts)
	r.Post("/terminal/positions/{id}/ai/scenario", h.TerminalAIScenario)
```
Add these to `terminalRoutes`:
```go
	"POST /terminal/positions/{id}/ai/facts",
	"POST /terminal/positions/{id}/ai/scenario",
```

- [ ] **Step 8: Generate and run the tests**

```bash
templ generate
GOFLAGS=-mod=mod go test ./internal/handlers/ ./internal/server/ -run 'TerminalAI|TerminalAccepting|TerminalRowDetailsOfferAI|TerminalRoutes' -count=1 -v
```
Expected: PASS.

- [ ] **Step 9: Check controls and commit**

```bash
bash scripts/check-no-bare-controls.sh
git add internal/pages/terminal internal/handlers/terminal_ai.go internal/handlers/terminal_ai_test.go internal/handlers/terminal.go internal/server/terminal_routes_test.go
git commit -m "feat(terminal): Pro AI suggestions for share facts and scenarios, applied only on Accept"
```

---

### Task 9: Dashboard summary card

**Files:**
- Create: `internal/pages/dashboard/terminal_summary.go`
- Create: `internal/pages/dashboard/terminal_summary.templ`
- Create: `internal/handlers/dashboard_terminal.go`
- Modify: `internal/pages/dashboard/command_center.templ` (the `cc-rail-now` section, after `@MCPStatusShell()`)
- Modify: `internal/handlers/terminal.go` (`MountTerminalRoutes`)
- Modify: `internal/server/terminal_routes_test.go`
- Test: `internal/handlers/dashboard_terminal_test.go`, `internal/pages/dashboard/terminal_summary_test.go`

**Interfaces:**
- Consumes: `loadTerminalSummary`, `terminalRowVM`, `terminalCopy`, `renderTerminalFragment`, `format.*`.
- Produces:
  - Package `dashboard`: `TerminalSummaryVM`, `TerminalSummaryRowVM`, templ `TerminalSummaryShell()` and `TerminalSummaryCard(TerminalSummaryVM)` (root `id="cc-terminal-summary"`).
  - Route `GET /dashboard/terminal` → `DashboardTerminalSummary`.

- [ ] **Step 1: Write the failing tests**

`internal/handlers/dashboard_terminal_test.go`:
```go
package handlers

import (
	"net/http"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestDashboardTerminalSummaryShowsTotalsTopRowsAndAutobuys(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, nil)
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodGet, "/dashboard/terminal", nil)

	require.Equal(t, http.StatusOK, rec.Code)
	body := rec.Body.String()
	assert.Contains(t, body, `id="cc-terminal-summary"`)
	assert.Contains(t, body, "Terminal sizing")
	assert.Contains(t, body, "$1.5M")
	assert.Contains(t, body, "AMZN")
	assert.Contains(t, body, "1,100 shares at $909.09")
	assert.Contains(t, body, "68.18%")
	assert.Contains(t, body, "VG")
	assert.Contains(t, body, "$216.67")
	assert.Contains(t, body, `href="/terminal"`)
	assert.Contains(t, body, "Not financial advice.")
}

func TestDashboardTerminalSummaryInvitesWhenThereAreNoRows(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{"GET /v1/terminal-positions/summary": {http.StatusOK, terminalEmptySummaryJSON}})
	body := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodGet, "/dashboard/terminal", nil).Body.String()
	assert.Contains(t, body, "Plan a position")
	assert.Contains(t, body, `href="/terminal"`)
	assert.NotContains(t, body, "AMZN")
}

// Review Focus 5.
func TestDashboardTerminalSummaryHidesOnBackendFailure(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{"GET /v1/terminal-positions/summary": {http.StatusBadGateway, ""}})
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodGet, "/dashboard/terminal", nil)
	require.Equal(t, http.StatusOK, rec.Code)
	assert.Contains(t, rec.Body.String(), `id="cc-terminal-summary" hidden`)
	assert.NotContains(t, rec.Body.String(), "unavailable")
}
```

`internal/pages/dashboard/terminal_summary_test.go`:
```go
package dashboard

import (
	"bytes"
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTerminalSummaryShellLazyLoadsTheCard(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	require.NoError(t, TerminalSummaryShell().Render(context.Background(), &buf))
	assert.Contains(t, buf.String(), `hx-get="/dashboard/terminal"`)
	assert.Contains(t, buf.String(), `hx-trigger="load"`)
}

func TestCommandCenterCarriesTheTerminalSummaryShell(t *testing.T) {
	t.Parallel()
	rendered := renderCommandCenter(t, populatedCommandCenter())
	assert.Contains(t, rendered, `hx-get="/dashboard/terminal"`)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `GOFLAGS=-mod=mod go test ./internal/handlers/ ./internal/pages/dashboard/ -run 'DashboardTerminal|TerminalSummary|CommandCenterCarriesTheTerminal' -count=1`
Expected: FAIL to compile with `undefined: TerminalSummaryShell`.

- [ ] **Step 3: Write the view model and templates**

`internal/pages/dashboard/terminal_summary.go`:
```go
package dashboard

// TerminalSummaryVM is the dashboard's terminal sizing card. Every string is
// formatted by the handler from backend values.
type TerminalSummaryVM struct {
	LoadError           bool
	Empty               bool
	TotalValueWanted    string
	MonthlyAutobuyTotal string
	Top                 []TerminalSummaryRowVM
	Disclaimer          string
}

// TerminalSummaryRowVM is one of the top three rows.
type TerminalSummaryRowVM struct {
	Ticker             string
	TerminalSharePrice string
	SharesNeeded       string
	ProgressLabel      string
	ProgressPct        float64
}
```

`internal/pages/dashboard/terminal_summary.templ`:
```templ
package dashboard

import (
	"fmt"

	"github.com/FinancePlanner/StockPlanWeb/internal/components/vigil"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/components"
)

// TerminalSummaryShell defers the terminal summary fetch off the critical
// path, like TaxPanelShell and MCPStatusShell on this page.
templ TerminalSummaryShell() {
	<div id="cc-terminal-summary" hx-get="/dashboard/terminal" hx-trigger="load" hx-swap="outerHTML">
		@vigil.Panel("cc-terminal-summary-inner", "") {
			<div class="cc-panel-head">
				<div class="cc-panel-head-copy">
					<h2 class="cc-panel-title">Terminal sizing</h2>
				</div>
			</div>
			@components.SkeletonBlock("h-20")
		}
	</div>
}

// TerminalSummaryCard is best effort: a failed load hides the card instead of
// putting an error on the dashboard.
templ TerminalSummaryCard(vm TerminalSummaryVM) {
	if vm.LoadError {
		<div id="cc-terminal-summary" hidden></div>
	} else {
		<div id="cc-terminal-summary">
			@vigil.Panel("cc-terminal-summary-inner", "cc-terminal-title") {
				@vigil.PanelHeader("cc-terminal-title", "Terminal sizing", "", terminalOpenLink())
				if vm.Empty {
					<p class="text-subhead text-muted-foreground">Pick a future market cap and share count, and see how many shares your target takes.</p>
					<div class="mt-3">
						@components.SecondaryButton(components.ButtonProps{Href: "/terminal"}) {
							Plan a position
						}
					</div>
				} else {
					<div class="grid grid-cols-2 gap-3">
						<div>
							<p class="command-metric-label">Value wanted</p>
							<p class="text-title3 font-semibold tabular-nums">{ vm.TotalValueWanted }</p>
						</div>
						<div>
							<p class="command-metric-label">Autobuys a month</p>
							<p class="text-title3 font-semibold tabular-nums">{ vm.MonthlyAutobuyTotal }</p>
						</div>
					</div>
					<ul class="mt-3 space-y-2">
						for _, row := range vm.Top {
							<li class="space-y-1">
								<div class="flex justify-between gap-2 text-subhead">
									<span class="font-semibold">{ row.Ticker }</span>
									<span class="tabular-nums text-muted-foreground">{ row.SharesNeeded } shares at { row.TerminalSharePrice }</span>
								</div>
								<div class="flex items-center gap-2">
									<div class="h-1 flex-1 overflow-hidden rounded-full bg-muted">
										<div class="h-full rounded-full bg-primary" style={ fmt.Sprintf("width:%.1f%%", row.ProgressPct) }></div>
									</div>
									<span class="text-footnote tabular-nums">{ row.ProgressLabel }</span>
								</div>
							</li>
						}
					</ul>
				}
				<p class="mt-3 text-footnote text-muted-foreground">{ vm.Disclaimer }</p>
			}
		</div>
	}
}

templ terminalOpenLink() {
	<a href="/terminal">Open</a>
}
```

In `internal/pages/dashboard/command_center.templ`, in the `<section class="cc-rail cc-rail-now cc-modules" ...>` block, add a line right after `@MCPStatusShell()`:
```templ
			@TerminalSummaryShell()
```

- [ ] **Step 4: Write the handler**

`internal/handlers/dashboard_terminal.go`:
```go
package handlers

import (
	"net/http"

	"github.com/FinancePlanner/StockPlanWeb/internal/format"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/dashboard"
)

// terminalTopRows is how many rows the dashboard card lists (spec: top 3).
const terminalTopRows = 3

// DashboardTerminalSummary is the lazy terminal sizing card on /dashboard.
func (h *AppHandler) DashboardTerminalSummary(w http.ResponseWriter, r *http.Request) {
	h.renderTerminalFragment(w, r, dashboard.TerminalSummaryCard(h.loadTerminalSummaryCard(r)))
}

func (h *AppHandler) loadTerminalSummaryCard(r *http.Request) dashboard.TerminalSummaryVM {
	vm := dashboard.TerminalSummaryVM{Disclaimer: terminalCopy(r.Context()).Disclaimer}
	client, err := h.terminalClient(terminalClientTimeout)
	if err != nil {
		vm.LoadError = true
		return vm
	}
	summary := h.loadTerminalSummary(r, client)
	if summary == nil {
		vm.LoadError = true
		return vm
	}
	if summary.PositionCount == 0 {
		vm.Empty = true
		return vm
	}
	vm.TotalValueWanted = format.CompactCurrency(summary.TotalValueWanted, summary.Currency)
	vm.MonthlyAutobuyTotal = format.Currency(summary.MonthlyAutobuyTotal, summary.Currency)
	for i := range summary.TopPositions {
		if i == terminalTopRows {
			break
		}
		row := terminalRowVM(&summary.TopPositions[i], summary.Currency, false)
		vm.Top = append(vm.Top, dashboard.TerminalSummaryRowVM{
			Ticker:             row.Ticker,
			TerminalSharePrice: row.TerminalSharePrice,
			SharesNeeded:       row.SharesNeeded,
			ProgressLabel:      row.ProgressLabel,
			ProgressPct:        row.ProgressPct,
		})
	}
	return vm
}
```

- [ ] **Step 5: Mount the route and pin it**

In `MountTerminalRoutes`, add `r.Get("/dashboard/terminal", h.DashboardTerminalSummary)`. Add `"GET /dashboard/terminal",` to `terminalRoutes`.

- [ ] **Step 6: Generate and run the tests**

```bash
templ generate
GOFLAGS=-mod=mod go test ./internal/handlers/ ./internal/pages/dashboard/ ./internal/server/ -run 'DashboardTerminal|TerminalSummary|CommandCenter|TerminalRoutes' -count=1 -v
```
Expected: PASS, including the existing command center tests.

- [ ] **Step 7: Commit**

```bash
git add internal/pages/dashboard internal/handlers/dashboard_terminal.go internal/handlers/dashboard_terminal_test.go internal/handlers/terminal.go internal/server/terminal_routes_test.go
git commit -m "feat(terminal): dashboard summary card with top rows and monthly autobuys"
```

---

### Task 10: Stock detail card

**Files:**
- Create: `internal/pages/stock/terminal_card.go`
- Create: `internal/pages/stock/terminal_card.templ`
- Create: `internal/handlers/stock_terminal.go`
- Modify: `internal/pages/stock/overview.templ` (`OverviewTab`, right after `@PressureShell(vm.Symbol)`)
- Modify: `internal/handlers/terminal.go` (`MountTerminalRoutes`)
- Modify: `internal/server/terminal_routes_test.go`
- Test: `internal/handlers/stock_terminal_test.go`, `internal/pages/stock/terminal_card_test.go`

**Interfaces:**
- Consumes: `normalizeTerminalTicker`, `terminalRowVM`, `terminalCopy`, `renderTerminalFragment`, `terminalapi.ListTerminalPositionsParams`.
- Produces:
  - Package `stock`: `TerminalCardVM`, templ `TerminalShell(symbol string)` (root `id="stock-terminal"`) and `TerminalCard(TerminalCardVM)`.
  - Route `GET /portfolio/{symbol}/terminal` → `StockTerminal`.
  - The "Add terminal scenario" link targets `/terminal?ticker=X`. Task 4's `Terminal` already opens the create form for it.

- [ ] **Step 1: Write the failing tests**

`internal/handlers/stock_terminal_test.go`:
```go
package handlers

import (
	"net/http"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestStockTerminalShowsTheTickersFirstScenario(t *testing.T) {
	t.Parallel()
	svc, backend := newTerminalBackend(t, nil)
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodGet, "/portfolio/amzn/terminal", nil)

	require.Equal(t, http.StatusOK, rec.Code)
	assert.Equal(t, "ticker=AMZN", backend.query("GET /v1/terminal-positions"))
	body := rec.Body.String()
	assert.Contains(t, body, "Terminal scenario")
	assert.Contains(t, body, "$909.09")
	assert.Contains(t, body, "1,100")
	assert.Contains(t, body, "68.18%")
	assert.Contains(t, body, `href="/terminal"`)
	assert.Contains(t, body, "Not financial advice.")
}

func TestStockTerminalOffersToAddAScenario(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{"GET /v1/terminal-positions": {http.StatusOK, terminalEmptyListJSON}})
	body := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodGet, "/portfolio/AMZN/terminal", nil).Body.String()
	assert.Contains(t, body, "Add terminal scenario")
	assert.Contains(t, body, `href="/terminal?ticker=AMZN"`)
}

func TestStockTerminalExplainsAnInvalidScenario(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{
		"GET /v1/terminal-positions": {http.StatusOK, `{"currency":"USD","positions":[` + sofiPositionJSON + `]}`},
	})
	body := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodGet, "/portfolio/SOFI/terminal", nil).Body.String()
	assert.Contains(t, body, "Terminal share count must be above zero.")
}

// Review Focus 5.
func TestStockTerminalHidesOnBackendFailure(t *testing.T) {
	t.Parallel()
	svc, _ := newTerminalBackend(t, map[string]terminalReply{"GET /v1/terminal-positions": {http.StatusBadGateway, ""}})
	rec := serveTerminal(t, svc, terminalTestOpts{hx: true}, http.MethodGet, "/portfolio/AMZN/terminal", nil)
	require.Equal(t, http.StatusOK, rec.Code)
	assert.NotContains(t, rec.Body.String(), "Terminal scenario")
}
```

`internal/pages/stock/terminal_card_test.go`:
```go
package stock

import (
	"bytes"
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestOverviewTabLazyLoadsTheTerminalCard(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	require.NoError(t, OverviewTab(DetailViewModel{Symbol: "AAPL", SymbolInitial: "A"}).Render(context.Background(), &buf))
	assert.Contains(t, buf.String(), `id="stock-terminal"`)
	assert.Contains(t, buf.String(), `hx-get="/portfolio/AAPL/terminal"`)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `GOFLAGS=-mod=mod go test ./internal/handlers/ ./internal/pages/stock/ -run 'StockTerminal|OverviewTabLazyLoadsTheTerminal' -count=1`
Expected: FAIL. The route is missing, and there is no `stock-terminal` in the overview.

- [ ] **Step 3: Write the view model and templates**

`internal/pages/stock/terminal_card.go`:
```go
package stock

// TerminalCardVM is the stock overview's terminal scenario card: the first
// scenario for this ticker by sort order, or an invitation to add one.
type TerminalCardVM struct {
	Symbol             string
	Unavailable        bool
	HasScenario        bool
	TerminalSharePrice string
	SharesNeeded       string
	ProgressLabel      string
	ProgressPct        float64
	ScenarioError      string
	AddHref            string
	Disclaimer         string
}
```

`internal/pages/stock/terminal_card.templ`:
```templ
package stock

import (
	"fmt"

	"github.com/FinancePlanner/StockPlanWeb/internal/components/vigil"
)

// TerminalShell lazy-loads the terminal scenario card so the stock page never
// waits on it. It renders nothing until the card arrives.
templ TerminalShell(symbol string) {
	<div
		id="stock-terminal"
		hx-get={ templ.SafeURL("/portfolio/" + symbol + "/terminal") }
		hx-trigger="load"
		hx-swap="innerHTML"
	></div>
}

// TerminalCard is best effort: an unavailable backend renders nothing.
templ TerminalCard(vm TerminalCardVM) {
	if !vm.Unavailable {
		@vigil.Panel("p-5 md:p-6", "stock-terminal-title") {
			<h2 id="stock-terminal-title" class="text-lg font-semibold">Terminal scenario</h2>
			if vm.HasScenario {
				if vm.ScenarioError != "" {
					<p class="mt-3 text-footnote text-destructive">{ vm.ScenarioError }</p>
				} else {
					<dl class="mt-4 grid grid-cols-2 gap-3">
						<div>
							<dt class="command-metric-label">Terminal price</dt>
							<dd class="text-title3 font-semibold tabular-nums">{ vm.TerminalSharePrice }</dd>
						</div>
						<div>
							<dt class="command-metric-label">Shares needed</dt>
							<dd class="text-title3 font-semibold tabular-nums">{ vm.SharesNeeded }</dd>
						</div>
					</dl>
					<div class="mt-3 flex items-center gap-2">
						<div class="h-1 flex-1 overflow-hidden rounded-full bg-muted">
							<div class="h-full rounded-full bg-primary" style={ fmt.Sprintf("width:%.1f%%", vm.ProgressPct) }></div>
						</div>
						<span class="text-footnote tabular-nums">{ vm.ProgressLabel }</span>
					</div>
				}
				<a href="/terminal" class="link-tint mt-3 inline-block text-subhead font-semibold">Open terminal sizing</a>
			} else {
				<p class="mt-3 text-subhead text-muted-foreground">No terminal scenario for { vm.Symbol } yet.</p>
				<a href={ templ.SafeURL(vm.AddHref) } class="link-tint mt-3 inline-block text-subhead font-semibold">Add terminal scenario</a>
			}
			<p class="mt-3 text-footnote text-muted-foreground">{ vm.Disclaimer }</p>
		}
	}
}
```

In `internal/pages/stock/overview.templ`, inside `@vigil.CommandSplitAside() {`, add a line right after `@PressureShell(vm.Symbol)`:
```templ
				@TerminalShell(vm.Symbol)
```

- [ ] **Step 4: Write the handler**

`internal/handlers/stock_terminal.go`:
```go
package handlers

import (
	"net/http"
	"net/url"

	"github.com/FinancePlanner/StockPlanWeb/internal/api/terminalapi"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/stock"
	"github.com/go-chi/chi/v5"
)

// StockTerminal is the lazy terminal scenario card on the stock overview.
func (h *AppHandler) StockTerminal(w http.ResponseWriter, r *http.Request) {
	h.renderTerminalFragment(w, r, stock.TerminalCard(h.loadStockTerminalCard(r, chi.URLParam(r, "symbol"))))
}

// loadStockTerminalCard shows the first scenario for the ticker by sort order
// (the backend filters case-insensitively and sorts).
func (h *AppHandler) loadStockTerminalCard(r *http.Request, rawSymbol string) stock.TerminalCardVM {
	symbol, ok := normalizeTerminalTicker(rawSymbol)
	vm := stock.TerminalCardVM{
		Symbol:     symbol,
		AddHref:    "/terminal?ticker=" + url.QueryEscape(symbol),
		Disclaimer: terminalCopy(r.Context()).Disclaimer,
	}
	if !ok {
		vm.Unavailable = true
		return vm
	}
	client, err := h.terminalClient(terminalClientTimeout)
	if err != nil {
		vm.Unavailable = true
		return vm
	}
	resp, err := client.ListTerminalPositionsWithResponse(r.Context(), &terminalapi.ListTerminalPositionsParams{Ticker: &symbol}, h.terminalEditor(r))
	if err != nil || resp.JSON200 == nil {
		vm.Unavailable = true
		return vm
	}
	if len(resp.JSON200.Positions) == 0 {
		return vm
	}
	row := terminalRowVM(&resp.JSON200.Positions[0], resp.JSON200.Currency, false)
	vm.HasScenario = true
	vm.TerminalSharePrice = row.TerminalSharePrice
	vm.SharesNeeded = row.SharesNeeded
	vm.ProgressLabel = row.ProgressLabel
	vm.ProgressPct = row.ProgressPct
	vm.ScenarioError = row.ScenarioError
	return vm
}
```

- [ ] **Step 5: Mount the route and pin it**

In `MountTerminalRoutes`, add `r.Get("/portfolio/{symbol}/terminal", h.StockTerminal)`. chi matches the static segment `terminal` before the existing `/portfolio/{symbol}/{tab}`. Add `"GET /portfolio/{symbol}/terminal",` to `terminalRoutes`.

- [ ] **Step 6: Generate and run the tests**

```bash
templ generate
GOFLAGS=-mod=mod go test ./internal/handlers/ ./internal/pages/stock/ ./internal/server/ -run 'StockTerminal|OverviewTab|TerminalRoutes|StockDetailFullRouter' -count=1 -v
```
Expected: PASS, including the existing stock router and overview tests.

- [ ] **Step 7: Commit**

```bash
git add internal/pages/stock internal/handlers/stock_terminal.go internal/handlers/stock_terminal_test.go internal/handlers/terminal.go internal/server/terminal_routes_test.go
git commit -m "feat(terminal): stock overview card with the ticker's scenario or an add link"
```

---

### Task 11: Full verification, manual pass, hand-off

**Files:**
- None new. Fix anything the gates report in the file that owns it.

**Interfaces:**
- Consumes: everything.
- Produces: a green branch, ready for review.

- [ ] **Step 1: Run every CI gate**

```bash
templ generate
bun run build
GOFLAGS=-mod=mod make test check
bash scripts/check-no-bare-controls.sh
git status --short
```
Expected: `make check` passes, covering check-controls, templui-check, verify-vig-assets, no `*_templ.go` diff, `go build`, `go test` and golangci-lint. `git status` is clean apart from gitignored build output. If lint flags something, fix it in place. Common causes are a govet `shadow` on an inner `err` and a revive builtin shadow. Re-run the gate, then commit with `git commit -m "chore(terminal): satisfy lint"`.

- [ ] **Step 2: Manual pass against a backend that serves the terminal API**

Run the web app against a backend that has the backend PR deployed: staging, or a local `norviq-backend-terminal` with Postgres and Redis. Use `BACKEND_URL=<that API base URL> GOFLAGS=-mod=mod go run .`, then open `http://localhost:6969/terminal`. Check each of these in **en and pt-PT** (switch with the language setting):
1. The empty state shows the AMZN "Sample" row. "Use this row" creates it and shows $909.09 / 1,100. A fresh account's "Dismiss" hides the sample, and the sample stays hidden after a reload.
2. Edit value wanted and confirm the row and footer update without a page reload. Tab across cells while a save is in flight, and confirm focus is not lost.
3. Set the terminal share count to 0 and confirm the inline error "Terminal share count must be above zero." with dashes in the derived cells.
4. Blur the market cap and confirm the label shows "$10T". Focus it and confirm the full number shows.
5. Confirm owned 750 shows 68.18%, and that the round-down toggle switches the share figures and survives a cell edit.
6. Check move up/down (the top row's Up is disabled), duplicate (the copy appears below), and delete (confirm first).
7. In the empty autobuys panel, confirm the three chips fill the form and create nothing. Check add, edit, pause and delete. Confirm the monthly equivalents and the total, and that a percent row with no base says "Add a monthly base".
8. As non-Pro, confirm "Fill with AI" shows the upgrade prompt. As Pro, confirm the suggestion shows sources, and that Accept fills the cells while Dismiss does not.
9. Confirm the `/dashboard` card shows totals, the top 3 and monthly autobuys. On a stock page, confirm the card shows for a ticker with a scenario, and that "Add terminal scenario" opens `/terminal` with the create form filled in.
10. Confirm the disclaimer is visible on `/terminal`, the dashboard card and the stock card.

Record anything that fails, fix it in its owning task's files, re-run Step 1, and commit.

- [ ] **Step 3: Hand off for review. Push only on approval.**

Report the branch, the commit list (`git log --oneline origin/main..HEAD`) and the gate results to the user. **Do not push.** Push and open the PR only after the user explicitly approves:
```bash
git push -u origin feat/terminal-positions
gh pr create --title "feat(terminal): terminal position sizing on the web" --body "<summary, test plan from Step 2, link to the spec and contract>"
```
Remind the user of the release order (spec "Order and release gates"): the web PR merges only after the backend PR is serving `/v1/terminal-positions`. Merging to main does not deploy. Staging and promotion are separate manual dispatches, and the promote dispatch needs `-f service=both`.
