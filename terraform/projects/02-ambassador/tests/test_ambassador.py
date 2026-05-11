import json

from conftest import DLQ_URL, QUEUE_URL, wait_for


def test_producer_invocation_succeeds(lamb):
    response = lamb.invoke(
        FunctionName="producer",
        InvocationType="RequestResponse",
        Payload=json.dumps({"body": "hello from test"}).encode(),
    )
    assert response["StatusCode"] == 200
    result = json.loads(response["Payload"].read())
    assert result["status"] == "sent"
    assert "message_id" in result


def test_message_reaches_queue_then_drains(sqs, lamb):
    lamb.invoke(
        FunctionName="producer",
        InvocationType="RequestResponse",
        Payload=json.dumps({"body": "drain-check"}).encode(),
    )

    # Consumer is triggered by SQS event source mapping — queue should drain.
    def queue_empty():
        attrs = sqs.get_queue_attributes(
            QueueUrl=QUEUE_URL,
            AttributeNames=["ApproximateNumberOfMessages"],
        )
        return int(attrs["Attributes"]["ApproximateNumberOfMessages"]) == 0

    wait_for(queue_empty, timeout=15, interval=2)


def test_dlq_remains_empty(sqs):
    attrs = sqs.get_queue_attributes(
        QueueUrl=DLQ_URL,
        AttributeNames=["ApproximateNumberOfMessages"],
    )
    assert int(attrs["Attributes"]["ApproximateNumberOfMessages"]) == 0


def test_ambassador_reads_queue_url_from_ssm(lamb):
    # If SSM lookup fails the ambassador raises; a 200 with "sent" confirms it worked.
    response = lamb.invoke(
        FunctionName="ambassador",
        InvocationType="RequestResponse",
        Payload=json.dumps({"message_id": "ssm-check", "body": "ssm test"}).encode(),
    )
    assert response["StatusCode"] == 200
    result = json.loads(response["Payload"].read())
    assert result["status"] == "sent"
