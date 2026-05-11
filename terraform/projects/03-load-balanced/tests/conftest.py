import time

import boto3
import pytest

FLASK_BASE_URL = "http://localhost:8080"   # via ALB
AWS_ENDPOINT   = "http://localhost:4566"
TABLE_NAME     = "load-balanced-counters"


@pytest.fixture(scope="session")
def dynamodb():
    return boto3.resource(
        "dynamodb",
        endpoint_url=AWS_ENDPOINT,
        region_name="eu-west-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
    )


@pytest.fixture(scope="session")
def table(dynamodb):
    return dynamodb.Table(TABLE_NAME)


def wait_for(condition_fn, timeout=15, interval=2):
    """Poll condition_fn until it returns a truthy value or timeout expires."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = condition_fn()
        if result:
            return result
        time.sleep(interval)
    raise TimeoutError(f"condition not met within {timeout}s")
