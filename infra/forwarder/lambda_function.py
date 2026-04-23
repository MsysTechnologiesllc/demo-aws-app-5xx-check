import json
import os
import urllib.request
import urllib.error

AZIRON_WEBHOOK_URL = os.environ.get("AZIRON_WEBHOOK_URL", "")


def lambda_handler(event, context):
    print(f"Received event: {json.dumps(event)}")

    if not AZIRON_WEBHOOK_URL:
        print("ERROR: AZIRON_WEBHOOK_URL environment variable not set")
        return {"statusCode": 500, "body": "AZIRON_WEBHOOK_URL not configured"}

    # Forward the raw EventBridge event to Aziron
    payload = json.dumps(event).encode("utf-8")
    req = urllib.request.Request(
        AZIRON_WEBHOOK_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode("utf-8")
            print(f"Aziron responded {resp.status}: {body[:200]}")
            return {"statusCode": resp.status, "body": body}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8")
        print(f"Aziron HTTP error {e.code}: {body[:200]}")
        return {"statusCode": e.code, "body": body}
    except Exception as e:
        print(f"Failed to forward to Aziron: {e}")
        return {"statusCode": 500, "body": str(e)}
