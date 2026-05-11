import json
import os
from datetime import datetime, timezone, timedelta

import boto3
from botocore.exceptions import ClientError

TABLE_NAME = os.environ["TABLE_NAME"]

_dynamodb = boto3.resource("dynamodb", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))


def handler(event, context):
    table = _dynamodb.Table(TABLE_NAME)

    for record in event.get("Records", []):
        # SQS body is the SNS notification envelope
        outer  = json.loads(record["body"])
        message = json.loads(outer["Message"]) if "Message" in outer else outer

        item_id    = message["id"]
        title      = message["title"]
        score      = len(title.split())   # word count as score
        expires_at = int((datetime.now(timezone.utc) + timedelta(hours=24)).timestamp())

        try:
            table.put_item(
                Item={
                    "id":           item_id,
                    "title":        title,
                    "score":        score,
                    "source":       message.get("source"),
                    "processed_at": datetime.now(timezone.utc).isoformat(),
                    "expires_at":   expires_at,
                },
                ConditionExpression="attribute_not_exists(id)",
            )
            print(f"processed {item_id} score={score}")
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                print(f"duplicate skipped: {item_id}")
            else:
                raise
