import json
import os
import urllib.request


WEBHOOK_URL = os.environ["SLACK_WEBHOOK_URL"]


def handler(event, context):
    for record in event.get("Records", []):
        raw = record.get("Sns", {}).get("Message", "")
        subject = record.get("Sns", {}).get("Subject", "AWS Alert")

        try:
            body = json.loads(raw)
            # CloudWatch alarm
            if body.get("AlarmName"):
                text = (
                    f"*{body['AlarmName']}*\n"
                    f"State: `{body.get('NewStateValue', 'UNKNOWN')}`\n"
                    f"Reason: {body.get('NewStateReason', '-')}\n"
                    f"Account: `{body.get('AWSAccountId', '-')}`"
                )
            # GuardDuty / EventBridge formatted string
            else:
                text = raw
        except (json.JSONDecodeError, TypeError):
            text = raw if raw else subject

        payload = json.dumps({"text": text}).encode()
        req = urllib.request.Request(
            WEBHOOK_URL,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            resp.read()
