# Terminal Position Sizing — MCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give MCP clients four tools over a user's terminal position scenarios: `get_terminal_positions`, `get_terminal_position`, `lookup_share_facts` (all read-only), and `set_terminal_scenario` (a confirmed, destructive-hinted write). Every number the tools show is computed by Norviq's backend, never by the model or the Go service.

**Architecture:** A hand-written client file, `internal/api/terminal_positions.go`, mirrors the contract's DTOs and the four backend routes MCP uses, following the other `internal/api/*.go` files. `APIError` gains `Code()` and `Reason()` so tools can tell a Pro upgrade (`403` + `code: upgrade_required`) apart from a missing scope (also `403`), and can show a `422` reason. `internal/tools/terminal_positions.go` registers the read tools behind `planning:read`. `internal/tools/terminal_scenario.go` registers `set_terminal_scenario` behind `planning:read` **and** `planning:write`: it reads the ticker's rows, then either PATCHes the first row by `sortOrder` or POSTs a new row, after `confirmMutation` shows the exact values. **Decision on `lookup_share_facts`: expose it as a read tool.** The contract lists it as an action "mirrored by norviq-mcp tools". MCP sessions are already Pro-entitled (the introspection gate in `server.go` requires `Entitled`). It returns validated numbers with sources instead of model guesses, and it never writes. The backend's Pro gate and `aiRateLimit` bound what it costs. `catalog_parity_test.go` only checks *write* tools, so a catalog read action with no MCP tool would be invisible to it, and no exclusion list exists or is needed. Task 4 adds `TestTerminalCatalogActionsHaveMCPTools`, which pins all four terminal actions in both directions.

**Tech Stack:** Go 1.27, `github.com/modelcontextprotocol/go-sdk` v1.7.0 (`github.com/google/jsonschema-go` v0.4.3 infers schemas; a `*float64` with `omitempty` becomes an optional, nullable number), stdlib `net/http/httptest` for fake backends, gofumpt, golangci-lint v2.13 (`govet shadow` on).

**Spec:** `/Users/fernandocorreiachill/Work/production/apps/norviq/norviq-backend-terminal/docs/superpowers/specs/2026-10-09-terminal-position-sizing-design.md` (section 4 "MCP"; also "Formulas", "Order and release gates", "Verification").
**Contract (exact names, endpoints, action table — authoritative):** `/Users/fernandocorreiachill/Work/production/apps/norviq/norviq-backend-terminal/docs/superpowers/plans/2026-10-09-terminal-contract.md`.

## Global Constraints

- Repo: `norviq-mcp`. Work in a new worktree `/Users/fernandocorreiachill/Work/production/apps/norviq/norviq-mcp-terminal` on branch `feat/terminal-positions` off `origin/main`. Do **not** push or open a PR until the user approves (Task 5).
- Tool names, verbatim from the contract: `get_terminal_positions`, `get_terminal_position`, `lookup_share_facts`, `set_terminal_scenario`.
- `set_terminal_scenario` argument names, verbatim (camelCase, as in the contract): `ticker`, `terminalShareCount`, `terminalMarketCap`, `valueWanted`, `sharesOwned`, `sharesOutstanding`, `currentSharePrice`. `get_terminal_position` and `lookup_share_facts` take `ticker`.
- Backend routes used, and no others: `GET /v1/terminal-positions[?ticker=]`, `POST /v1/terminal-positions` (with `Idempotency-Key`), `PATCH /v1/terminal-positions/:id`, `POST /v1/terminal-positions/ai/share-facts`. MCP never calls delete, duplicate, order, summary, autobuys or `ai/scenario`.
- Scopes: the read tools need `planning:read`. `set_terminal_scenario` needs `planning:read` **and** `planning:write`, because it GETs before it writes and the backend's `ScopeRequirementMiddleware` does not treat write as implying read.
- Formulas are never computed in Go: `terminalSharePrice = terminalMarketCap / terminalShareCount` and `sharesNeeded = valueWanted × terminalShareCount / terminalMarketCap` (plus `capitalAtTodayPrice`, `progress`, `sharesStillNeeded`, `gapValueAtTerminal`) come from the backend response and are passed through. Derived fields have no `omitempty`, so an invalid scenario shows `null` next to `scenarioError`.
- Every tool description ends with `terminalNotice`. It says that this is planning math, not advice; that terminal assumptions must come from the user or from cited sources; the two formulas exactly as above; and that the model must never compute or invent them.
- Disclaimer copy, verbatim, in every tool answer and confirmation: `Terminal prices are your assumptions, not forecasts. Not financial advice.`
- `set_terminal_scenario`: listed in `writeToolNames`, `Annotations: &mcp.ToolAnnotations{DestructiveHint: ptrBool(true)}`, and calls `confirmMutation(req, message)`. The message lists every value being written, and the old value on update. A non-nil `pending` is returned unchanged.
- Pro gate: the backend answers **HTTP 403** with `{"success":false,"code":"upgrade_required","feature":"terminal_position_ai",…}`. Detect it by `code == "upgrade_required"`, not by status, because a missing scope is also 403.
- Ticker: trim, uppercase, must match `^[A-Z0-9.\-]{1,12}$` (the backend's rule). Reject anything else before any backend call.
- No new module dependencies.
- Format with `go tool gofumpt -w .`. Lint with `golangci-lint run` (the pre-commit hook runs both, and `core.hooksPath=.githooks` applies in worktrees). With `govet shadow`, do not redeclare `err` in an inner scope.
- Baseline: on `origin/main` (4f314c6), `go test ./...` fails exactly one test, `TestGetNewsDefaultUsesTrackedFeed`. Its `/v1/news/feed` fixture is dated 2026-09-01, outside the 7-day lookback. CI on `main` is red for the same reason. This plan does not touch it. In every full run, that test must be the only failure.
- Deploy: merging to `main` **auto-deploys staging only**. `.github/workflows/deploy.yml` builds `ghcr.io/financeplanner/norviq-mcp:<sha>` and commits the tag to `LuminaVault/LuminaVaultInfra` `apps/norviq/mcp/values-staging.yaml`, and ArgoCD syncs `norviq-staging`, which has no ingress. Production changes only through `promote-norviq.yml -f service=mcp`: it opens a PR, and merging the PR deploys. `service=both` means api + web and does **not** include mcp. The `deploy-compose` job is legacy and runs only when `vars.COMPOSE_DEPLOY_ENABLED == 'true'`.

## Review Focus

1. **The backend ignores or loosens `?ticker=`.** If the GET returns other tickers' rows, the read tools must not show them as this ticker's scenario, and `set_terminal_scenario` must never PATCH another ticker's row. In that case it creates a row for the asked ticker. Pinned in Task 2 (`TestGetTerminalPositionIgnoresRowsForOtherTickers`) and Task 4 (`TestSetTerminalScenarioNeverPatchesAnotherTickersRow`).
2. **`sharesOwned: 0`** (the user owns none, or sold out) must be written as `0` and shown as `750 → 0`, not dropped as "not given". Pinned in Task 1 (`TestUpdateTerminalPositionSendsOnlyTheGivenFields`) and Task 4 (`TestSetTerminalScenarioWritesAZeroSharesOwned`).
3. **Duplicated rows for one ticker** (scenario variants, possibly unsorted in the response) must resolve to the lowest `sortOrder`. The user must be told it is "the first of N". Pinned in Task 2 (`TestGetTerminalPositionPicksTheFirstRowBySortOrder`) and Task 4 (`TestSetTerminalScenarioUpdatesTheFirstRowAfterConfirmation`).
4. **A model passes `amzn`, `" brk.b "`, `$AMZN` or a company name.** The first two must normalize to `AMZN` / `BRK.B`. The others must fail with no backend call and no confirmation prompt. Pinned in Task 2 (`TestGetTerminalPositionNormalizesTheTicker`, `TestGetTerminalPositionRejectsANonTickerWithoutCallingNorviq`) and Task 4 (`TestSetTerminalScenarioRejectsImpossibleValuesBeforeAsking`).
5. **A 403 that is not an upgrade** (a token missing `planning:read`) must not tell the user to buy Pro. A real upgrade 403 must say so plainly. Pinned in Task 3 (`TestLookupShareFactsExplainsTheProUpgrade`, `TestLookupShareFactsDoesNotCallAMissingScopeAnUpgrade`).

---

### Task 1: Worktree, baseline, and the terminal-positions API client

**Files:**
- Create: `internal/api/terminal_positions.go`
- Modify: `internal/api/client.go:42-44` (add `Code`, `Reason`, `bodyField` after `func (e *APIError) Error()`)
- Test: `internal/api/terminal_positions_test.go` (new; package `api_test`; this is the first test file in `internal/api`)

**Interfaces:**
- Consumes: `(*Client).do(ctx, method, path string, query url.Values, body, out any) error` and `(*Client).doWithIdempotency(ctx, method, path string, body, out any, key string) error` from `internal/api/client.go`.
- Produces:
  - `type TerminalPosition struct` with fields `ID, Ticker string; SharesOutstanding *float64; TerminalShareCount, TerminalMarketCap, ValueWanted, SharesOwned float64; CurrentSharePrice *float64; Notes *string; SortOrder int; TerminalSharePrice, SharesNeeded, CapitalAtTodayPrice, Progress, SharesStillNeeded, GapValueAtTerminal *float64; ScenarioError *string; CreatedAt, UpdatedAt string`
  - `type TerminalPositionsList struct { Currency string; Positions []TerminalPosition }`
  - `type TerminalPositionCreateRequest struct { Ticker string; SharesOutstanding *float64; TerminalShareCount, TerminalMarketCap, ValueWanted float64; SharesOwned, CurrentSharePrice *float64 }`
  - `type TerminalPositionUpdateRequest struct { SharesOutstanding, TerminalShareCount, TerminalMarketCap, ValueWanted, SharesOwned, CurrentSharePrice *float64 }` (all `omitempty`: nil is omitted, a pointer to 0 is sent)
  - `type ShareFactsSuggestion struct { Ticker string; SharesOutstanding, CurrentSharePrice *float64; Currency, AsOf *string; Sources []string }`
  - `func (c *Client) ListTerminalPositions(ctx context.Context, ticker string) (*TerminalPositionsList, error)` (sends no query when `ticker == ""`)
  - `func (c *Client) CreateTerminalPosition(ctx context.Context, req TerminalPositionCreateRequest, idempotencyKey string) (*TerminalPosition, error)`
  - `func (c *Client) UpdateTerminalPosition(ctx context.Context, id string, req TerminalPositionUpdateRequest) (*TerminalPosition, error)`
  - `func (c *Client) LookupShareFacts(ctx context.Context, ticker string) (*ShareFactsSuggestion, error)`
  - `func (e *APIError) Code() string` and `func (e *APIError) Reason() string` (the JSON body's `code` / `reason`, or `""`)

- [ ] **Step 1: Create the worktree and record the baseline**

```bash
git -C /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-mcp fetch origin
git -C /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-mcp worktree add \
  /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-mcp-terminal \
  -b feat/terminal-positions origin/main
cd /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-mcp-terminal
go test ./... 2>&1 | grep -E '^(--- FAIL|FAIL|ok)'
```

Expected: `--- FAIL: TestGetNewsDefaultUsesTrackedFeed` and nothing else failing. If anything else fails, stop and report it. Do not start on a red baseline you do not understand.

All later commands run from `/Users/fernandocorreiachill/Work/production/apps/norviq/norviq-mcp-terminal`.

- [ ] **Step 2: Write the failing tests**

Create `internal/api/terminal_positions_test.go`:

```go
package api_test

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/FinancePlanner/norviq-mcp/internal/api"
)

// The AMZN worked example from the spec: 10T terminal market cap, 11B terminal
// shares, 1M wanted, 750 owned at $200 → 909.09… per share, 1,100 shares needed.
const amznPositionJSON = `{"id":"11111111-1111-4111-8111-111111111111","ticker":"AMZN","sharesOutstanding":10600000000,"terminalShareCount":11000000000,"terminalMarketCap":10000000000000,"valueWanted":1000000,"sharesOwned":750,"currentSharePrice":200,"sortOrder":0,"terminalSharePrice":909.0909090909091,"sharesNeeded":1100,"capitalAtTodayPrice":220000,"progress":0.6818181818181818,"sharesStillNeeded":350,"gapValueAtTerminal":318181.8181818182,"createdAt":"2026-10-09T10:00:00Z","updatedAt":"2026-10-09T10:00:00Z"}`

// Swift's encoder omits nil optionals, so an invalid scenario arrives with no
// derived keys at all, only scenarioError.
const invalidPositionJSON = `{"id":"22222222-2222-4222-8222-222222222222","ticker":"VG","terminalShareCount":0,"terminalMarketCap":8000000000,"valueWanted":500000,"sharesOwned":0,"sortOrder":1,"scenarioError":"share_count_not_positive","createdAt":"2026-10-09T10:00:00Z","updatedAt":"2026-10-09T10:00:00Z"}`

func newTestClient(t *testing.T, handler http.HandlerFunc) *api.Client {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	return api.NewClient(srv.URL, "nvq_pat_test")
}

func TestListTerminalPositionsSendsTheTickerAndDecodesDerivedValues(t *testing.T) {
	var gotTicker, gotAuth string
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/v1/terminal-positions" {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		gotTicker = r.URL.Query().Get("ticker")
		gotAuth = r.Header.Get("Authorization")
		_, _ = w.Write([]byte(`{"currency":"USD","positions":[` + amznPositionJSON + `,` + invalidPositionJSON + `]}`))
	})

	list, err := client.ListTerminalPositions(context.Background(), "AMZN")
	if err != nil {
		t.Fatal(err)
	}
	if gotTicker != "AMZN" {
		t.Errorf("ticker query = %q, want AMZN", gotTicker)
	}
	if gotAuth != "Bearer nvq_pat_test" {
		t.Errorf("Authorization = %q, want the user's bearer", gotAuth)
	}
	if list.Currency != "USD" || len(list.Positions) != 2 {
		t.Fatalf("list = %+v, want USD and two positions", list)
	}
	valid := list.Positions[0]
	if valid.TerminalSharePrice == nil || *valid.TerminalSharePrice != 909.0909090909091 {
		t.Errorf("terminalSharePrice = %v, want the backend's 909.0909090909091", valid.TerminalSharePrice)
	}
	if valid.SharesNeeded == nil || *valid.SharesNeeded != 1100 {
		t.Errorf("sharesNeeded = %v, want the backend's 1100", valid.SharesNeeded)
	}
	invalid := list.Positions[1]
	if invalid.TerminalSharePrice != nil || invalid.SharesNeeded != nil || invalid.Progress != nil {
		t.Error("an invalid scenario must decode with nil derived values")
	}
	if invalid.ScenarioError == nil || *invalid.ScenarioError != "share_count_not_positive" {
		t.Errorf("scenarioError = %v, want share_count_not_positive", invalid.ScenarioError)
	}
}

func TestListTerminalPositionsWithoutATickerSendsNoQuery(t *testing.T) {
	rawQuery := "unset"
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		rawQuery = r.URL.RawQuery
		_, _ = w.Write([]byte(`{"currency":"EUR","positions":[]}`))
	})
	if _, err := client.ListTerminalPositions(context.Background(), ""); err != nil {
		t.Fatal(err)
	}
	if rawQuery != "" {
		t.Errorf("query = %q, want none", rawQuery)
	}
}

func TestUpdateTerminalPositionSendsOnlyTheGivenFields(t *testing.T) {
	var gotRequest string
	var body map[string]any
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		gotRequest = r.Method + " " + r.URL.Path
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		_, _ = w.Write([]byte(amznPositionJSON))
	})

	valueWanted := 2000000.0
	sharesOwned := 0.0
	updated, err := client.UpdateTerminalPosition(context.Background(), "11111111-1111-4111-8111-111111111111",
		api.TerminalPositionUpdateRequest{ValueWanted: &valueWanted, SharesOwned: &sharesOwned})
	if err != nil {
		t.Fatal(err)
	}
	if gotRequest != "PATCH /v1/terminal-positions/11111111-1111-4111-8111-111111111111" {
		t.Errorf("request = %q", gotRequest)
	}
	// sharesOwned 0 is a real value (the user owns none) and must be sent.
	if len(body) != 2 || body["valueWanted"] != 2000000.0 || body["sharesOwned"] != 0.0 {
		t.Errorf("PATCH body = %v, want exactly valueWanted 2000000 and sharesOwned 0", body)
	}
	if updated.ID != "11111111-1111-4111-8111-111111111111" {
		t.Errorf("decoded id = %q", updated.ID)
	}
}

func TestCreateTerminalPositionSendsAnIdempotencyKey(t *testing.T) {
	var gotKey string
	var body map[string]any
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/terminal-positions" {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		gotKey = r.Header.Get("Idempotency-Key")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(amznPositionJSON))
	})

	created, err := client.CreateTerminalPosition(context.Background(), api.TerminalPositionCreateRequest{
		Ticker: "AMZN", TerminalShareCount: 11000000000, TerminalMarketCap: 10000000000000, ValueWanted: 1000000,
	}, "mcp_test_key")
	if err != nil {
		t.Fatal(err)
	}
	if gotKey != "mcp_test_key" {
		t.Errorf("Idempotency-Key = %q, want mcp_test_key", gotKey)
	}
	if body["ticker"] != "AMZN" || body["terminalShareCount"] != 11000000000.0 ||
		body["terminalMarketCap"] != 10000000000000.0 || body["valueWanted"] != 1000000.0 {
		t.Errorf("POST body = %v", body)
	}
	for _, absent := range []string{"sharesOutstanding", "sharesOwned", "currentSharePrice"} {
		if _, ok := body[absent]; ok {
			t.Errorf("POST body carries %s although it was not given: %v", absent, body)
		}
	}
	if created.SharesNeeded == nil || *created.SharesNeeded != 1100 {
		t.Errorf("created sharesNeeded = %v, want 1100", created.SharesNeeded)
	}
}

func TestLookupShareFactsPostsTheTicker(t *testing.T) {
	var body map[string]any
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/terminal-positions/ai/share-facts" {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		_, _ = w.Write([]byte(`{"ticker":"AMZN","sharesOutstanding":10600000000,"currentSharePrice":201.5,"currency":"USD","asOf":"2026-10-08","sources":["https://ir.aboutamazon.com/quarterly-results"]}`))
	})

	facts, err := client.LookupShareFacts(context.Background(), "AMZN")
	if err != nil {
		t.Fatal(err)
	}
	if len(body) != 1 || body["ticker"] != "AMZN" {
		t.Errorf("body = %v, want only ticker AMZN", body)
	}
	if facts.SharesOutstanding == nil || *facts.SharesOutstanding != 10600000000 || len(facts.Sources) != 1 {
		t.Errorf("facts = %+v", facts)
	}
}

func TestLookupShareFactsKeepsTheUpgradeErrorReadable(t *testing.T) {
	client := newTestClient(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"success":false,"code":"upgrade_required","error":"Upgrade required","feature":"terminal_position_ai","plan":"free","requiredPlan":"pro"}`))
	})
	_, err := client.LookupShareFacts(context.Background(), "AMZN")
	var apiErr *api.APIError
	if !errors.As(err, &apiErr) {
		t.Fatalf("err = %v, want *api.APIError", err)
	}
	if apiErr.Status != http.StatusForbidden || apiErr.Code() != "upgrade_required" {
		t.Errorf("status %d code %q, want 403 upgrade_required", apiErr.Status, apiErr.Code())
	}
}

