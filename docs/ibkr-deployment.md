# IBKR Gateway Docker Integration - Deployment Guide

## Overview

This guide covers deploying the Interactive Brokers (IBKR) Gateway Docker integration for automated portfolio synchronization.

## Architecture

```
┌─────────────────┐         ┌──────────────────┐         ┌─────────────────┐
│   iOS App       │◄───────►│  Backend API     │◄───────►│  IB Gateway     │
│                 │  HTTPS  │  (Vapor)         │  HTTP   │  (Docker)       │
└─────────────────┘         └──────────────────┘         └─────────────────┘
                                     │                            │
                                     ▼                            ▼
                            ┌──────────────────┐         ┌─────────────────┐
                            │   PostgreSQL     │         │  IBKR API       │
                            │   (User data)    │         │  (Live data)    │
                            └──────────────────┘         └─────────────────┘
```

## Prerequisites

- Docker and Docker Compose installed
- Interactive Brokers account (paper or live)
- IBKR Gateway credentials
- PostgreSQL database

## Environment Variables

### Required Variables

```bash
# IBKR Gateway Configuration
IBKR_USERNAME=your_ibkr_username
IBKR_PASSWORD=your_ibkr_password
IBKR_MODE=paper  # or 'live' for production
IBKR_API_BASE_URL=http://ib-gateway:5000/v1/api

# Optional: VNC access for debugging
IBKR_VNC_PASSWORD=your_vnc_password
```

### Optional Variables

```bash
# Gateway Configuration
IBKR_GATEWAY_HOST=ib-gateway
IBKR_GATEWAY_PORT=5000
TZ=America/New_York  # Your timezone
```

## Deployment Steps

### 1. Configure Environment

Create or update `.env` file:

```bash
cd StockPlanBackend
cp .env.example .env
# Edit .env with your IBKR credentials
```

### 2. Start Services

```bash
# Start all services including IB Gateway
docker compose up -d

# Check Gateway health
docker compose logs ib-gateway

# Verify Gateway is responding
curl http://localhost:5000/v1/api/iserver/auth/status
```

### 3. Run Database Migrations

```bash
docker compose run --rm migrate
```

### 4. Verify Sync Job

Check logs for the scheduled sync job:

```bash
docker compose logs app | grep ibkr_sync_job
```

Expected output:
```
ibkr_sync_job starting
ibkr_sync_job next_run=2026-04-25 06:00:00 delay_seconds=68400
```

## API Endpoints

### Connect IBKR Account

**POST** `/v1/brokers/ibkr/connect/start`

Request:
```json
{
  "redirectURI": "norviqa://oauth/callback",
  "portfolioListId": "optional-uuid"
}
```

Response:
```json
{
  "flowId": "uuid",
  "authorizationURL": "https://api.example.com/v1/auth/brokers/ibkr/callback?flowId=...&state=...",
  "expiresIn": 600
}
```

### Manual Sync

**POST** `/v1/brokers/ibkr/sync`

Response:
```json
{
  "runId": "uuid",
  "status": "completed",
  "inserted": 5,
  "updated": 10,
  "removed": 2
}
```

### Check Sync Status

**GET** `/v1/brokers/ibkr/sync/status`

Response:
```json
{
  "status": "connected",
  "lastSyncedAt": "2026-04-24T10:00:00Z",
  "isStale": false,
  "statusDetail": null
}
```

### Disconnect IBKR

**DELETE** `/v1/brokers/ibkr/connection`

## Synced Data

The integration syncs the following data:

1. **Positions** - Current holdings with quantities and average costs
2. **Transactions** - Trade history (BUY, SELL, DIVIDEND, etc.)
3. **Cash Balances** - Multi-currency cash positions
4. **Dividends** - Dividend payments extracted from transactions

## Scheduled Sync

- **Frequency**: Daily at 6:00 AM server time
- **Scope**: All active IBKR connections (status=connected)
- **Idempotency**: Uses external_id to prevent duplicates
- **Error Handling**: Failed syncs update connection status to "error"

## Monitoring

### Health Checks

```bash
# Check Gateway health
curl http://localhost:5000/v1/api/iserver/auth/status

# Check backend health
curl http://localhost:8080/health

# Check database connection
docker compose exec db psql -U stockplan_user -d stockplan_dev -c "SELECT 1"
```

### Logs

```bash
# Gateway logs
docker compose logs -f ib-gateway

# Backend logs
docker compose logs -f app

# Sync job logs
docker compose logs app | grep ibkr_sync_job
```

### Metrics

Monitor these metrics:
- Sync success/failure rate
- Sync duration
- Number of records synced (inserted/updated/removed)
- Gateway session health

## Troubleshooting

### Gateway Not Starting

**Symptom**: Gateway container exits immediately

**Solution**:
1. Check credentials in `.env`
2. Verify IBKR account is active
3. Check Gateway logs: `docker compose logs ib-gateway`

### Authentication Failures

**Symptom**: "IBKR did not return any accounts"

**Solution**:
1. Verify credentials are correct
2. Check if 2FA is required (set TWOFA_TIMEOUT_ACTION=restart)
3. Restart Gateway: `docker compose restart ib-gateway`

### Sync Failures

**Symptom**: Connection status shows "error"

**Solution**:
1. Check sync status endpoint for statusDetail
2. Verify Gateway is running: `docker compose ps ib-gateway`
3. Check backend logs for detailed error messages
4. Manually trigger sync to test: `POST /v1/brokers/ibkr/sync`

### Stale Data

**Symptom**: isStale=true in sync status

**Solution**:
1. Check if scheduled job is running
2. Verify connection status is "connected"
3. Manually trigger sync
4. Check for errors in job logs

## Security Considerations

### Credentials

- Store IBKR credentials in environment variables, never in code
- Use Docker secrets in production
- Rotate credentials regularly

### Network

- Gateway ports (4001, 4002) are bound to localhost only
- Use HTTPS for all external API calls
- Consider VPN for production deployments

### API Access

- All endpoints require authentication
- Sync endpoint requires premium subscription
- Rate limiting is enforced

## Production Checklist

- [ ] IBKR credentials configured
- [ ] Database migrations applied
- [ ] Gateway health check passing
- [ ] Scheduled sync job running
- [ ] Monitoring and alerting configured
- [ ] Backup strategy in place
- [ ] SSL/TLS certificates configured
- [ ] Firewall rules configured
- [ ] Log aggregation configured

## Support

For issues or questions:
1. Check logs: `docker compose logs`
2. Review troubleshooting section above
3. Check IBKR Gateway documentation: https://github.com/gnzsnz/ib-gateway-docker
4. Contact support with relevant log excerpts

## References

- [IB Gateway Docker](https://github.com/gnzsnz/ib-gateway-docker)
- [IBKR Web API Documentation](https://ibkrcampus.com/campus/ibkr-api-page/webapi-doc/)
- [IBC Documentation](https://github.com/IbcAlpha/IBC)
