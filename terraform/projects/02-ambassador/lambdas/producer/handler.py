import json
import os
import uuid
from datetime import datetime, timezone

import boto3

AMBASSADOR_FUNCTION = os.environ["AMBASSADOR_FUNCTION"]

_lambda = boto3.client("lambda", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))


def handler(event, context):
    payload = {
        "message_id": str(uuid.uuid4()),
        "body": event.get("body", "hello from producer"),
        "produced_at": datetime.now(timezone.utc).isoformat(),
    }

    response = _lambda.invoke(
        FunctionName=AMBASSADOR_FUNCTION,
        InvocationType="RequestResponse",
        Payload=json.dumps(payload).encode(),
    )

    result = json.loads(response["Payload"].read())
    print(json.dumps({"sent": payload["message_id"], "ambassador_response": result}))
    return result
