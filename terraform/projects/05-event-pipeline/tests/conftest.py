import os
import subprocess
import time

import boto3
import pytest

AWS_ENDPOINT   = "http://localhost:4566"
TABLE_NAME     = "pipeline-items"
RESULTS_BUCKET = "pipeline-notifications"

_PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _api_endpoint() -> str:
    result = subprocess.run(
        ["terraform", "output", "-raw", "api_endpoint"],
        cwd=_PROJECT_DIR,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


API_ENDPOINT = _api_endpoint()


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


@pytest.fixture(scope="session")
def s3():
    return boto3.client(
        "s3",
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