func TestAPIErrorReadsCodeAndReason(t *testing.T) {
	abort := &api.APIError{Status: 422, Body: `{"error":true,"reason":"Ticker must be 1-12 letters, digits, dots or hyphens."}`}
	if abort.Reason() != "Ticker must be 1-12 letters, digits, dots or hyphens." {
		t.Errorf("Reason() = %q", abort.Reason())
	}
	if abort.Code() != "" {
		t.Errorf("Code() = %q, want empty for a Vapor Abort body", abort.Code())
	}
	garbage := &api.APIError{Status: 502, Body: "<html>bad gateway</html>"}
	if garbage.Code() != "" || garbage.Reason() != "" {
		t.Error("a non-JSON body must yield empty code and reason")
	}
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `go test ./internal/api -run 'TerminalPosition|ShareFacts|APIError' -v`
Expected: FAIL to compile with `undefined: api.TerminalPositionUpdateRequest` (and the other new names), and `abort.Reason undefined`.

- [ ] **Step 4: Add `Code` and `Reason` to `APIError`**

In `internal/api/client.go`, directly after `func (e *APIError) Error() string { … }` (ends at line 44), add:

```go
// Code returns the "code" field of a JSON error body, such as
// "upgrade_required" from the backend's BillingErrorMiddleware, or "" when the
// body has none. A 403 means a missing scope as often as a Pro upgrade, so
// callers tell them apart by this, not by the status.
func (e *APIError) Code() string { return e.bodyField("code") }

// Reason returns the "reason" field a Vapor Abort renders, or "".
func (e *APIError) Reason() string { return e.bodyField("reason") }

func (e *APIError) bodyField(name string) string {
	var body map[string]any
	if err := json.Unmarshal([]byte(e.Body), &body); err != nil {
		return ""
	}
	value, _ := body[name].(string)
	return value
}
```

(`encoding/json` is already imported in `client.go`.)

- [ ] **Step 5: Write the client**

Create `internal/api/terminal_positions.go`:

```go
package api

import (
	"context"
	"net/http"
	"net/url"
)

// Terminal position types mirror StockPlanShared/TerminalPositions/
// TerminalPositionsDTOs.swift (norviq-shared 5.21.0), as fixed by the
// cross-repo contract norviq-backend/docs/superpowers/plans/
// 2026-10-09-terminal-contract.md.
//
// The derived values are computed by the backend (the shared TerminalMath) and
// passed through untouched. Nothing in this service computes them. They carry
// no omitempty, so an invalid scenario shows null next to scenarioError rather
// than leaving the model to wonder where they went.

type TerminalPosition struct {
	ID                 string   `json:"id"`
	Ticker             string   `json:"ticker"`
	SharesOutstanding  *float64 `json:"sharesOutstanding"`
	TerminalShareCount float64  `json:"terminalShareCount"`
	TerminalMarketCap  float64  `json:"terminalMarketCap"`
	ValueWanted        float64  `json:"valueWanted"`
	SharesOwned        float64  `json:"sharesOwned"`
	CurrentSharePrice  *float64 `json:"currentSharePrice"`
	Notes              *string  `json:"notes"`
	SortOrder          int      `json:"sortOrder"`
	// Derived by the backend; all nil when ScenarioError is set.
	TerminalSharePrice *float64 `json:"terminalSharePrice"`
	SharesNeeded       *float64 `json:"sharesNeeded"`
	// CapitalAtTodayPrice is also nil when the row has no current price.
	CapitalAtTodayPrice *float64 `json:"capitalAtTodayPrice"`
	Progress            *float64 `json:"progress"`
	SharesStillNeeded   *float64 `json:"sharesStillNeeded"`
	GapValueAtTerminal  *float64 `json:"gapValueAtTerminal"`
	// ScenarioError is a TerminalScenarioError raw value:
	// "share_count_not_positive", "market_cap_not_positive" or "invalid_number".
	ScenarioError *string `json:"scenarioError"`
	CreatedAt     string  `json:"createdAt"`
	UpdatedAt     string  `json:"updatedAt"`
}

type TerminalPositionsList struct {
	Currency  string             `json:"currency"`
	Positions []TerminalPosition `json:"positions"`
}

type TerminalPositionCreateRequest struct {
	Ticker             string   `json:"ticker"`
	SharesOutstanding  *float64 `json:"sharesOutstanding,omitempty"`
	TerminalShareCount float64  `json:"terminalShareCount"`
	TerminalMarketCap  float64  `json:"terminalMarketCap"`
	ValueWanted        float64  `json:"valueWanted"`
	SharesOwned        *float64 `json:"sharesOwned,omitempty"`
	CurrentSharePrice  *float64 `json:"currentSharePrice,omitempty"`
}

// TerminalPositionUpdateRequest is a PATCH: only non-nil fields change. A
// pointer to 0 is sent as 0. MCP never sends the contract's ticker, notes or
// clear fields.
type TerminalPositionUpdateRequest struct {
	SharesOutstanding  *float64 `json:"sharesOutstanding,omitempty"`
	TerminalShareCount *float64 `json:"terminalShareCount,omitempty"`
	TerminalMarketCap  *float64 `json:"terminalMarketCap,omitempty"`
	ValueWanted        *float64 `json:"valueWanted,omitempty"`
	SharesOwned        *float64 `json:"sharesOwned,omitempty"`
	CurrentSharePrice  *float64 `json:"currentSharePrice,omitempty"`
}

type ShareFactsRequest struct {
	Ticker string `json:"ticker"`
}

type ShareFactsSuggestion struct {
	Ticker            string   `json:"ticker"`
	SharesOutstanding *float64 `json:"sharesOutstanding"`
	CurrentSharePrice *float64 `json:"currentSharePrice"`
	Currency          *string  `json:"currency"`
	AsOf              *string  `json:"asOf"`
	Sources           []string `json:"sources"`
}

// ListTerminalPositions returns the user's rows in sortOrder. A non-empty
// ticker filters them (the backend matches case-insensitively).
func (c *Client) ListTerminalPositions(ctx context.Context, ticker string) (*TerminalPositionsList, error) {
	q := url.Values{}
	if ticker != "" {
		q.Set("ticker", ticker)
	}
	var out TerminalPositionsList
	if err := c.do(ctx, http.MethodGet, "/v1/terminal-positions", q, nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) CreateTerminalPosition(ctx context.Context, req TerminalPositionCreateRequest, idempotencyKey string) (*TerminalPosition, error) {
	var out TerminalPosition
	if err := c.doWithIdempotency(ctx, http.MethodPost, "/v1/terminal-positions", req, &out, idempotencyKey); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) UpdateTerminalPosition(ctx context.Context, id string, req TerminalPositionUpdateRequest) (*TerminalPosition, error) {
	var out TerminalPosition
	if err := c.do(ctx, http.MethodPatch, "/v1/terminal-positions/"+url.PathEscape(id), nil, req, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// LookupShareFacts asks the backend's Pro-gated AI lookup for shares
// outstanding and today's price. It only suggests; nothing is stored.
func (c *Client) LookupShareFacts(ctx context.Context, ticker string) (*ShareFactsSuggestion, error) {
	var out ShareFactsSuggestion
	if err := c.do(ctx, http.MethodPost, "/v1/terminal-positions/ai/share-facts", nil, ShareFactsRequest{Ticker: ticker}, &out); err != nil {
		return nil, err
	}
	return &out, nil
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `go test ./internal/api -run 'TerminalPosition|ShareFacts|APIError' -v`
Expected: PASS, all 7 tests.

- [ ] **Step 7: Commit**

```bash
go tool gofumpt -w internal/api
git add internal/api/terminal_positions.go internal/api/terminal_positions_test.go internal/api/client.go
git commit -m "feat(terminal): backend client for terminal positions and share facts"
```

---

### Task 2: `get_terminal_positions` and `get_terminal_position`

**Files:**
- Create: `internal/tools/terminal_positions.go`
- Modify: `internal/tools/expenses.go:49` (add `registerTerminalPositions(s, client, p)` after `registerPilots(s, client, p)`)
- Test: `internal/tools/terminal_positions_test.go` (new; package `tools_test`)

**Interfaces:**
- Consumes: Task 1's `api.TerminalPosition`, `api.TerminalPositionsList`, `(*api.Client).ListTerminalPositions`, `(*api.APIError).Reason`. From the package: `textResult(text string, isError bool) *mcp.CallToolResult` and `fail(err error) *mcp.CallToolResult` (`expenses.go`). From test helpers: `connect(t, scopes, backendURL, elicit) *mcp.ClientSession` (`tools_test.go`), and `callPilotTool(t, cs, name, args map[string]any) (string, bool)` and `listPilotTools(t, cs) []*mcp.Tool` (`pilots_test.go`). Despite their names, these are generic.
- Produces (package `tools`):
  - `const terminalDisclaimer = "Terminal prices are your assumptions, not forecasts. Not financial advice."`
  - `const terminalNotice` (description suffix)
  - `func normalizeTicker(raw string) (string, error)`
  - `func rowsForTicker(rows []api.TerminalPosition, ticker string) []api.TerminalPosition`
  - `func firstBySortOrder(rows []api.TerminalPosition) (api.TerminalPosition, bool)`
  - `func terminalFail(err error) *mcp.CallToolResult` (422 → "Norviq rejected this: <reason>…", else `fail`)
  - `func registerTerminalPositions(s *mcp.Server, client *api.Client, p *auth.Principal)`
- Produces (package `tools_test`): `terminalFake` (`rows map[string][]string`, `ignoreFilter bool`, `fail map[string]terminalFailure`, `calls []terminalCall`), `newTerminalFake()`, `(*terminalFake).server(t) *httptest.Server`, `(*terminalFake).writes() int`, `terminalCall{Method, Path, Query, IdempotencyKey string; Body map[string]any}`, `terminalFailure{status int; body string}`, `terminalRowJSON(id, ticker string, sortOrder int) string`, `invalidTerminalRowJSON`, `shareFactsJSON` (used by the fake's share-facts route), `terminalRowA/B/TSLA` ids, `terminalDisclaimerText`, `assertTerminalNotice(t, tool)`, `terminalTools(t, cs) map[string]*mcp.Tool`.

- [ ] **Step 1: Write the failing tests**

Create `internal/tools/terminal_positions_test.go`:

```go
package tools_test

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"github.com/FinancePlanner/norviq-mcp/internal/tools"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	terminalRowA    = "11111111-1111-4111-8111-111111111111"
	terminalRowB    = "22222222-2222-4222-8222-222222222222"
	terminalRowTSLA = "33333333-3333-4333-8333-333333333333"

	terminalDisclaimerText = "Terminal prices are your assumptions, not forecasts. Not financial advice."

	// Swift omits nil optionals: an invalid scenario has no derived keys at all.
	invalidTerminalRowJSON = `{"id":"44444444-4444-4444-8444-444444444444","ticker":"VG","terminalShareCount":0,"terminalMarketCap":8000000000,"valueWanted":500000,"sharesOwned":0,"sortOrder":0,"scenarioError":"share_count_not_positive","createdAt":"2026-10-09T10:00:00Z","updatedAt":"2026-10-09T10:00:00Z"}`

	shareFactsJSON = `{"ticker":"AMZN","sharesOutstanding":10600000000,"currentSharePrice":201.5,"currency":"USD","asOf":"2026-10-08","sources":["https://ir.aboutamazon.com/quarterly-results"]}`
)

