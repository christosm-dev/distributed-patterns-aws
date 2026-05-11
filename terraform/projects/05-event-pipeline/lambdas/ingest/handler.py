import json
import os
import uuid
from datetime import datetime, timezone

import boto3

TOPIC_ARN = os.environ["TOPIC_ARN"]

_sns = boto3.client("sns", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))


def handler(event, context):
    body = json.loads(event.get("body") or "{}")
    title  = body.get("title", "")
    source = body.get("source", "unknown")

    if not title:
        return {"statusCode": 400, "body": json.dumps({"error": "title is required"})}

    item_id = body.get("id") or str(uuid.uuid4())
    message = {
        "id":           item_id,
        "title":        title,
        "source":       source,
        "ingested_at":  datetime.now(timezone.utc).isoformat(),
    }

    response = _sns.publish(TopicArn=TOPIC_ARN, Message=json.dumps(message))

    return {
        "statusCode": 200,
        "body": json.dumps({"message_id": response["MessageId"], "item_id": item_id}),
    }
