# IBKR Integration Troubleshooting Guide

## Common Issues and Solutions

### 1. Gateway Connection Issues

#### Issue: "IBKR Gateway is not responding"

**Symptoms:**
- Sync fails with connection timeout
- Health check returns 503
- Gateway container is not running

**Diagnosis:**
```bash
# Check if Gateway container is running
docker compose ps ib-gateway

# Check Gateway logs
docker compose logs ib-gateway --tail=100

# Test Gateway endpoint
curl http://localhost:5000/v1/api/iserver/auth/status
```

**Solutions:**

1. **Gateway not started:**
   ```bash
   docker compose up -d ib-gateway
   ```

2. **Gateway crashed:**
   ```bash
   docker compose restart ib-gateway
   docker compose logs ib-gateway
   ```

3. **Wrong credentials:**
   - Verify `IBKR_USERNAME` and `IBKR_PASSWORD` in `.env`
   - Check IBKR account is active
   - Ensure paper/live mode matches account type

4. **Network issues:**
   ```bash
   # Test from backend container
   docker compose exec app curl http://ib-gateway:5000/v1/api/iserver/auth/status
   ```

---

### 2. Authentication Failures

#### Issue: "IBKR did not return any accounts"

**Symptoms:**
- OAuth callback fails
- Sync returns empty account list
- Connection status shows "error"

**Diagnosis:**
```bash
# Check Gateway authentication status
curl http://localhost:5000/v1/api/iserver/auth/status

# Check Gateway accounts endpoint
curl http://localhost:5000/v1/api/portfolio/accounts
```

**Solutions:**

1. **Session expired:**
   - Gateway sessions expire after inactivity
   - Restart Gateway to re-authenticate:
     ```bash
     docker compose restart ib-gateway
     ```

2. **2FA required:**
   - Set `TWOFA_TIMEOUT_ACTION=restart` in `.env`
   - Configure `TWOFA_DEVICE` if using specific device
   - Check Gateway logs for 2FA prompts

3. **Wrong account type:**
   - Verify `IBKR_MODE=paper` or `IBKR_MODE=live` matches your account
   - Paper accounts cannot access live data and vice versa

---

### 3. Sync Failures

#### Issue: "Sync completed with errors"

**Symptoms:**
- Connection status shows "error"
- statusDetail contains error message
- Some data missing after sync

**Diagnosis:**
```bash
# Check sync status
curl -H "Authorization: Bearer YOUR_TOKEN" \
  http://localhost:8080/v1/brokers/ibkr/sync/status

# Check backend logs
docker compose logs app | grep ibkr

# Check for database errors
docker compose logs db | grep ERROR
```

**Solutions:**

1. **Instrument not found:**
   - Symbol lookup failed
   - Check market data provider is configured
   - Verify symbol exists in market data API

2. **Transaction parsing errors:**
   - IBKR API returned unexpected format
   - Check Gateway version compatibility
   - Review transaction payload in logs

3. **Database constraint violations:**
   - Duplicate external_id (should not happen with idempotency)
   - Check database migrations are up to date:
     ```bash
     docker compose run --rm migrate
     ```

---

### 4. Stale Data

#### Issue: "isStale=true in sync status"

**Symptoms:**
- Last sync was >24 hours ago
- Data not updating
- Scheduled job not running

**Diagnosis:**
```bash
# Check if sync job is running
docker compose logs app | grep ibkr_sync_job

# Check connection status
curl -H "Authorization: Bearer YOUR_TOKEN" \
  http://localhost:8080/v1/brokers/ibkr/sync/status

# Check for job errors
docker compose logs app | grep "ibkr_sync_job error"
```

**Solutions:**

1. **Job not scheduled:**
   - Verify `IBKRSyncJob` is registered in `configure.swift`
   - Restart backend:
     ```bash
     docker compose restart app
     ```

2. **Job failing silently:**
   - Check logs for errors
   - Manually trigger sync to test:
     ```bash
     curl -X POST -H "Authorization: Bearer YOUR_TOKEN" \
       http://localhost:8080/v1/brokers/ibkr/sync
     ```

3. **Connection status not "connected":**
   - Reconnect IBKR account via OAuth flow
   - Check connection status in database:
     ```sql
     SELECT * FROM broker_connections WHERE provider = 'ibkr';
     ```

---

### 5. Missing Data

#### Issue: "Some positions/transactions not syncing"

**Symptoms:**
- Position count doesn't match IBKR
- Recent transactions missing
- Dividends not appearing

**Diagnosis:**
```bash
# Check sync response
curl -X POST -H "Authorization: Bearer YOUR_TOKEN" \
  http://localhost:8080/v1/brokers/ibkr/sync

# Check database records
docker compose exec db psql -U stockplan_user -d stockplan_dev \
  -c "SELECT COUNT(*) FROM transactions WHERE account_id = 'YOUR_ACCOUNT_ID';"
```

