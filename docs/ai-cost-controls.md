# In-app AI cost controls (ops)

Norviq pays LLM usage for **in-app** chat, insight cards, and proactive tips.
MCP is BYO-LLM — users pay Claude/Cursor/ChatGPT; see MCP README.

## Gates (already in code)

| Control | Where | Default |
|---------|--------|---------|
| `AI_ENABLED` | All in-app LLM routes + tips job | `true` |
| `AI_PROACTIVE_TIPS_ENABLED` | Tips background job only | `true` |
| `AI_DAILY_LIMIT` | Redis day-bucket on `/v1/ai/chat` + `/v1/ai/insights/*` | `50` |
| `AI_FREE_MONTHLY_LIMIT` | Free users on `/v1/ai/assistant/*` | `5` |
| Route rate limit | `RateLimitMiddleware` 20/min `ratelimit:ai` | 20/min |
| Pro entitlement | `requirePremium(.aiInsights)` on chat + insights | Pro/trial |
| Free monthly | `AIAssistantUsage` month counter | 5 turns |
| Tips | Pro only + user preference + meaningful-spend heuristic | — |
| Empty API key | `DisabledOpenAIChatClient` | no spend |

## Kill switch

```bash
AI_ENABLED=false
```

Returns `503` on chat / insights / assistant turns. Tips job no-ops.

Tips only:

```bash
AI_PROACTIVE_TIPS_ENABLED=false
```

## Cheaper models

| Workload | Env | OpenAI default | OpenRouter default |
|----------|-----|----------------|--------------------|
| Chat | `AI_CHAT_MODEL` / `AI_MODEL` | `gpt-5.6-terra` | `anthropic/claude-sonnet-4.6` |
| Tips | `AI_TIPS_MODEL` | `gpt-5.6-luna` | `google/gemini-3.5-flash` |

Prefer flash/luna (or DeepSeek) for tips; keep stronger chat model only if quality requires it.

## Production checklist

1. Set `AI_PROVIDER` + key (`OPENAI_API_KEY` or `OPENROUTER_API_KEY`).
2. Set `AI_DAILY_LIMIT` (start ~20–50 depending on Pro volume).
3. Confirm Redis up — daily cap fails closed in production without Redis.
4. Keep `AI_ENABLED=true` unless emergency stop.
5. Monitor provider invoices + `ai_daily:*` Redis keys / 429 responses.
