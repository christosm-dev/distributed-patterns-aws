import time

import boto3
import pytest

AWS_ENDPOINT = "http://localhost:4566"
QUEUE_URL    = "http://localhost:4566/000000000000/ambassador-queue"
DLQ_URL      = "http://localhost:4566/000000000000/ambassador-queue-dlq"


@pytest.fixture(scope="session")
def sqs():
    return boto3.client(
        "sqs",
        endpoint_url=AWS_ENDPOINT,
        region_name="eu-west-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
    )


@pytest.fixture(scope="session")
def lamb():
    return boto3.client(
        "lambda",
        endpoint_url=AWS_ENDPOINT,
        region_name="eu-west-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
    )


def wait_for(condition_fn, timeout=15, interval=2):
    """Poll condition_fn until it returns a truthy value or timeout expires."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = condition_fn()
        if result:
            return result
        time.sleep(interval)
    raise TimeoutError(f"condition not met within {timeout}s")
