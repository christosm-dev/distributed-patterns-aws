import os
from datetime import datetime, timezone

import boto3

TABLE_NAME       = os.environ["TABLE_NAME"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "WorkQueue")

_dynamodb   = boto3.resource("dynamodb",  endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))
_cloudwatch = boto3.client("cloudwatch", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))


def normalise(event: dict) -> dict:
    item_id   = event.get("item_id") or event.get("id") or event.get("ref", "unknown")
    worker_id = str(event.get("worker") or event.get("worker_id") or event.get("source", "unknown"))
    return {
        "id":           item_id,
        "worker_id":    worker_id,
        "processed_at": datetime.now(timezone.utc).isoformat(),
    }


def handler(event, context):
    normalised = normalise(event)

    _dynamodb.Table(TABLE_NAME).put_item(Item=normalised)

    _cloudwatch.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[{
            "MetricName": "ItemsProcessed",
            "Value":      1,
            "Unit":       "Count",
            "Dimensions": [{"Name": "WorkerId", "Value": normalised["worker_id"]}],
        }],
    )

    print(f"adapter normalised {normalised['id']} from worker {normalised['worker_id']}")
    return normalised
