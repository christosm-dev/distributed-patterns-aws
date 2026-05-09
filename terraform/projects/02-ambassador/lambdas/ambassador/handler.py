import json
import os
import time

import boto3

QUEUE_URL_PARAM = os.environ["QUEUE_URL_PARAM"]

_ssm = boto3.client("ssm", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))
_sqs = boto3.client("sqs", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))

MAX_RETRIES = 3
BASE_DELAY  = 0.5


def _queue_url() -> str:
    return _ssm.get_parameter(Name=QUEUE_URL_PARAM)["Parameter"]["Value"]


def handler(event, context):
    queue_url = _queue_url()
    last_exc  = None

    for attempt in range(MAX_RETRIES):
        try:
            _sqs.send_message(QueueUrl=queue_url, MessageBody=json.dumps(event))
            print(json.dumps({
                "status":     "sent",
                "message_id": event.get("message_id"),
                "attempt":    attempt + 1,
            }))
            return {"status": "sent", "message_id": event.get("message_id")}
        except Exception as exc:
            last_exc = exc
            if attempt < MAX_RETRIES - 1:
                time.sleep(BASE_DELAY * (2 ** attempt))

    raise RuntimeError(f"failed after {MAX_RETRIES} attempts: {last_exc}")