// terminalRowJSON is a position as the backend renders it, using the spec's
// AMZN inputs (10T cap, 11B shares, 1M wanted, 750 owned). The derived values
// are canned and deliberately NOT what those inputs give (123.45 instead of
// 909.09…). MCP must pass Norviq's numbers through; a recomputation would show
// up as 909.09.
func terminalRowJSON(id, ticker string, sortOrder int) string {
	return fmt.Sprintf(`{"id":%q,"ticker":%q,"sharesOutstanding":10600000000,"terminalShareCount":11000000000,"terminalMarketCap":10000000000000,"valueWanted":1000000,"sharesOwned":750,"currentSharePrice":200,"sortOrder":%d,"terminalSharePrice":123.45,"sharesNeeded":4321,"capitalAtTodayPrice":864200,"progress":0.1736,"sharesStillNeeded":3571,"gapValueAtTerminal":440839.95,"createdAt":"2026-10-09T10:00:00Z","updatedAt":"2026-10-09T10:00:00Z"}`,
		id, ticker, sortOrder)
}

type terminalCall struct {
	Method, Path, Query, IdempotencyKey string
	Body                                map[string]any
}

type terminalFailure struct {
	status int
	body   string
}

// terminalFake fakes the backend's terminal-position routes and records calls.
type terminalFake struct {
	// rows maps an upper-case ticker to the row JSON objects GET ?ticker= answers
	// with; an unknown ticker answers an empty list.
	rows map[string][]string
	// ignoreFilter makes every GET answer with every row, as a backend that
	// ignored ?ticker= would.
	ignoreFilter bool
	// fail maps "METHOD /path" to a canned error response.
	fail  map[string]terminalFailure
	calls []terminalCall
}

func newTerminalFake() *terminalFake {
	return &terminalFake{rows: map[string][]string{}, fail: map[string]terminalFailure{}}
}

