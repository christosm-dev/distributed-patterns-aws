import json
import os
from datetime import datetime, timezone

import boto3

WORKER_ID       = os.environ["WORKER_ID"]
ADAPTER_FUNCTION = os.environ["ADAPTER_FUNCTION"]

_lambda = boto3.client("lambda", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))


def handler(event, context):
    for record in event.get("Records", []):
        body    = json.loads(record["body"])
        item_id = body.get("id", "unknown")

        # Each worker produces a deliberately different output shape to
        # demonstrate the adapter's normalisation role.
        if WORKER_ID == "1":
            result = {"worker": WORKER_ID, "item_id": item_id, "status": "processed",
                      "ts": datetime.now(timezone.utc).isoformat()}
        elif WORKER_ID == "2":
            result = {"worker_id": WORKER_ID, "id": item_id, "done": True,
                      "processed_at": datetime.now(timezone.utc).isoformat()}
        else:
            result = {"source": f"worker-{WORKER_ID}", "ref": item_id, "result": "ok",
                      "when": datetime.now(timezone.utc).isoformat()}

        _lambda.invoke(
            FunctionName=ADAPTER_FUNCTION,
            InvocationType="Event",
            Payload=json.dumps(result).encode(),
        )
        print(f"worker-{WORKER_ID} processed {item_id}")
