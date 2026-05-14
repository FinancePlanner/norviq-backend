#!/usr/bin/env python3
"""
Update .env.production with Apple OAuth + APNS secrets.
Run this via SSH on the production server.
"""
import re

# Base64-encoded PEM keys to avoid shell escaping issues
import base64

oauth_key = base64.b64decode(
    "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JR1RBZ0VBTUJNR0J5cUdTTTQ5QWdFR0NDcUdTTTQ5QXdFSEJIa3dkd0lCQVFRZ09hWVpMN1NhUDdH"
    "TWJUMTl5VCtWZ0g2REdwRjV2T01lOEh2eUtaby94VE9nQ2dZSUtvWkl6ajBEQVFlaFJBTkNBQVFWVmZ6c3Fh"
    "bzFrY1czWFhwUDZYL210RjdWcDJaalBvWmJRRkVqN1FYMjFML01ZNGhFMDdubFhSWWFNbWszTXh0L0gwb3Aw"
    "S1FpUS9JN1FySHREaG1zCi0tLS0tRU5EIFBSSVZBVEUgS0VZLS0tLS0K"
).decode("utf-8").strip().replace("\n", "\\n")

apns_key = base64.b64decode(
    "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JR1RBZ0VBTUJNR0J5cUdTTTQ5QWdFR0NDcUdTTTQ5QXdFSEJIa3dkd0lCQVFRZzMrTHFhU2JH"
    "K0tRTG1URkN6NGVUaTRIMHFEL1lKNko2R0RrYWU4cDV6U09nQ2dZSUtvWkl6ajBEQVFlaFJBTkNBQVJCQ0c3"
    "ZzBUZzJwT0NHamhjVFE2ZHdycGIrUExxaGs4N1pTcGI4eFNSakFXRUVUd0FGYTFVbWd1aUI1cDgzcStSWGFn"
    "NlFaeDAwaW45eWtobStJeWwKLS0tLS1FTkQgUFJJVkFURSBLRVktLS0tLQo="
).decode("utf-8").strip().replace("\n", "\\n")

path = "/opt/stockplan/.env.production"

with open(path, "r") as f:
    content = f.read()

updates = {
    "APNS_TEAM_ID": "84X9WYBF36",
    "APNS_KEY_ID": "WP8NG28N63",
    "APNS_PRIVATE_KEY_P8": apns_key,
    "APNS_TOPIC": "facorreia.financeplan",
    "OAUTH_APPLE_CLIENT_ID": "facorreia.financeplan",
    "OAUTH_APPLE_TEAM_ID": "84X9WYBF36",
    "OAUTH_APPLE_KEY_ID": "BV4PBRXTZ3",
    "OAUTH_APPLE_PRIVATE_KEY": oauth_key,
    "BILLING_PREMIUM_EMAILS": "testemail12345678@email.com",
    "BYPASS_BILLING": "true",
    "REVENUECAT_API_KEY": "sk_HEJTcPFiLTipIaSqddoOSunQuAOTLL",
    "REVENUECAT_WEBHOOK_SECRET": "aDcRhXETamXkw0Us2xdjpoW14msZETwP9eVnslMOWNM",
    "DISCORD_WEBHOOK_URL": "https://discord.com/api/webhooks/1500153981937389568/Rw8qmmPMxxL4X1vAgy8B-E9FqlBwnG4dITCDOY4YwbQsP_5lO5SYC2hmzMjmPRbPAKq_",
    "ACME_EMAIL": "fernandocorreia316@gmail.com",
    "IBKR_API_BASE_URL": "https://localhost:5000/v1/api",
}

for k, v in updates.items():
    pattern = f"^{re.escape(k)}=.*$"
    if re.search(pattern, content, re.MULTILINE):
        content = re.sub(pattern, f"{k}={v}", content, flags=re.MULTILINE)
        print(f"  Updated {k}")
    else:
        content += f"\n{k}={v}"
        print(f"  Added  {k}")

with open(path, "w") as f:
    f.write(content)

print("Done - .env.production updated")

# Verify the .env symlink
os.symlink("/opt/stockplan/.env.production", "/opt/stockplan/.env.tmp")
print("Symlink created for verification")