func (f *terminalFake) server(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := terminalCall{
			Method: r.Method, Path: r.URL.Path, Query: r.URL.RawQuery,
			IdempotencyKey: r.Header.Get("Idempotency-Key"),
		}
		if raw, _ := io.ReadAll(r.Body); len(raw) > 0 {
			_ = json.Unmarshal(raw, &call.Body)
		}
		f.calls = append(f.calls, call)
		w.Header().Set("Content-Type", "application/json")
		if failure, ok := f.fail[r.Method+" "+r.URL.Path]; ok {
			w.WriteHeader(failure.status)
			_, _ = w.Write([]byte(failure.body))
			return
		}
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v1/terminal-positions":
			ticker := strings.ToUpper(r.URL.Query().Get("ticker"))
			var rows []string
			for key, list := range f.rows {
				if ticker == "" || f.ignoreFilter || key == ticker {
					rows = append(rows, list...)
				}
			}
			_, _ = w.Write([]byte(`{"currency":"USD","positions":[` + strings.Join(rows, ",") + `]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/v1/terminal-positions":
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(terminalRowJSON(terminalRowTSLA, "TSLA", 0)))
		case r.Method == http.MethodPatch && strings.HasPrefix(r.URL.Path, "/v1/terminal-positions/"):
			_, _ = w.Write([]byte(terminalRowJSON(strings.TrimPrefix(r.URL.Path, "/v1/terminal-positions/"), "AMZN", 0)))
		case r.Method == http.MethodPost && r.URL.Path == "/v1/terminal-positions/ai/share-facts":
			_, _ = w.Write([]byte(shareFactsJSON))
		default:
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":true,"reason":"Not Found"}`))
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// writes counts calls that would change a terminal position.
func (f *terminalFake) writes() int {
	n := 0
	for _, c := range f.calls {
		create := c.Method == http.MethodPost && c.Path == "/v1/terminal-positions"
		if create || c.Method == http.MethodPatch || c.Method == http.MethodDelete {
			n++
		}
	}
	return n
}

func terminalTools(t *testing.T, cs *mcp.ClientSession) map[string]*mcp.Tool {
	t.Helper()
	byName := map[string]*mcp.Tool{}
	for _, tool := range listPilotTools(t, cs) {
		byName[tool.Name] = tool
	}
	return byName
}

// assertTerminalNotice pins what every terminal tool must tell the model before
// it says anything about a terminal scenario.
func assertTerminalNotice(t *testing.T, tool *mcp.Tool) {
	t.Helper()
	for _, want := range []string{
		"planning math, not advice",
		"must come from the user or from sources you cite",
		"terminalSharePrice = terminalMarketCap / terminalShareCount",
		"sharesNeeded = valueWanted × terminalShareCount / terminalMarketCap",
		"Never compute, round or invent them yourself",
		terminalDisclaimerText,
	} {
		if !strings.Contains(tool.Description, want) {
			t.Errorf("%s description is missing %q", tool.Name, want)
		}
	}
}

var terminalReadTools = []string{"get_terminal_positions", "get_terminal_position"}

func TestTerminalReadToolsNeedPlanningRead(t *testing.T) {
	f := newTerminalFake()
	backendURL := f.server(t).URL

	without := terminalTools(t, connect(t, map[string]bool{"goals:read": true, "portfolio:read": true}, backendURL, nil))
	for _, name := range terminalReadTools {
		if without[name] != nil {
			t.Errorf("%s exposed without planning:read", name)
		}
	}

	with := terminalTools(t, connect(t, map[string]bool{"planning:read": true}, backendURL, nil))
	for _, name := range terminalReadTools {
		tool := with[name]
		if tool == nil {
			t.Errorf("%s not exposed with planning:read", name)
			continue
		}
		if tool.Annotations == nil || !tool.Annotations.ReadOnlyHint {
			t.Errorf("%s must carry ReadOnlyHint", name)
		}
		if slices.Contains(tools.WriteToolNames(), name) {
			t.Errorf("%s is a read tool and must not be in WriteToolNames()", name)
		}
		assertTerminalNotice(t, tool)
	}
}

func TestGetTerminalPositionsPassesNorviqsNumbersThrough(t *testing.T) {
	f := newTerminalFake()
	f.rows["AMZN"] = []string{terminalRowJSON(terminalRowA, "AMZN", 0)}
	f.rows["VG"] = []string{invalidTerminalRowJSON}
	cs := connect(t, map[string]bool{"planning:read": true}, f.server(t).URL, nil)

	text, isErr := callPilotTool(t, cs, "get_terminal_positions", nil)
	if isErr {
		t.Fatalf("get_terminal_positions failed: %s", text)
	}
	for _, want := range []string{
		`"currency": "USD"`,
		`"terminalSharePrice": 123.45`,
		`"sharesNeeded": 4321`,
		`"scenarioError": "share_count_not_positive"`,
		terminalDisclaimerText,
	} {
		if !strings.Contains(text, want) {
			t.Errorf("result is missing %s:\n%s", want, text)
		}
	}
	if strings.Contains(text, "909.09") {
		t.Error("MCP computed a terminal share price instead of passing Norviq's through")
	}
	if len(f.calls) != 1 || f.calls[0].Query != "" {
		t.Errorf("calls = %+v, want one unfiltered GET", f.calls)
	}
	if f.writes() != 0 {
		t.Error("a read tool wrote to the backend")
	}
}

func TestGetTerminalPositionNormalizesTheTicker(t *testing.T) {
	f := newTerminalFake()
	f.rows["BRK.B"] = []string{terminalRowJSON(terminalRowA, "BRK.B", 0)}
	cs := connect(t, map[string]bool{"planning:read": true}, f.server(t).URL, nil)

	text, isErr := callPilotTool(t, cs, "get_terminal_position", map[string]any{"ticker": "  brk.b "})
	if isErr {
		t.Fatalf("get_terminal_position failed: %s", text)
	}
	if len(f.calls) != 1 || f.calls[0].Query != "ticker=BRK.B" {
		t.Fatalf("calls = %+v, want one GET with ticker=BRK.B", f.calls)
	}
	if !strings.Contains(text, `"ticker": "BRK.B"`) || !strings.Contains(text, terminalDisclaimerText) {
		t.Errorf("unexpected result:\n%s", text)
	}
}

func TestGetTerminalPositionRejectsANonTickerWithoutCallingNorviq(t *testing.T) {
	for _, bad := range []string{"", "Amazon.com Inc", "$AMZN", "ABCDEFGHIJKLM"} {
		f := newTerminalFake()
		cs := connect(t, map[string]bool{"planning:read": true}, f.server(t).URL, nil)
		text, isErr := callPilotTool(t, cs, "get_terminal_position", map[string]any{"ticker": bad})
		if !isErr || !strings.Contains(text, "not a valid ticker") {
			t.Errorf("ticker %q: got %q (error=%v), want a not-a-valid-ticker error", bad, text, isErr)
		}
		if len(f.calls) != 0 {
			t.Errorf("ticker %q reached the backend: %+v", bad, f.calls)
		}
	}
}

func TestGetTerminalPositionPicksTheFirstRowBySortOrder(t *testing.T) {
	f := newTerminalFake()
	// Deliberately out of order: the first row in the response is not first by sortOrder.
	f.rows["AMZN"] = []string{terminalRowJSON(terminalRowB, "AMZN", 4), terminalRowJSON(terminalRowA, "AMZN", 1)}
	cs := connect(t, map[string]bool{"planning:read": true}, f.server(t).URL, nil)

	text, isErr := callPilotTool(t, cs, "get_terminal_position", map[string]any{"ticker": "AMZN"})
	if isErr {
		t.Fatalf("get_terminal_position failed: %s", text)
	}
	if !strings.Contains(text, `"id": "`+terminalRowA+`"`) || strings.Contains(text, terminalRowB) {
		t.Errorf("want only the sortOrder-1 row %s:\n%s", terminalRowA, text)
	}
	if !strings.Contains(text, `"scenariosForTicker": 2`) {
		t.Errorf("want scenariosForTicker 2:\n%s", text)
	}
}

func TestGetTerminalPositionIgnoresRowsForOtherTickers(t *testing.T) {
	f := newTerminalFake()
	f.ignoreFilter = true
	f.rows["AMZN"] = []string{terminalRowJSON(terminalRowA, "AMZN", 0)}
	f.rows["TSLA"] = []string{terminalRowJSON(terminalRowTSLA, "TSLA", 1)}
	cs := connect(t, map[string]bool{"planning:read": true}, f.server(t).URL, nil)

	text, isErr := callPilotTool(t, cs, "get_terminal_position", map[string]any{"ticker": "TSLA"})
	if isErr {
		t.Fatalf("get_terminal_position failed: %s", text)
	}
	if !strings.Contains(text, terminalRowTSLA) || strings.Contains(text, terminalRowA) {
		t.Errorf("want only the TSLA row even when the backend returns others:\n%s", text)
	}
	if !strings.Contains(text, `"scenariosForTicker": 1`) {
		t.Errorf("want scenariosForTicker 1:\n%s", text)
	}
}

func TestGetTerminalPositionSaysWhenThereIsNone(t *testing.T) {
	f := newTerminalFake()
	cs := connect(t, map[string]bool{"planning:read": true}, f.server(t).URL, nil)

	text, isErr := callPilotTool(t, cs, "get_terminal_position", map[string]any{"ticker": "tsla"})
	if isErr {
		t.Fatalf("no row is an answer, not an error: %s", text)
	}
	if !strings.Contains(text, "No terminal scenario for TSLA") {
		t.Errorf("got %q", text)
	}
}

func TestGetTerminalPositionReportsAnInvalidScenario(t *testing.T) {
	f := newTerminalFake()
	f.rows["VG"] = []string{invalidTerminalRowJSON}
	cs := connect(t, map[string]bool{"planning:read": true}, f.server(t).URL, nil)

	text, isErr := callPilotTool(t, cs, "get_terminal_position", map[string]any{"ticker": "VG"})
	if isErr {
		t.Fatalf("get_terminal_position failed: %s", text)
	}
	for _, want := range []string{
		`"scenarioError": "share_count_not_positive"`,
		`"terminalSharePrice": null`,
		`"sharesNeeded": null`,
	} {
		if !strings.Contains(text, want) {
			t.Errorf("result is missing %s:\n%s", want, text)
		}
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/tools -run 'TerminalReadTools|GetTerminalPosition' -v`
Expected: FAIL. `TestTerminalReadToolsNeedPlanningRead` reports `get_terminal_positions not exposed with planning:read`, and the call tests fail with an unknown-tool error from `callPilotTool`.

- [ ] **Step 3: Write the implementation**

Create `internal/tools/terminal_positions.go`:

```go
package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"

	"github.com/FinancePlanner/norviq-mcp/internal/api"
	"github.com/FinancePlanner/norviq-mcp/internal/auth"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// terminalDisclaimer is the spec's disclaimer copy, verbatim. Every terminal
// tool answer and confirmation carries it.
const terminalDisclaimer = "Terminal prices are your assumptions, not forecasts. Not financial advice."

// terminalNotice ends every terminal tool description. A model that reads only
// the tool list must still know that this is planning math, where the
// assumptions come from, and that Norviq, not the model, does the arithmetic.
const terminalNotice = " Terminal position sizing is planning math, not advice: Norviq never recommends buying or selling. " +
	"Terminal assumptions (terminal market cap, terminal share count, value wanted) must come from the user or from sources you cite to the user; never invent or estimate them. " +
	"Norviq computes every derived value: terminalSharePrice = terminalMarketCap / terminalShareCount; " +
	"sharesNeeded = valueWanted × terminalShareCount / terminalMarketCap; and from those capitalAtTodayPrice, progress, " +
	"sharesStillNeeded and gapValueAtTerminal. Report the values Norviq returns. Never compute, round or invent them yourself. " +
	"When scenarioError is set the derived values are null: say the scenario is invalid and why, and do not fill them in. " +
	terminalDisclaimer

// tickerPattern is the backend's ticker rule, applied after trimming and
// uppercasing.
var tickerPattern = regexp.MustCompile(`^[A-Z0-9.\-]{1,12}$`)

func normalizeTicker(raw string) (string, error) {
	ticker := strings.ToUpper(strings.TrimSpace(raw))
	if !tickerPattern.MatchString(ticker) {
		return "", fmt.Errorf("%q is not a valid ticker: use the exchange ticker, 1 to 12 letters, digits, dots or hyphens, such as AMZN or BRK.B", raw)
	}
	return ticker, nil
}

// rowsForTicker keeps only the rows for ticker. The backend already filters on
// ?ticker=, but a write picks its target from this list, so a backend that
// ignored the filter must not lead MCP to change another ticker's row.
func rowsForTicker(rows []api.TerminalPosition, ticker string) []api.TerminalPosition {
	var out []api.TerminalPosition
	for _, row := range rows {
		if strings.EqualFold(row.Ticker, ticker) {
			out = append(out, row)
		}
	}
	return out
}

// firstBySortOrder is the contract's "first row for the ticker by sortOrder".
// The backend returns rows sorted, but the choice decides which row a write
// changes, so it does not rely on that.
func firstBySortOrder(rows []api.TerminalPosition) (api.TerminalPosition, bool) {
	if len(rows) == 0 {
		return api.TerminalPosition{}, false
	}
	first := rows[0]
	for _, row := range rows[1:] {
		if row.SortOrder < first.SortOrder {
			first = row
		}
	}
	return first, true
}

// terminalFail maps a backend error from a terminal route. A 422 carries the
// backend's reason. errmap's generic "try again shortly" would invite the model
// to retry values Norviq has already rejected.
func terminalFail(err error) *mcp.CallToolResult {
	var apiErr *api.APIError
	if errors.As(err, &apiErr) && apiErr.Status == http.StatusUnprocessableEntity {
		reason := apiErr.Reason()
		if reason == "" {
			reason = "the values were not accepted"
		}
		return textResult("Norviq rejected this: "+strings.TrimSuffix(reason, ".")+
			". Check the values with the user before trying again; do not retry them unchanged.", true)
	}
	return fail(err)
}

type terminalPositionsView struct {
	Currency   string                 `json:"currency"`
	Positions  []api.TerminalPosition `json:"positions"`
	Disclaimer string                 `json:"disclaimer"`
}

type terminalPositionView struct {
	Currency string               `json:"currency"`
	Position api.TerminalPosition `json:"position"`
	// ScenariosForTicker counts the user's rows for this ticker. A duplicated row
	// is a scenario variant, and set_terminal_scenario changes only the first.
	ScenariosForTicker int    `json:"scenariosForTicker"`
	Disclaimer         string `json:"disclaimer"`
}

func registerTerminalPositions(s *mcp.Server, client *api.Client, p *auth.Principal) {
	if !p.Scopes["planning:read"] {
		return
	}

	mcp.AddTool(s, &mcp.Tool{
		Name: "get_terminal_positions",
		Description: "List the user's terminal position scenarios in their sort order, with the account currency. " +
			"Each row has the user's inputs (ticker, terminal share count, terminal market cap, value wanted, shares owned, " +
			"and optionally shares outstanding and today's share price) and the values Norviq derived from them " +
			"(terminalSharePrice, sharesNeeded, capitalAtTodayPrice, progress, sharesStillNeeded, gapValueAtTerminal)." +
			terminalNotice,
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, any, error) {
		list, err := client.ListTerminalPositions(ctx, "")
		if err != nil {
			return terminalFail(err), nil, nil
		}
		positions := list.Positions
		if positions == nil {
			positions = []api.TerminalPosition{}
		}
		body, _ := json.MarshalIndent(terminalPositionsView{
			Currency: list.Currency, Positions: positions, Disclaimer: terminalDisclaimer,
		}, "", "  ")
		return textResult(string(body), false), nil, nil
	})

	type tickerArgs struct {
		Ticker string `json:"ticker" jsonschema:"stock ticker, e.g. AMZN or BRK.B"`
	}
	mcp.AddTool(s, &mcp.Tool{
		Name: "get_terminal_position",
		Description: "Get the user's terminal scenario for one ticker: the first row for that ticker in the user's sort order, " +
			"with the values Norviq derived, and how many scenario rows the ticker has (a duplicated row is a scenario variant). " +
			"Says so plainly when the ticker has no row." +
			terminalNotice,
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, args tickerArgs) (*mcp.CallToolResult, any, error) {
		ticker, err := normalizeTicker(args.Ticker)
		if err != nil {
			return textResult(err.Error(), true), nil, nil
		}
		list, err := client.ListTerminalPositions(ctx, ticker)
		if err != nil {
			return terminalFail(err), nil, nil
		}
		rows := rowsForTicker(list.Positions, ticker)
		first, ok := firstBySortOrder(rows)
		if !ok {
			return textResult(fmt.Sprintf(
				"No terminal scenario for %s yet. To add one, ask the user for the terminal market cap, terminal share count and value wanted, then call set_terminal_scenario.",
				ticker,
			), false), nil, nil
		}
		body, _ := json.MarshalIndent(terminalPositionView{
			Currency: list.Currency, Position: first, ScenariosForTicker: len(rows), Disclaimer: terminalDisclaimer,
		}, "", "  ")
		return textResult(string(body), false), nil, nil
	})
}
```

In `internal/tools/expenses.go`, inside `Register`, add one line after `registerPilots(s, client, p)` (line 49):

```go
	registerTerminalPositions(s, client, p)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/tools -run 'TerminalReadTools|GetTerminalPosition' -v`
Expected: PASS, all 8 tests.

Then run: `go test ./internal/tools 2>&1 | grep -E '^(--- FAIL|ok|FAIL)'`
Expected: only `--- FAIL: TestGetNewsDefaultUsesTrackedFeed` (baseline).

- [ ] **Step 5: Commit**

```bash
go tool gofumpt -w internal/tools
git add internal/tools/terminal_positions.go internal/tools/terminal_positions_test.go internal/tools/expenses.go
git commit -m "feat(terminal): get_terminal_positions and get_terminal_position read tools"
```

---

### Task 3: `lookup_share_facts` (Pro, read-only)

**Files:**
- Modify: `internal/tools/terminal_positions.go` (add `shareFactsUpgradeMessage`, `shareFactsFail`, `shareFactsView`, `registerShareFacts`, and one call in `registerTerminalPositions`)
- Test: `internal/tools/terminal_positions_test.go` (append)

**Interfaces:**
- Consumes: Task 1's `(*api.Client).LookupShareFacts`, `api.ShareFactsSuggestion`, `(*api.APIError).Code`. Task 2's `normalizeTicker`, `terminalFail`, `terminalNotice`, and the test fake (`shareFactsJSON`, `terminalFailure`, `writes()`, `assertTerminalNotice`, `terminalTools`).
- Produces: `func registerShareFacts(s *mcp.Server, client *api.Client)`, `const shareFactsUpgradeMessage` (contains "lookup_share_facts needs Norviq Pro"), `func shareFactsFail(err error, ticker string) *mcp.CallToolResult`.

- [ ] **Step 1: Write the failing tests**

Append to `internal/tools/terminal_positions_test.go`:

```go
const (
	shareFactsPath = "POST /v1/terminal-positions/ai/share-facts"

	// BillingErrorMiddleware's body for a non-Pro user: HTTP 403, code upgrade_required.
	upgradeRequiredJSON = `{"success":false,"code":"upgrade_required","error":"Upgrade required","feature":"terminal_position_ai","plan":"free","requiredPlan":"pro"}`
)

func TestLookupShareFactsIsAProReadTool(t *testing.T) {
	f := newTerminalFake()
	backendURL := f.server(t).URL
	if terminalTools(t, connect(t, map[string]bool{"market:read": true}, backendURL, nil))["lookup_share_facts"] != nil {
		t.Error("lookup_share_facts exposed without planning:read")
	}
	tool := terminalTools(t, connect(t, map[string]bool{"planning:read": true}, backendURL, nil))["lookup_share_facts"]
	if tool == nil {
		t.Fatal("lookup_share_facts not exposed with planning:read")
	}
	if tool.Annotations == nil || !tool.Annotations.ReadOnlyHint || slices.Contains(tools.WriteToolNames(), "lookup_share_facts") {
		t.Error("lookup_share_facts must be a ReadOnlyHint tool outside WriteToolNames()")
	}
	for _, want := range []string{"Norviq Pro", "saves nothing"} {
		if !strings.Contains(tool.Description, want) {
			t.Errorf("description is missing %q", want)
		}
	}
	assertTerminalNotice(t, tool)
}

func TestLookupShareFactsReturnsASuggestionAndWritesNothing(t *testing.T) {
	f := newTerminalFake()
	cs := connect(t, map[string]bool{"planning:read": true}, f.server(t).URL, nil)

	text, isErr := callPilotTool(t, cs, "lookup_share_facts", map[string]any{"ticker": " amzn"})
	if isErr {
		t.Fatalf("lookup_share_facts failed: %s", text)
	}
	if len(f.calls) != 1 || f.calls[0].Method+" "+f.calls[0].Path != shareFactsPath || f.calls[0].Body["ticker"] != "AMZN" {
		t.Fatalf("calls = %+v, want one share-facts POST for AMZN", f.calls)
	}
	if f.writes() != 0 {
		t.Error("lookup_share_facts wrote a terminal position")
	}
	for _, want := range []string{`"sharesOutstanding": 10600000000`, "https://ir.aboutamazon.com/quarterly-results", `"saved": false`} {
		if !strings.Contains(text, want) {
			t.Errorf("result is missing %s:\n%s", want, text)
		}
	}
}

func TestLookupShareFactsExplainsTheProUpgrade(t *testing.T) {
	f := newTerminalFake()
	f.fail[shareFactsPath] = terminalFailure{http.StatusForbidden, upgradeRequiredJSON}
	cs := connect(t, map[string]bool{"planning:read": true}, f.server(t).URL, nil)

	text, isErr := callPilotTool(t, cs, "lookup_share_facts", map[string]any{"ticker": "AMZN"})
	if !isErr || !strings.Contains(text, "lookup_share_facts needs Norviq Pro") {
		t.Errorf("got %q (error=%v), want the Pro upgrade message", text, isErr)
	}
}

func TestLookupShareFactsDoesNotCallAMissingScopeAnUpgrade(t *testing.T) {
	f := newTerminalFake()
	f.fail[shareFactsPath] = terminalFailure{http.StatusForbidden, `{"error":true,"reason":"insufficient_scope: 'planning:read' required"}`}
	cs := connect(t, map[string]bool{"planning:read": true}, f.server(t).URL, nil)

	text, isErr := callPilotTool(t, cs, "lookup_share_facts", map[string]any{"ticker": "AMZN"})
	if !isErr {
		t.Fatal("a 403 must be an error")
	}
	if strings.Contains(text, "lookup_share_facts needs Norviq Pro") {
		t.Errorf("a missing scope was reported as a Pro upgrade: %q", text)
	}
}

func TestLookupShareFactsSaysWhenTheAILookupCannotAnswer(t *testing.T) {
	cases := []struct {
		status int
		want   string
	}{
		{http.StatusServiceUnavailable, "unavailable right now"},
		{http.StatusUnprocessableEntity, "could not find usable, sourced numbers"},
	}
	for _, tc := range cases {
		f := newTerminalFake()
		f.fail[shareFactsPath] = terminalFailure{tc.status, `{"error":true,"reason":"AI lookup unavailable"}`}
		cs := connect(t, map[string]bool{"planning:read": true}, f.server(t).URL, nil)

		text, isErr := callPilotTool(t, cs, "lookup_share_facts", map[string]any{"ticker": "AMZN"})
		if !isErr || !strings.Contains(text, tc.want) || !strings.Contains(text, "Do not guess them") {
			t.Errorf("status %d: got %q (error=%v), want %q and a do-not-guess instruction", tc.status, text, isErr, tc.want)
		}
	}
}

func TestLookupShareFactsRejectsANonTicker(t *testing.T) {
	f := newTerminalFake()
	cs := connect(t, map[string]bool{"planning:read": true}, f.server(t).URL, nil)
	// "AMAZON" would be a syntactically valid ticker; a name with a space is not.
	text, isErr := callPilotTool(t, cs, "lookup_share_facts", map[string]any{"ticker": "Amazon Inc"})
	if !isErr || !strings.Contains(text, "not a valid ticker") {
		t.Errorf("got %q (error=%v), want a not-a-valid-ticker error", text, isErr)
	}
	if len(f.calls) != 0 {
		t.Errorf("an invalid ticker reached the backend: %+v", f.calls)
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/tools -run 'LookupShareFacts' -v`
Expected: FAIL. `lookup_share_facts not exposed with planning:read`, and the call tests fail with an unknown tool.

- [ ] **Step 3: Write the implementation**

Add to `internal/tools/terminal_positions.go`, below `terminalFail`:

```go
// shareFactsUpgradeMessage answers the backend's Pro gate: a 403 whose body
// code is "upgrade_required". The table itself is free, so the message says the
// user can still type the numbers in.
const shareFactsUpgradeMessage = "lookup_share_facts needs Norviq Pro: the AI share-facts lookup is a Pro feature. " +
	"Terminal position sizing itself is free, so the user can still enter shares outstanding and today's price themselves. " +
	"Upgrade at norviq.org."

// shareFactsFail maps the AI lookup's documented failures. It is not errmap's
// job: errmap says "Pro, or a missing permission" for every 403, and calls a
// 503 a transient fault worth retrying.
func shareFactsFail(err error, ticker string) *mcp.CallToolResult {
	var apiErr *api.APIError
	if errors.As(err, &apiErr) {
		switch {
		case apiErr.Status == http.StatusForbidden && apiErr.Code() == "upgrade_required":
			return textResult(shareFactsUpgradeMessage, true)
		case apiErr.Status == http.StatusServiceUnavailable:
			return textResult("Norviq's AI lookup is unavailable right now, so there are no sourced numbers for "+ticker+
				". Ask the user for shares outstanding and today's price, or cite a source they can check. Do not guess them.", true)
		case apiErr.Status == http.StatusUnprocessableEntity:
			return textResult("Norviq's AI lookup could not find usable, sourced numbers for "+ticker+
				". Ask the user for shares outstanding and today's price, or cite a source they can check. Do not guess them.", true)
		}
	}
	return terminalFail(err)
}

type shareFactsView struct {
	Suggestion api.ShareFactsSuggestion `json:"suggestion"`
	// Saved is always false: the lookup only suggests.
	Saved bool   `json:"saved"`
	Note  string `json:"note"`
}

func registerShareFacts(s *mcp.Server, client *api.Client) {
	type tickerArgs struct {
		Ticker string `json:"ticker" jsonschema:"stock ticker, e.g. AMZN or BRK.B"`
	}
	mcp.AddTool(s, &mcp.Tool{
		Name: "lookup_share_facts",
		Description: "Norviq Pro. Ask Norviq's AI web lookup for a ticker's shares outstanding and share price today, with the sources " +
			"it used and the as-of date. It returns a suggestion and saves nothing: show the user the numbers and the sources, " +
			"and write them with set_terminal_scenario (sharesOutstanding, currentSharePrice) only if the user agrees. " +
			"It never suggests a terminal market cap, terminal share count or value wanted; those stay the user's assumptions." +
			terminalNotice,
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, args tickerArgs) (*mcp.CallToolResult, any, error) {
		ticker, err := normalizeTicker(args.Ticker)
		if err != nil {
			return textResult(err.Error(), true), nil, nil
		}
		facts, err := client.LookupShareFacts(ctx, ticker)
		if err != nil {
			return shareFactsFail(err, ticker), nil, nil
		}
		body, _ := json.MarshalIndent(shareFactsView{
			Suggestion: *facts,
			Saved:      false,
			Note: "Suggestion only; nothing was saved. Show the user these numbers with their sources before writing anything. " +
				terminalDisclaimer,
		}, "", "  ")
		return textResult(string(body), false), nil, nil
	})
}
```

In `registerTerminalPositions`, add this as its last statement, after the `get_terminal_position` `mcp.AddTool(...)` call:

```go
	registerShareFacts(s, client)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/tools -run 'LookupShareFacts|TerminalReadTools|GetTerminalPosition' -v`
Expected: PASS (6 new tests plus Task 2's 8).

- [ ] **Step 5: Commit**

```bash
go tool gofumpt -w internal/tools
git add internal/tools/terminal_positions.go internal/tools/terminal_positions_test.go
git commit -m "feat(terminal): lookup_share_facts read tool with Pro upgrade mapping"
```

---

### Task 4: `set_terminal_scenario` (confirmed write) and catalog parity

**Files:**
- Modify: `internal/tools/testdata/action-catalog.json` (regenerated by `make catalog-snapshot`, never hand-edited)
- Create: `internal/tools/terminal_scenario.go`
- Modify: `internal/tools/terminal_positions.go` (`registerTerminalPositions`: register the write tool when `planning:write` is also held)
- Modify: `internal/tools/confirmation.go:11-43` (append `"set_terminal_scenario"` to `writeToolNames`)
- Modify: `internal/tools/catalog_parity_test.go` (add to `mcpToCatalog`; add `terminalActions` and `TestTerminalCatalogActionsHaveMCPTools`)
- Modify: `internal/tools/tools_test.go` (in `TestEveryMutatingToolIsInTheWriteAllowlist`, add `"planning:read", "planning:write"` to the scope list)
- Test: `internal/tools/terminal_scenario_test.go` (new)

**Interfaces:**
- Consumes: Task 1's `api.TerminalPositionCreateRequest`, `api.TerminalPositionUpdateRequest`, `(*api.Client).CreateTerminalPosition`, `(*api.Client).UpdateTerminalPosition`, `(*api.Client).ListTerminalPositions`. Task 2's `normalizeTicker`, `rowsForTicker`, `firstBySortOrder`, `terminalFail`, `terminalNotice`, `terminalDisclaimer`. From the package: `confirmMutation(req, message) (bool, *mcp.CallToolResult, error)`, `idempotencyKey(userID string, args any) string`, `ptrBool`, `textResult`, `fail`. From tests: Task 2's fake and helpers, plus `acceptElicit` / `declineElicit` (`tools_test.go`) and `loadCatalog(t)` (`catalog_parity_test.go`).
- Produces: `func registerSetTerminalScenario(s *mcp.Server, client *api.Client, p *auth.Principal)`, `type setTerminalScenarioArgs`, `type terminalWriteView { Action, Currency string; Position api.TerminalPosition; Disclaimer string }`.

- [ ] **Step 1: Refresh the catalog snapshot (precondition)**

This needs a backend that already serves the terminal actions, i.e. the backend plan's `AI/ActionCatalog+TerminalPositions.swift` is deployed. Prefer staging, which has no public host, so port-forward it in a separate shell or as a background command:

```bash
KUBECONFIG=~/.kube/maat.yaml kubectl -n norviq-staging port-forward svc/api 18080:8080
```

If the backend branch has not reached staging yet, run it locally from its worktree instead (see its README) and use `NORVIQ_API=http://localhost:8090`. Ask the user for a PAT valid on that backend. Never write the token into a file or commit.

```bash
NORVIQ_API=http://localhost:18080 NORVIQ_TOKEN="$TOKEN_FROM_USER" make catalog-snapshot
python3 -c 'import json; a={x["name"]:x["destructive"] for x in json.load(open("internal/tools/testdata/action-catalog.json"))["actions"]}; want={"get_terminal_positions":False,"get_terminal_position":False,"lookup_share_facts":False,"set_terminal_scenario":True}; bad={k:a.get(k) for k,v in want.items() if a.get(k)!=v}; print("OK" if not bad else "MISSING/WRONG: %s" % bad)'
go test ./internal/tools -run 'TestEveryWriteToolIsMappedOrDeclaredMCPOnly|TestDestructiveClassificationAgrees' -v
```

Expected: `OK`, then both parity tests PASS. The refreshed snapshot may also add other catalog actions. That is fine, because the parity test only walks MCP *write* tools. If the check prints `MISSING/WRONG`, **stop**: the backend is not ready. Do not hand-edit the snapshot to make it pass.

- [ ] **Step 2: Write the failing tests**

Create `internal/tools/terminal_scenario_test.go`:

```go
package tools_test

import (
	"context"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/FinancePlanner/norviq-mcp/internal/tools"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var terminalWriteScopes = map[string]bool{"planning:read": true, "planning:write": true}

// confirmAndCapture accepts the confirmation and records what the user was shown.
func confirmAndCapture(prompt *string) func(context.Context, *mcp.ElicitRequest) (*mcp.ElicitResult, error) {
	return func(_ context.Context, req *mcp.ElicitRequest) (*mcp.ElicitResult, error) {
		if req.Params != nil {
			*prompt = req.Params.Message
		}
		return &mcp.ElicitResult{Action: "accept", Content: map[string]any{"confirm": true}}, nil
	}
}

func (f *terminalFake) callsWith(method string) []terminalCall {
	var out []terminalCall
	for _, c := range f.calls {
		if c.Method == method {
			out = append(out, c)
		}
	}
	return out
}

func TestSetTerminalScenarioIsAConfirmedWriteTool(t *testing.T) {
	f := newTerminalFake()
	backendURL := f.server(t).URL
	for _, scopes := range []map[string]bool{{"planning:read": true}, {"planning:write": true}} {
		if terminalTools(t, connect(t, scopes, backendURL, acceptElicit))["set_terminal_scenario"] != nil {
			t.Errorf("set_terminal_scenario exposed with only %v; it reads before it writes, so it needs both planning scopes", scopes)
		}
	}
	tool := terminalTools(t, connect(t, terminalWriteScopes, backendURL, acceptElicit))["set_terminal_scenario"]
	if tool == nil {
		t.Fatal("set_terminal_scenario not exposed with planning:read and planning:write")
	}
	if tool.Annotations == nil || tool.Annotations.ReadOnlyHint ||
		tool.Annotations.DestructiveHint == nil || !*tool.Annotations.DestructiveHint {
		t.Error("set_terminal_scenario must carry DestructiveHint true and no ReadOnlyHint")
	}
	if !slices.Contains(tools.WriteToolNames(), "set_terminal_scenario") {
		t.Error("set_terminal_scenario must be in WriteToolNames() so clients that cannot confirm never see it")
	}
	if !strings.Contains(tool.Description, "confirm") {
		t.Error("the description must say the user confirms first")
	}
	assertTerminalNotice(t, tool)
}

func TestSetTerminalScenarioUpdatesTheFirstRowAfterConfirmation(t *testing.T) {
	f := newTerminalFake()
	f.rows["AMZN"] = []string{terminalRowJSON(terminalRowB, "AMZN", 3), terminalRowJSON(terminalRowA, "AMZN", 0)}
	var prompt string
	cs := connect(t, terminalWriteScopes, f.server(t).URL, confirmAndCapture(&prompt))

	text, isErr := callPilotTool(t, cs, "set_terminal_scenario", map[string]any{
		"ticker": "amzn", "terminalMarketCap": 12000000000000,
	})
	if isErr {
		t.Fatalf("set_terminal_scenario failed: %s", text)
	}
	patches := f.callsWith(http.MethodPatch)
	if len(patches) != 1 || patches[0].Path != "/v1/terminal-positions/"+terminalRowA {
		t.Fatalf("patches = %+v, want one PATCH of the sortOrder-0 row %s", patches, terminalRowA)
	}
	if len(patches[0].Body) != 1 || patches[0].Body["terminalMarketCap"] != 12000000000000.0 {
		t.Errorf("PATCH body = %v, want only terminalMarketCap", patches[0].Body)
	}
	if len(f.callsWith(http.MethodPost)) != 0 {
		t.Error("an update must not also create a row")
	}
	for _, want := range []string{
		"Update the terminal scenario for AMZN (the first of 2 AMZN rows):",
		"- terminal market cap: 10000000000000 USD → 12000000000000 USD",
		terminalDisclaimerText,
	} {
		if !strings.Contains(prompt, want) {
			t.Errorf("confirmation is missing %q:\n%s", want, prompt)
		}
	}
	if strings.Contains(prompt, "value wanted") {
		t.Errorf("the confirmation lists a field that is not being written:\n%s", prompt)
	}
	for _, want := range []string{`"action": "updated"`, `"currency": "USD"`, `"terminalSharePrice": 123.45`, `"sharesNeeded": 4321`} {
		if !strings.Contains(text, want) {
			t.Errorf("result is missing %s:\n%s", want, text)
		}
	}
}

func TestSetTerminalScenarioWritesAZeroSharesOwned(t *testing.T) {
	f := newTerminalFake()
	f.rows["AMZN"] = []string{terminalRowJSON(terminalRowA, "AMZN", 0)}
	var prompt string
	cs := connect(t, terminalWriteScopes, f.server(t).URL, confirmAndCapture(&prompt))

	text, isErr := callPilotTool(t, cs, "set_terminal_scenario", map[string]any{"ticker": "AMZN", "sharesOwned": 0})
	if isErr {
		t.Fatalf("set_terminal_scenario failed: %s", text)
	}
	patches := f.callsWith(http.MethodPatch)
	if len(patches) != 1 {
		t.Fatalf("patches = %+v, want one", patches)
	}
	value, ok := patches[0].Body["sharesOwned"]
	if !ok || value != 0.0 || len(patches[0].Body) != 1 {
		t.Errorf("PATCH body = %v, want exactly sharesOwned 0", patches[0].Body)
	}
	if !strings.Contains(prompt, "- shares owned: 750 → 0") {
		t.Errorf("confirmation should show 750 → 0:\n%s", prompt)
	}
}

func TestSetTerminalScenarioCreatesARowWhenTheTickerHasNone(t *testing.T) {
	f := newTerminalFake()
	var prompt string
	cs := connect(t, terminalWriteScopes, f.server(t).URL, confirmAndCapture(&prompt))

	text, isErr := callPilotTool(t, cs, "set_terminal_scenario", map[string]any{
		"ticker": "tsla", "terminalShareCount": 3500000000, "terminalMarketCap": 5000000000000,
		"valueWanted": 250000, "sharesOwned": 10,
	})
	if isErr {
		t.Fatalf("set_terminal_scenario failed: %s", text)
	}
	creates := f.callsWith(http.MethodPost)
	if len(creates) != 1 || creates[0].Path != "/v1/terminal-positions" {
		t.Fatalf("creates = %+v, want one POST /v1/terminal-positions", creates)
	}
	if !strings.HasPrefix(creates[0].IdempotencyKey, "mcp_") {
		t.Errorf("Idempotency-Key = %q, want an mcp_ key", creates[0].IdempotencyKey)
	}
	want := map[string]any{
		"ticker": "TSLA", "terminalShareCount": 3500000000.0, "terminalMarketCap": 5000000000000.0,
		"valueWanted": 250000.0, "sharesOwned": 10.0,
	}
	if len(creates[0].Body) != len(want) {
		t.Errorf("POST body = %v, want exactly %v", creates[0].Body, want)
	}
	for key, value := range want {
		if creates[0].Body[key] != value {
			t.Errorf("POST body %s = %v, want %v", key, creates[0].Body[key], value)
		}
	}
	if len(f.callsWith(http.MethodPatch)) != 0 {
		t.Error("a create must not patch anything")
	}
	for _, line := range []string{
		"Create a terminal scenario for TSLA:",
		"- terminal share count: 3500000000",
		"- terminal market cap: 5000000000000 USD",
		"- value wanted: 250000 USD",
		"- shares owned: 10",
		terminalDisclaimerText,
	} {
		if !strings.Contains(prompt, line) {
			t.Errorf("confirmation is missing %q:\n%s", line, prompt)
		}
	}
	if !strings.Contains(text, `"action": "created"`) {
		t.Errorf("result should say created:\n%s", text)
	}
}

func TestSetTerminalScenarioWillNotCreateWithoutTheThreeAssumptions(t *testing.T) {
	f := newTerminalFake()
	var prompt string
	cs := connect(t, terminalWriteScopes, f.server(t).URL, confirmAndCapture(&prompt))

	text, isErr := callPilotTool(t, cs, "set_terminal_scenario", map[string]any{"ticker": "TSLA", "valueWanted": 250000})
	if !isErr || !strings.Contains(text, "terminalShareCount, terminalMarketCap") || !strings.Contains(text, "do not invent them") {
		t.Errorf("got %q (error=%v), want an error naming the missing assumptions", text, isErr)
	}
	if prompt != "" {
		t.Errorf("the user was asked to confirm an impossible create: %q", prompt)
	}
	if f.writes() != 0 {
		t.Error("an incomplete create reached the backend")
	}
}

func TestSetTerminalScenarioRejectsImpossibleValuesBeforeAsking(t *testing.T) {
	cases := []struct {
		name string
		args map[string]any
		want string
	}{
		{"nothing to set", map[string]any{"ticker": "AMZN"}, "nothing to set"},
		{"zero market cap", map[string]any{"ticker": "AMZN", "terminalMarketCap": 0}, "terminalMarketCap must be greater than 0"},
		{"negative share count", map[string]any{"ticker": "AMZN", "terminalShareCount": -5}, "terminalShareCount must be greater than 0"},
		{"negative value wanted", map[string]any{"ticker": "AMZN", "valueWanted": -1}, "valueWanted must not be negative"},
		{"negative shares owned", map[string]any{"ticker": "AMZN", "sharesOwned": -2}, "sharesOwned must not be negative"},
		{"zero price", map[string]any{"ticker": "AMZN", "currentSharePrice": 0}, "currentSharePrice must be greater than 0"},
		{"not a ticker", map[string]any{"ticker": "$AMZN", "valueWanted": 1}, "not a valid ticker"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newTerminalFake()
			var prompt string
			cs := connect(t, terminalWriteScopes, f.server(t).URL, confirmAndCapture(&prompt))
			text, isErr := callPilotTool(t, cs, "set_terminal_scenario", tc.args)
			if !isErr || !strings.Contains(text, tc.want) {
				t.Errorf("got %q (error=%v), want %q", text, isErr, tc.want)
			}
			if prompt != "" || len(f.calls) != 0 {
				t.Errorf("rejected input still asked (%q) or called the backend (%+v)", prompt, f.calls)
			}
		})
	}
}

func TestSetTerminalScenarioDeclinedWritesNothing(t *testing.T) {
	f := newTerminalFake()
	f.rows["AMZN"] = []string{terminalRowJSON(terminalRowA, "AMZN", 0)}
	cs := connect(t, terminalWriteScopes, f.server(t).URL, declineElicit)

	text, isErr := callPilotTool(t, cs, "set_terminal_scenario", map[string]any{"ticker": "AMZN", "valueWanted": 2000000})
	if isErr || !strings.Contains(text, "not confirmed") {
		t.Errorf("got %q (error=%v), want a soft not-confirmed message", text, isErr)
	}
	if f.writes() != 0 {
		t.Error("a declined change reached the backend")
	}
}

func TestSetTerminalScenarioRefusesAClientThatCannotConfirm(t *testing.T) {
	f := newTerminalFake()
	f.rows["AMZN"] = []string{terminalRowJSON(terminalRowA, "AMZN", 0)}
	// No elicitation handler. server.go strips write tools from such sessions;
	// this harness registers them anyway, so this pins the handler's own guard.
	cs := connect(t, terminalWriteScopes, f.server(t).URL, nil)

	_, isErr := callPilotTool(t, cs, "set_terminal_scenario", map[string]any{"ticker": "AMZN", "valueWanted": 2000000})
	if !isErr {
		t.Error("a client without form elicitation must get an error")
	}
	if f.writes() != 0 {
		t.Error("an unconfirmable change reached the backend")
	}
}

func TestSetTerminalScenarioNeverPatchesAnotherTickersRow(t *testing.T) {
	f := newTerminalFake()
	f.ignoreFilter = true // the backend answers every row whatever ?ticker= says
	f.rows["AMZN"] = []string{terminalRowJSON(terminalRowA, "AMZN", 0)}
	var prompt string
	cs := connect(t, terminalWriteScopes, f.server(t).URL, confirmAndCapture(&prompt))

	text, isErr := callPilotTool(t, cs, "set_terminal_scenario", map[string]any{
		"ticker": "TSLA", "terminalShareCount": 3500000000, "terminalMarketCap": 5000000000000, "valueWanted": 250000,
	})
	if isErr {
		t.Fatalf("set_terminal_scenario failed: %s", text)
	}
	if len(f.callsWith(http.MethodPatch)) != 0 {
		t.Fatal("MCP patched AMZN's row while setting TSLA")
	}
	if creates := f.callsWith(http.MethodPost); len(creates) != 1 || creates[0].Body["ticker"] != "TSLA" {
		t.Errorf("creates = %+v, want one TSLA create", creates)
	}
}

func TestSetTerminalScenarioExplainsABackendRejection(t *testing.T) {
	f := newTerminalFake()
	f.rows["AMZN"] = []string{terminalRowJSON(terminalRowA, "AMZN", 0)}
	f.fail["PATCH /v1/terminal-positions/"+terminalRowA] = terminalFailure{
		http.StatusUnprocessableEntity, `{"error":true,"reason":"Ticker must be 1-12 letters, digits, dots or hyphens."}`,
	}
	cs := connect(t, terminalWriteScopes, f.server(t).URL, acceptElicit)

	text, isErr := callPilotTool(t, cs, "set_terminal_scenario", map[string]any{"ticker": "AMZN", "valueWanted": 5})
	if !isErr || !strings.Contains(text, "Norviq rejected this: Ticker must be 1-12 letters, digits, dots or hyphens.") {
		t.Errorf("got %q (error=%v), want the backend's reason", text, isErr)
	}
}
```

In `internal/tools/catalog_parity_test.go`, add this entry to `mcpToCatalog`, after `"delete_goal": "delete_goal",`:

```go
	"set_terminal_scenario":  "set_terminal_scenario",
```

Append to `internal/tools/catalog_parity_test.go`:

```go
// terminalActions are the backend catalog actions for terminal position sizing
// (norviq-backend docs/superpowers/plans/2026-10-09-terminal-contract.md). The
// write-only checks above cannot see a missing read tool, and these four are
// mirrored one-to-one by MCP tools of the same name, so both sides are pinned:
// the snapshot must carry them and MCP must expose them.
var terminalActions = []string{
	"get_terminal_position",
	"get_terminal_positions",
	"lookup_share_facts",
	"set_terminal_scenario",
}

func TestTerminalCatalogActionsHaveMCPTools(t *testing.T) {
	snap := loadCatalog(t)
	inCatalog := map[string]bool{}
	for _, action := range snap.Actions {
		inCatalog[action.Name] = true
	}

	backend, _ := fakeBackend(t)
	cs := connect(t, map[string]bool{"planning:read": true, "planning:write": true}, backend.URL, acceptElicit)
	listed, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	exposed := map[string]bool{}
	for _, tool := range listed.Tools {
		exposed[tool.Name] = true
	}

	for _, name := range terminalActions {
		if !inCatalog[name] {
			t.Errorf("%s is not in testdata/action-catalog.json; run make catalog-snapshot against a backend that serves the terminal actions", name)
		}
		if !exposed[name] {
			t.Errorf("%s is a contract action but MCP does not expose it", name)
		}
	}
}
```

Add `"context"` to `catalog_parity_test.go`'s imports, which currently are `encoding/json, os, sort, strings, testing, tools`.

In `internal/tools/tools_test.go`, in `TestEveryMutatingToolIsInTheWriteAllowlist`, change the last line of the scope list from:

```go
		"reports:read", "market:read", "portfolio:read", "insights:read", "tax:read",
```

to:

```go
		"reports:read", "market:read", "portfolio:read", "insights:read", "tax:read",
		"planning:read", "planning:write",
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `go test ./internal/tools -run 'SetTerminalScenario|TerminalCatalog|WriteToolIsMapped|DestructiveClassification|WriteAllowlist' -v`
Expected: FAIL. `set_terminal_scenario not exposed with planning:read and planning:write`, the call tests fail with an unknown tool, and `TestTerminalCatalogActionsHaveMCPTools` reports `set_terminal_scenario is a contract action but MCP does not expose it`. `TestEveryWriteToolIsMappedOrDeclaredMCPOnly` still passes, because the tool is not in `WriteToolNames()` yet.

- [ ] **Step 4: Write the implementation**

Create `internal/tools/terminal_scenario.go`:

```go
package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/FinancePlanner/norviq-mcp/internal/api"
	"github.com/FinancePlanner/norviq-mcp/internal/auth"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// setTerminalScenarioArgs is the contract's set_terminal_scenario input, field
// for field. Every number is a pointer so "not given" and 0 differ:
// sharesOwned 0 is a real answer (the user owns none, or sold out).
type setTerminalScenarioArgs struct {
	Ticker             string   `json:"ticker" jsonschema:"stock ticker, e.g. AMZN or BRK.B"`
	TerminalShareCount *float64 `json:"terminalShareCount,omitempty" jsonschema:"the user's assumed share count at the terminal date, as a plain number (11 billion is 11000000000)"`
	TerminalMarketCap  *float64 `json:"terminalMarketCap,omitempty" jsonschema:"the user's assumed market cap at the terminal date in the account currency, as a plain number (10 trillion is 10000000000000)"`
	ValueWanted        *float64 `json:"valueWanted,omitempty" jsonschema:"what the user wants the position to be worth at the terminal date, in the account currency"`
	SharesOwned        *float64 `json:"sharesOwned,omitempty" jsonschema:"shares the user owns today; 0 is valid"`
	SharesOutstanding  *float64 `json:"sharesOutstanding,omitempty" jsonschema:"the company's shares outstanding today, for reference"`
	CurrentSharePrice  *float64 `json:"currentSharePrice,omitempty" jsonschema:"today's share price in the account currency; Norviq uses it for capitalAtTodayPrice"`
}

// terminalField is one numeric input, in the order confirmations list them.
type terminalField struct {
	name     string // the contract's argument name
	label    string // what the confirmation calls it
	value    *float64
	money    bool // shown with the account currency
	positive bool // must be > 0; otherwise must be >= 0
	current  func(api.TerminalPosition) *float64
}

func (a setTerminalScenarioArgs) fields() []terminalField {
	return []terminalField{
		{
			name: "terminalShareCount", label: "terminal share count", value: a.TerminalShareCount, positive: true,
			current: func(r api.TerminalPosition) *float64 { return &r.TerminalShareCount },
		},
		{
			name: "terminalMarketCap", label: "terminal market cap", value: a.TerminalMarketCap, money: true, positive: true,
			current: func(r api.TerminalPosition) *float64 { return &r.TerminalMarketCap },
		},
		{
			name: "valueWanted", label: "value wanted", value: a.ValueWanted, money: true,
			current: func(r api.TerminalPosition) *float64 { return &r.ValueWanted },
		},
		{
			name: "sharesOwned", label: "shares owned", value: a.SharesOwned,
			current: func(r api.TerminalPosition) *float64 { return &r.SharesOwned },
		},
		{
			name: "sharesOutstanding", label: "shares outstanding today", value: a.SharesOutstanding, positive: true,
			current: func(r api.TerminalPosition) *float64 { return r.SharesOutstanding },
		},
		{
			name: "currentSharePrice", label: "today's share price", value: a.CurrentSharePrice, money: true, positive: true,
			current: func(r api.TerminalPosition) *float64 { return r.CurrentSharePrice },
		},
	}
}

// validate rejects input before anything is read or asked. The backend stores
// a share count or market cap of 0 so a half-typed web cell still saves, but an
// assistant writing 0 is always a mistake, so MCP refuses it.
func (a setTerminalScenarioArgs) validate() error {
	given := 0
	for _, f := range a.fields() {
		if f.value == nil {
			continue
		}
		given++
		if f.positive && *f.value <= 0 {
			return fmt.Errorf("%s must be greater than 0", f.name)
		}
		if *f.value < 0 {
			return fmt.Errorf("%s must not be negative", f.name)
		}
	}
	if given == 0 {
		return errors.New("nothing to set: give at least one of terminalShareCount, terminalMarketCap, valueWanted, sharesOwned, sharesOutstanding or currentSharePrice")
	}
	return nil
}

func (a setTerminalScenarioArgs) missingForCreate() []string {
	var missing []string
	if a.TerminalShareCount == nil {
		missing = append(missing, "terminalShareCount")
	}
	if a.TerminalMarketCap == nil {
		missing = append(missing, "terminalMarketCap")
	}
	if a.ValueWanted == nil {
		missing = append(missing, "valueWanted")
	}
	return missing
}

// show prints the exact value being written: no rounding, no 10T shorthand.
func (f terminalField) show(v float64, currency string) string {
	text := strconv.FormatFloat(v, 'f', -1, 64)
	if f.money && currency != "" {
		text += " " + currency
	}
	return text
}

const terminalRecalcNote = "Norviq recalculates the terminal share price and shares needed from these. " + terminalDisclaimer

func describeTerminalUpdate(ticker string, row api.TerminalPosition, rowCount int, currency string, args setTerminalScenarioArgs) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Update the terminal scenario for %s", ticker)
	if rowCount > 1 {
		fmt.Fprintf(&b, " (the first of %d %s rows)", rowCount, ticker)
	}
	b.WriteString(":")
	for _, f := range args.fields() {
		if f.value == nil {
			continue
		}
		from := "empty"
		if current := f.current(row); current != nil {
			from = f.show(*current, currency)
		}
		fmt.Fprintf(&b, "\n- %s: %s → %s", f.label, from, f.show(*f.value, currency))
	}
	b.WriteString("\n" + terminalRecalcNote)
	return b.String()
}

func describeTerminalCreate(ticker, currency string, args setTerminalScenarioArgs) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Create a terminal scenario for %s:", ticker)
	for _, f := range args.fields() {
		if f.value == nil {
			continue
		}
		fmt.Fprintf(&b, "\n- %s: %s", f.label, f.show(*f.value, currency))
	}
	b.WriteString("\n" + terminalRecalcNote)
	return b.String()
}

type terminalWriteView struct {
	Action     string               `json:"action"` // "updated" or "created"
	Currency   string               `json:"currency"`
	Position   api.TerminalPosition `json:"position"`
	Disclaimer string               `json:"disclaimer"`
}

func registerSetTerminalScenario(s *mcp.Server, client *api.Client, p *auth.Principal) {
	mcp.AddTool(s, &mcp.Tool{
		Name: "set_terminal_scenario",
		Description: "Set the user's terminal scenario for one ticker. If the ticker already has a row, this updates the first one " +
			"in the user's sort order and changes only the fields given; otherwise it creates a row, which needs terminalShareCount, " +
			"terminalMarketCap and valueWanted. Every call shows the user the exact values in an MCP confirmation form, and Norviq " +
			"writes nothing unless they confirm. Give numbers as plain amounts in the account currency or plain share counts: " +
			"10 trillion is 10000000000000, not 10T. The answer includes the values Norviq derived." +
			terminalNotice,
		Annotations: &mcp.ToolAnnotations{DestructiveHint: ptrBool(true)},
	}, func(ctx context.Context, req *mcp.CallToolRequest, args setTerminalScenarioArgs) (*mcp.CallToolResult, any, error) {
		ticker, err := normalizeTicker(args.Ticker)
		if err != nil {
			return textResult(err.Error(), true), nil, nil
		}
		if invalid := args.validate(); invalid != nil {
			return textResult(invalid.Error(), true), nil, nil
		}

		list, err := client.ListTerminalPositions(ctx, ticker)
		if err != nil {
			return terminalFail(err), nil, nil
		}
		rows := rowsForTicker(list.Positions, ticker)
		row, exists := firstBySortOrder(rows)

		var message string
		if exists {
			message = describeTerminalUpdate(ticker, row, len(rows), list.Currency, args)
		} else {
			if missing := args.missingForCreate(); len(missing) > 0 {
				return textResult(fmt.Sprintf(
					"%s has no terminal scenario yet, so this would create one, and creating needs %s. Ask the user for them; do not invent them.",
					ticker, strings.Join(missing, ", "),
				), true), nil, nil
			}
			message = describeTerminalCreate(ticker, list.Currency, args)
		}

		confirmed, pending, err := confirmMutation(req, message)
		if err != nil {
			return fail(err), nil, nil
		}
		if pending != nil {
			return pending, nil, nil
		}
		if !confirmed {
			return textResult("The terminal scenario change was not confirmed. Nothing was written.", false), nil, nil
		}

		var written *api.TerminalPosition
		action := "updated"
		if exists {
			written, err = client.UpdateTerminalPosition(ctx, row.ID, api.TerminalPositionUpdateRequest{
				SharesOutstanding:  args.SharesOutstanding,
				TerminalShareCount: args.TerminalShareCount,
				TerminalMarketCap:  args.TerminalMarketCap,
				ValueWanted:        args.ValueWanted,
				SharesOwned:        args.SharesOwned,
				CurrentSharePrice:  args.CurrentSharePrice,
			})
		} else {
			action = "created"
			keyArgs := args
			keyArgs.Ticker = ticker
			written, err = client.CreateTerminalPosition(ctx, api.TerminalPositionCreateRequest{
				Ticker:             ticker,
				SharesOutstanding:  args.SharesOutstanding,
				TerminalShareCount: *args.TerminalShareCount,
				TerminalMarketCap:  *args.TerminalMarketCap,
				ValueWanted:        *args.ValueWanted,
				SharesOwned:        args.SharesOwned,
				CurrentSharePrice:  args.CurrentSharePrice,
			}, idempotencyKey(p.UserID, keyArgs))
		}
		if err != nil {
			return terminalFail(err), nil, nil
		}
		body, _ := json.MarshalIndent(terminalWriteView{
			Action: action, Currency: list.Currency, Position: *written, Disclaimer: terminalDisclaimer,
		}, "", "  ")
		return textResult(string(body), false), nil, nil
	})
}
```

In `internal/tools/terminal_positions.go`, at the end of `registerTerminalPositions`, after `registerShareFacts(s, client)`, add:

```go
	// It reads the ticker's rows before writing, and the backend does not treat
	// planning:write as implying planning:read, so it needs both.
	if p.Scopes["planning:write"] {
		registerSetTerminalScenario(s, client, p)
	}
```

In `internal/tools/confirmation.go`, append to `writeToolNames` after `"delete_research_note",`:

```go
	"set_terminal_scenario",
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `go test ./internal/tools -run 'SetTerminalScenario|TerminalCatalog|WriteToolIsMapped|DestructiveClassification|WriteAllowlist' -v`
Expected: PASS. That covers the 10 `SetTerminalScenario` tests (`RejectsImpossibleValuesBeforeAsking` has 7 subtests), `TestTerminalCatalogActionsHaveMCPTools`, both existing parity tests, and `TestEveryMutatingToolIsInTheWriteAllowlist`.

Then run: `go test ./internal/... 2>&1 | grep -E '^(--- FAIL|ok|FAIL)'`
Expected: only `--- FAIL: TestGetNewsDefaultUsesTrackedFeed`.

- [ ] **Step 6: Commit**

```bash
go tool gofumpt -w internal/tools
git add internal/tools/terminal_scenario.go internal/tools/terminal_scenario_test.go \
  internal/tools/terminal_positions.go internal/tools/confirmation.go \
  internal/tools/catalog_parity_test.go internal/tools/tools_test.go \
  internal/tools/testdata/action-catalog.json
git commit -m "feat(terminal): set_terminal_scenario confirmed write and catalog parity"
```

---

### Task 5: README, full verification, and the user-approved ship

**Files:**
- Modify: `README.md:52` (tools table), `README.md:75` (add a paragraph after the pilot paragraph)

**Interfaces:**
- Consumes: everything above. Produces nothing new in code.

- [ ] **Step 1: Document the tools**

In `README.md`, replace the line

```markdown
| `goals:read` / `goals:write` | `list_goals`, goal CRUD |
```

with

```markdown
| `goals:read` / `goals:write` | `list_goals`, goal CRUD |
| `planning:read` | `project_investment_growth`, `check_retirement_readiness`, `get_terminal_positions`, `get_terminal_position`, `lookup_share_facts` (Pro) |
| `planning:read` + `planning:write` | `set_terminal_scenario` |
```

After the paragraph that starts `The pilot tools are read-only views of pilot follows` (line 75), add a blank line and:

```markdown
The terminal position tools are planning math, not advice. Norviq computes every derived value on the server (`terminalSharePrice = terminalMarketCap / terminalShareCount`, `sharesNeeded = valueWanted × terminalShareCount / terminalMarketCap`, plus progress, the gap at terminal prices and the capital at today's price). The tools return those values and never compute them. `set_terminal_scenario` updates the first row for a ticker by sort order, or creates one when there is none, and always asks for confirmation showing the exact values. `lookup_share_facts` runs Norviq's own AI web lookup (Pro, rate-limited) for shares outstanding and today's price, and returns a sourced suggestion without saving it. Every answer carries the disclaimer "Terminal prices are your assumptions, not forecasts. Not financial advice."
```

- [ ] **Step 2: Run the full suite, format and lint**

```bash
go tool gofumpt -l .
golangci-lint run
go build ./...
go test ./... 2>&1 | grep -E '^(--- FAIL|FAIL|ok)'
```

Expected: `gofumpt -l` prints nothing. `golangci-lint run` reports `0 issues`. The build succeeds. The test run shows `--- FAIL: TestGetNewsDefaultUsesTrackedFeed` as the only failure (baseline), and every other package is `ok`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: terminal position sizing tools"
```

- [ ] **Step 4: STOP and ask the user before pushing**

Show the user `git log --oneline origin/main..HEAD` and `git diff --stat origin/main`. Tell them:

- Merging this PR to `main` **auto-deploys to staging**. `deploy.yml` builds the image and commits the tag to `LuminaVault/LuminaVaultInfra` `apps/norviq/mcp/values-staging.yaml`, and ArgoCD syncs `norviq-staging`.
- Production does **not** change on merge. It needs `gh workflow run promote-norviq.yml -R LuminaVault/LuminaVaultInfra -f service=mcp` (or `service=all`; `both` is api + web only), and then merging the promote PR it opens.
- Release gate (spec, "Order and release gates"): promote MCP only **after** production serves `/v1/terminal-positions` and `/v1/actions/catalog` lists the four actions. Otherwise every terminal tool answers with errmap's "not found in your norviq account".
- CI on this PR will be red on `TestGetNewsDefaultUsesTrackedFeed`, the same as `main` today. That failure is not from this branch.

Push only on an explicit yes:

```bash
git push -u origin feat/terminal-positions
gh pr create --title "feat(terminal): terminal position sizing MCP tools" \
  --body "Adds get_terminal_positions, get_terminal_position, lookup_share_facts (Pro) and set_terminal_scenario (confirmed write) per norviq-backend docs/superpowers/plans/2026-10-09-terminal-contract.md. Refreshes the action-catalog snapshot. Merge deploys staging only; production needs promote-norviq.yml -f service=mcp after the backend is in production."
```

- [ ] **Step 5: Manual check on staging after the user merges (spec "Verification": MCP)**

Staging MCP has no ingress, so port-forward it. Use a staging PAT that holds `planning:read planning:write`, and add it as a separate MCP server in a client that supports form elicitation, such as Claude Code:

```bash
KUBECONFIG=~/.kube/maat.yaml kubectl -n norviq-staging port-forward svc/mcp 18087:8087
claude mcp add --transport http norviq-staging http://localhost:18087/mcp --header "Authorization: Bearer $STAGING_PAT"
```

Ask the client to "set my AMZN terminal scenario: 11 billion shares, 10 trillion market cap, I want 1 million". Expected:
- A confirmation form lists `terminal share count: 11000000000`, `terminal market cap: 10000000000000 USD`, `value wanted: 1000000 USD`.
- After you accept, the answer shows `"terminalSharePrice": 909.0909…` and `"sharesNeeded": 1100` from Norviq.
- `get_terminal_position AMZN` returns the same row.
- Declining writes nothing.

Remove the server afterwards with `claude mcp remove norviq-staging`.
