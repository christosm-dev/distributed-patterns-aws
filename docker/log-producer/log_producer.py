import json
import os
import uuid
from datetime import datetime, timezone

import boto3

QUEUE_URL   = os.environ["QUEUE_URL"]
TOTAL_ITEMS = int(os.environ.get("TOTAL_ITEMS", "30"))
BATCH_SIZE  = 10

_sqs = boto3.client("sqs", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))


def produce() -> None:
    items = [
        {
            "id":         str(uuid.uuid4()),
            "payload":    f"work-item-{i}",
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        for i in range(TOTAL_ITEMS)
    ]

    for batch_start in range(0, len(items), BATCH_SIZE):
        batch   = items[batch_start:batch_start + BATCH_SIZE]
        entries = [{"Id": str(j), "MessageBody": json.dumps(item)} for j, item in enumerate(batch)]
        _sqs.send_message_batch(QueueUrl=QUEUE_URL, Entries=entries)
        print(f"sent batch {batch_start // BATCH_SIZE + 1}: {len(batch)} items", flush=True)

    print(f"done: {TOTAL_ITEMS} items sent to {QUEUE_URL}", flush=True)


if __name__ == "__main__":
    produce()
