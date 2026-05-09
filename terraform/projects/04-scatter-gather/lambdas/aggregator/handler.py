import json
import os
from datetime import datetime, timezone

import boto3

S3_BUCKET = os.environ["S3_BUCKET"]

_s3 = boto3.client("s3", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))


def handler(event, context):
    query    = event.get("query", "")
    branches = event.get("parallel_results", [])

    successful    = [b for b in branches if b.get("success")]
    success_count = len(successful)

    merged = []
    for branch in successful:
        merged.extend(branch.get("results", []))

    result = {
        "execution_id":  context.aws_request_id,
        "query":         query,
        "success_count": success_count,
        "total_results": len(merged),
        "results":       merged,
        "gathered_at":   datetime.now(timezone.utc).isoformat(),
    }

    key = f"results/{context.aws_request_id}.json"
    _s3.put_object(Bucket=S3_BUCKET, Key=key, Body=json.dumps(result, default=str).encode())

    return {
        "success_count": success_count,
        "total_results": len(merged),
        "result_key":    key,
    }
