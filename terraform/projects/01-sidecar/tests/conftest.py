import time

import boto3
import pytest

FLASK_BASE_URL = "http://localhost:5000"
AWS_ENDPOINT   = "http://localhost:4566"
S3_BUCKET      = "sidecar-logs"


@pytest.fixture(scope="session")
def s3():
    return boto3.client(
        "s3",
        endpoint_url=AWS_ENDPOINT,
        region_name="eu-west-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
    )


def wait_for(condition_fn, timeout=60, interval=3):
    """Poll condition_fn until it returns a truthy value or timeout expires."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = condition_fn()
        if result:
            return result
        time.sleep(interval)
    raise TimeoutError(f"condition not met within {timeout}s")