**Solutions:**

1. **Incremental sync window:**
   - Sync only fetches data since last sync
   - For full resync, disconnect and reconnect account

2. **Symbol filtering:**
   - Check if symbols are being filtered out
   - Review `upsertPosition` logic for filters

3. **API pagination:**
   - IBKR API may paginate large result sets
   - Check if pagination is handled correctly

---

### 6. Performance Issues

#### Issue: "Sync takes too long"

**Symptoms:**
- Sync duration >5 minutes
- Gateway timeouts
- High CPU/memory usage

**Diagnosis:**
```bash
# Check resource usage
docker stats

# Check sync duration in logs
docker compose logs app | grep "ibkr_sync_job completed"

# Check database query performance
docker compose exec db psql -U stockplan_user -d stockplan_dev \
  -c "SELECT * FROM pg_stat_activity WHERE state = 'active';"
```

**Solutions:**

1. **Too many positions:**
   - Consider batching position updates
   - Add database indexes on frequently queried columns

2. **Gateway rate limiting:**
   - Add delays between API calls
   - Reduce retry attempts

3. **Database locks:**
   - Use transactions efficiently
   - Avoid long-running queries during sync

---

### 7. VNC Access Issues

#### Issue: "Cannot connect to VNC"

**Symptoms:**
- VNC client cannot connect
- Port 5900 not accessible
- Authentication fails

**Diagnosis:**
```bash
# Check if VNC port is exposed
docker compose ps ib-gateway

# Test VNC port
nc -zv localhost 5900
```

**Solutions:**

1. **VNC not enabled:**
   - Set `IBKR_VNC_PASSWORD` in `.env`
   - Restart Gateway:
     ```bash
     docker compose restart ib-gateway
     ```

2. **Port not exposed:**
   - Verify `docker-compose.yml` exposes port 5900
   - Check firewall rules

3. **Wrong password:**
   - Verify `IBKR_VNC_PASSWORD` matches VNC client password
   - Password must be set for VNC to start

---

## Debugging Tips

### Enable Verbose Logging

Add to `.env`:
```bash
LOG_LEVEL=debug
```

Restart backend:
```bash
docker compose restart app
```

### Inspect Gateway State

```bash
# Enter Gateway container
docker compose exec ib-gateway /bin/bash

# Check IBC logs
cat /home/ibgateway/ibc/logs/ibc-*.txt

# Check TWS logs
cat /home/ibgateway/Jts/*/log.*
```

### Database Inspection

```bash
# Connect to database
docker compose exec db psql -U stockplan_user -d stockplan_dev

# Check broker connections
SELECT * FROM broker_connections WHERE provider = 'ibkr';

# Check recent transactions
SELECT * FROM transactions ORDER BY created_at DESC LIMIT 10;

# Check sync history
SELECT user_id, status, last_synced_at, status_detail 
FROM broker_connections 
WHERE provider = 'ibkr';
```

### Network Debugging

```bash
# Test Gateway from backend
docker compose exec app curl -v http://ib-gateway:5000/v1/api/iserver/auth/status

# Check DNS resolution
docker compose exec app nslookup ib-gateway

# Check network connectivity
docker compose exec app ping ib-gateway
```

---

## Error Messages Reference

| Error Message | Cause | Solution |
|--------------|-------|----------|
| "IBKR did not return any accounts" | Gateway not authenticated | Restart Gateway, check credentials |
| "IBKR positions request failed with status 401" | Session expired | Reauthenticate via Gateway |
| "IBKR Gateway is not responding" | Gateway down or network issue | Check Gateway status, restart if needed |
| "Broker connection id missing" | Database inconsistency | Check broker_connections table |
| "Invalid broker provider" | Wrong provider name | Use "ibkr" (lowercase) |
| "IBKR connection not found" | User not connected | Complete OAuth flow first |

---

## Getting Help

If issues persist:

1. **Collect diagnostic information:**
   ```bash
   # Save logs
   docker compose logs > logs.txt
   
   # Save configuration (redact secrets!)
   docker compose config > config.yml
   
   # Save database state
   docker compose exec db psql -U stockplan_user -d stockplan_dev \
     -c "\dt" > db_tables.txt
   ```

2. **Check documentation:**
   - [IB Gateway Docker](https://github.com/gnzsnz/ib-gateway-docker)
   - [IBKR API Docs](https://ibkrcampus.com/campus/ibkr-api-page/webapi-doc/)

3. **Contact support** with:
   - Error messages from logs
   - Steps to reproduce
   - Environment details (OS, Docker version, etc.)
