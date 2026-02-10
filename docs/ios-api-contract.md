# iOS API Contract (Minimal)

Base URL
- `https://api.yourdomain.com`

Auth
- Header: `Authorization: Bearer <token>`
- Token issued by `POST /auth/register` or `POST /auth/login`

Date format
- ISO-8601 string, example: `2026-02-03` or `2026-02-03T14:30:00Z`

Endpoints and payloads

`POST /auth/register`
Request
```json
{
  "email": "user@example.com",
  "password": "secret"
}
```
Response
```json
{
  "token": "jwt-token",
  "userId": "uuid",
  "expiresIn": 604800
}
```

`POST /auth/login`
Request
```json
{
  "email": "user@example.com",
  "password": "secret"
}
```
Response
```json
{
  "token": "jwt-token",
  "userId": "uuid",
  "expiresIn": 604800
}
```

`GET /stocks`
Response
```json
[
  {
    "id": "uuid",
    "symbol": "AAPL",
    "shares": 10,
    "buyPrice": 150.25,
    "buyDate": "2026-01-10",
    "notes": "Starter position"
  }
]
```

`POST /stocks`
Request
```json
{
  "symbol": "AAPL",
  "shares": 10,
  "buyPrice": 150.25,
  "buyDate": "2026-01-10",
  "notes": "Starter position"
}
```
Response
```json
{
  "id": "uuid",
  "symbol": "AAPL",
  "shares": 10,
  "buyPrice": 150.25,
  "buyDate": "2026-01-10",
  "notes": "Starter position"
}
```

`GET /watchlist`
Response
```json
[
  {
    "id": "uuid",
    "symbol": "MSFT"
  }
]
```

`POST /watchlist`
Request
```json
{
  "symbol": "MSFT"
}
```
Response
```json
{
  "id": "uuid",
  "symbol": "MSFT"
}
```

`GET /research`
Response
```json
[
  {
    "id": "uuid",
    "symbol": "AAPL",
    "title": "AI upside",
    "thesis": "Revenue growth from services",
    "risks": "Margin pressure",
    "catalysts": "Earnings",
    "referenceLinks": ["https://example.com"]
  }
]
```

`POST /research`
Request
```json
{
  "symbol": "AAPL",
  "title": "AI upside",
  "thesis": "Revenue growth from services",
  "risks": "Margin pressure",
  "catalysts": "Earnings",
  "referenceLinks": ["https://example.com"]
}
```
Response
```json
{
  "id": "uuid",
  "symbol": "AAPL",
  "title": "AI upside",
  "thesis": "Revenue growth from services",
  "risks": "Margin pressure",
  "catalysts": "Earnings",
  "referenceLinks": ["https://example.com"]
}
```

`GET /targets`
Response
```json
[
  {
    "id": "uuid",
    "symbol": "AAPL",
    "scenario": "bull",
    "targetPrice": 220,
    "targetDate": "2026-12-31",
    "rationale": "Multiple expansion"
  }
]
```

`POST /targets`
Request
```json
{
  "symbol": "AAPL",
  "scenario": "bull",
  "targetPrice": 220,
  "targetDate": "2026-12-31",
  "rationale": "Multiple expansion"
}
```
Response
```json
{
  "id": "uuid",
  "symbol": "AAPL",
  "scenario": "bull",
  "targetPrice": 220,
  "targetDate": "2026-12-31",
  "rationale": "Multiple expansion"
}
```

`GET /quote/:symbol`
Response
```json
{
  "symbol": "AAPL",
  "price": 196.45,
  "currency": "USD",
  "asOf": "2026-02-03T14:30:00Z"
}
```

`GET /history/:symbol`
Response
```json
{
  "symbol": "AAPL",
  "currency": "USD",
  "bars": [
    {
      "date": "2026-02-03",
      "open": 195,
      "high": 198,
      "low": 194,
      "close": 196.45,
      "volume": 1200000
    }
  ]
}
```

`GET /search?q=`
Response
```json
[
  {
    "symbol": "AAPL",
    "name": "Apple Inc.",
    "exchange": "NASDAQ",
    "currency": "USD",
    "conid": "265598"
  }
]
```

`GET /fx?pair=EURUSD`
Response
```json
{
  "base": "EUR",
  "quote": "USD",
  "rate": 1.08,
  "date": "2026-02-03"
}
```

`GET /transactions`
Response
```json
[
  {
    "id": "uuid",
    "accountId": "uuid",
    "instrumentId": "uuid",
    "type": "buy",
    "quantity": 10,
    "price": 150.25,
    "currency": "USD",
    "tradeDate": "2026-01-10",
    "settleDate": "2026-01-12",
    "fees": 1.25
  }
]
```

`GET /lots`
Response
```json
[
  {
    "id": "uuid",
    "accountId": "uuid",
    "instrumentId": "uuid",
    "openDate": "2026-01-10",
    "closeDate": null,
    "openQuantity": 10,
    "remainingQuantity": 10,
    "openPrice": 150.25,
    "currency": "USD",
    "realizedPnl": null,
    "status": "open"
  }
]
```

`GET /pnl`
Response
```json
{
  "baseCurrency": "USD",
  "items": [
    {
      "symbol": "AAPL",
      "currency": "USD",
      "realizedPnl": 0,
      "unrealizedPnl": 12.4
    }
  ]
}
```

`GET /portfolio/summary`
Response
```json
{
  "baseCurrency": "USD",
  "totalValue": 12000.5,
  "totalCost": 10000,
  "unrealizedPnl": 2000.5,
  "realizedPnl": 0,
  "allocation": [
    {
      "symbol": "AAPL",
      "value": 12000.5,
      "currency": "USD"
    }
  ]
}
```

`GET /portfolio/performance`
Response
```json
{
  "baseCurrency": "USD",
  "points": [
    { "date": "2026-01-01", "value": 10000 },
    { "date": "2026-02-03", "value": 12000.5 }
  ]
}
```

`GET /brokers`
Response
```json
[
  { "id": "uuid", "provider": "ibkr", "status": "connected" }
]
```

`GET /brokers/holdings`
Response
```json
[
  { "symbol": "AAPL", "quantity": 10, "currency": "USD" }
]
```

`POST /brokers/ibkr/sync`
Response
```json
{ "runId": "uuid", "status": "accepted" }
```
