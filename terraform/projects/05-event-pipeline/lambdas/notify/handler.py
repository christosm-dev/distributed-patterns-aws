import json
import os
from datetime import datetime, timezone

import boto3

S3_BUCKET = os.environ["S3_BUCKET"]

_s3 = boto3.client("s3", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))


def handler(event, context):
    for record in event.get("Records", []):
        outer   = json.loads(record["body"])
        message = json.loads(outer["Message"]) if "Message" in outer else outer

        item_id = message["id"]
        summary = {
            "item_id":      item_id,
            "title":        message["title"],
            "source":       message.get("source"),
            "notified_at":  datetime.now(timezone.utc).isoformat(),
        }

        key = f"notifications/{item_id}.json"
        _s3.put_object(Bucket=S3_BUCKET, Key=key, Body=json.dumps(summary).encode())
        print(f"notification written: {key}")
