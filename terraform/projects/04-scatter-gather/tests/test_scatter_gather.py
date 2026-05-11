import json

from conftest import RESULTS_BUCKET, STATE_MACHINE_ARN, wait_for


def _start(sfn, query="test"):
    resp = sfn.start_execution(
        stateMachineArn=STATE_MACHINE_ARN,
        input=json.dumps({"query": query}),
    )
    return resp["executionArn"]


def _wait_until_complete(sfn, execution_arn, timeout=30):
    def done():
        desc = sfn.describe_execution(executionArn=execution_arn)
        if desc["status"] in ("SUCCEEDED", "FAILED", "TIMED_OUT", "ABORTED"):
            return desc
        return None

    return wait_for(done, timeout=timeout)


def test_execution_succeeds(sfn):
    arn = _start(sfn, query="test")
    desc = _wait_until_complete(sfn, arn)
    assert desc["status"] == "SUCCEEDED"


def test_output_contains_aggregated_results(sfn):
    arn = _start(sfn, query="test")
    desc = _wait_until_complete(sfn, arn)
    assert desc["status"] == "SUCCEEDED"

    output = json.loads(desc["output"])
    assert "success_count" in output
    assert "total_results" in output
    assert output["success_count"] > 0


def test_result_written_to_s3(sfn, s3):
    arn = _start(sfn, query="s3-check")
    desc = _wait_until_complete(sfn, arn)
    assert desc["status"] == "SUCCEEDED"

    output = json.loads(desc["output"])
    result_key = output.get("result_key")
    assert result_key is not None

    obj = s3.get_object(Bucket=RESULTS_BUCKET, Key=result_key)
    result = json.loads(obj["Body"].read())
    assert result["query"] == "s3-check"
    assert "gathered_at" in result


def test_result_key_is_unique_per_execution(sfn):
    arn_a = _start(sfn, query="unique-a")
    arn_b = _start(sfn, query="unique-b")

    desc_a = _wait_until_complete(sfn, arn_a)
    desc_b = _wait_until_complete(sfn, arn_b)

    key_a = json.loads(desc_a["output"])["result_key"]
    key_b = json.loads(desc_b["output"])["result_key"]
    assert key_a != key_b
