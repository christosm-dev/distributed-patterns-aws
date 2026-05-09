import os
import time
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import BotoCoreError, ClientError

LOG_FILE      = os.environ.get("LOG_FILE",       "/var/log/app/app.log")
S3_BUCKET     = os.environ["S3_BUCKET"]
AWS_REGION    = os.environ.get("AWS_REGION",     "eu-west-1")
S3_ENDPOINT   = os.environ.get("S3_ENDPOINT_URL","http://localhost:4566")
FLUSH_INTERVAL = int(os.environ.get("FLUSH_INTERVAL", "30"))

s3 = boto3.client(
    "s3",
    region_name=AWS_REGION,
    endpoint_url=S3_ENDPOINT,
    aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
    aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
)


def s3_key() -> str:
    now = datetime.now(timezone.utc)
    return f"logs/{now:%Y/%m/%d/%H/%M-%S}-{uuid.uuid4().hex[:8]}.log"


def ship(lines: list[str]) -> None:
    body = "\n".join(lines) + "\n"
    key = s3_key()
    s3.put_object(Bucket=S3_BUCKET, Key=key, Body=body.encode())
    print(f"shipped {len(lines)} lines → s3://{S3_BUCKET}/{key}", flush=True)


def tail() -> None:
    while not os.path.exists(LOG_FILE):
        print(f"waiting for {LOG_FILE} ...", flush=True)
        time.sleep(2)

    print(f"tailing {LOG_FILE}, flushing every {FLUSH_INTERVAL}s", flush=True)

    buffer: list[str] = []
    last_flush = time.monotonic()

    with open(LOG_FILE) as f:
        f.seek(0, 2)  # start at end — only ship new lines
        while True:
            line = f.readline()
            if line:
                buffer.append(line.rstrip())

            elapsed = time.monotonic() - last_flush
            if elapsed >= FLUSH_INTERVAL and buffer:
                try:
                    ship(buffer)
                except (BotoCoreError, ClientError) as exc:
                    print(f"upload failed: {exc}", flush=True)
                finally:
                    buffer = []
                    last_flush = time.monotonic()
            elif not line:
                time.sleep(0.5)


if __name__ == "__main__":
    tail()
