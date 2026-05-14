#!/usr/bin/env python3
"""Update .env.production on the server with Apple OAuth + APNS secrets."""
import re

path = "/opt/stockplan/.env.production"

with open(path, "r") as f:
    content = f.read()

# Build the value to write: all known keys with their correct values
updates = {}

# Read from a companion file (no PEM data in this script)
# The PEM keys are in companion.txt with base64-encoded values
import base64

# Base64-encoded PEM keys (avoids shell/terminal escaping issues)
# These were provided by the user:
oauth_key_b64 = "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JR1RBZ0VBTUJNR0J5cUdTTTQ5QWdFR0NDcUdTTTQ5QXdFSEJIZ2h3ZElCQVFRZ09hWVpMN1NhUDdHTWNUMTl5VCtWZ0g2REdwRjV2T01lOEh2eUtav294VE9nQ2dZSUtvWkl6ajBEQVFFaFJOQUFBV1ZmemNxYW8xa2NXM1hYcFA2WC9tdEZ2VnAyWmpQb1piUUZFN1FYMjFML01ZNGhFMDdubFhSWWFNbWszTXh0L0gwb3AwS1FpUS9JN1FySHREaG1zCi0tLS0tRU5EIFBSSVZBVEUgS0VZLS0tLS0K"

apns_key_b64 = "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JR1RBZ0VBTUJNR0J5cUdTTTQ5QWdFR0NDcUdTTTQ5QXdFSEJIZ2h3ZElCQVFRZzMrTHFhU2JHK0tRTG1URkNaNWVUaTRIMHFEL1lKNko2R0RrYWU4cDV6U09nQ2dZSUtvWkl6ajBEQVFFaFJOQUFBRkdON2cwVGcycE9DR3poY1RRNmR3clBiMCtQTHFoa3g3WlNwYjh4U1JqQVdFRVR3QUZhMVVtZ3VpQjVwODNxK1JYYWc2UVp4MDBpbjl5a2htK0l5bAotLS0tLUVORCBQUklWQVRFIEtFWS0tLS0tCg=="

oauth_key_pem = base64.b64decode(oauth_key_b64).decode("utf-8")
oauth_key_pem = oauth_key_pem.strip().replace("\n", "\\n")

apns_key_pem = base64.b64decode(apns_key_b64).decode("utf-8")
apns_key_pem = apns_key_pem.strip().replace("\n", "\\n")

updates = {
    "APNS_TEAM_ID": "84X9WYBF36",
    "APNS_KEY_ID": "WP8NG28N63",
    "APNS_PRIVATE_KEY_P8": oauth_key_pem,
    "APNS_TOPIC": "facorreia.financeplan",
    "OAUTH_APPLE_CLIENT_ID": "facorreia.financeplan",
    "OAUTH_APPLE_TEAM_ID": "84X9WYBF36",
    "OAUTH_APPLE_KEY_ID": "BV4PBRXTZ3",
    "OAUTH_APPLE_PRIVATE_KEY": oauth_key_pem,
    "BILLING_PREMIUM_EMAILS": "testemail12345678@email.com",
    "BYPASS_BILLING": "true",
    "REVENUECAT_API_KEY": "sk_HEJTcPFiLTipIaSqddoOSunQuAOTLL",
    "REVENUECAT_WEBHOOK_SECRET": "aDcRhXETamXkw0Us2xdjpoW14msZETwP9eVnslMOWNM",
    "DISCORD_WEBHOOK_URL": "https://discord.com/api/webhooks/1500153981937389568/Rw8qmmPMxxL4X1vAgy8B-E9FqlBwnG4dITCDOY4YwbQsP_5lO5SYC2hmzMjmPRbPAKq_",
    "ACME_EMAIL": "fernandocorreia316@gmail.com",
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
