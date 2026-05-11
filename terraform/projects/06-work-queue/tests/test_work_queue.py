import json
import uuid

from conftest import DLQ_URL, QUEUE_URL, TABLE_NAME, wait_for


def _send_item(sqs, item_id=None):
    item_id = item_id or str(uuid.uuid4())
    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps({"id": item_id, "payload": "test-item"}),
    )
    return item_id


def test_item_processed_and_written_to_dynamodb(sqs, table):
    item_id = _send_item(sqs)

    def item_exists():
        return table.get_item(Key={"id": item_id}).get("Item")

    item = wait_for(item_exists)
    assert item["id"] == item_id
    assert "worker_id" in item
    assert "processed_at" in item


def test_adapter_normalises_all_worker_output_shapes(sqs, table):
    # Send one item per worker by sending enough messages to spread across all three.
    item_ids = [_send_item(sqs) for _ in range(9)]

    def all_written():
        found = []
        for item_id in item_ids:
            item = table.get_item(Key={"id": item_id}).get("Item")
            if item:
                found.append(item)
        return found if len(found) == len(item_ids) else None

    items = wait_for(all_written, timeout=30)

    # All items must have the normalised schema regardless of which worker processed them.
    for item in items:
        assert "id" in item
        assert "worker_id" in item
        assert "processed_at" in item


def test_all_three_workers_contribute(lamb, table):
    # Invoke each worker Lambda directly with a crafted SQS Records payload
    # to guarantee all three output shapes are exercised independently of
    # how SQS distributes messages.
    item_ids = {
        "1":        str(uuid.uuid4()),
        "2":        str(uuid.uuid4()),
        "worker-3": str(uuid.uuid4()),
    }

    for worker_num, item_id in [("1", item_ids["1"]), ("2", item_ids["2"]), ("3", item_ids["worker-3"])]:
        payload = {"Records": [{"body": json.dumps({"id": item_id, "payload": "direct-invoke"})}]}
        lamb.invoke(
            FunctionName=f"work-queue-worker-{worker_num}",
            InvocationType="RequestResponse",
            Payload=json.dumps(payload).encode(),
        )

    def all_written():
        found = {}
        for expected_worker_id, item_id in item_ids.items():
            item = table.get_item(Key={"id": item_id}).get("Item")
            if item:
                found[expected_worker_id] = item["worker_id"]
        return found if len(found) == 3 else None

    found = wait_for(all_written, timeout=20)
    assert found["1"] == "1"
    assert found["2"] == "2"
    assert found["worker-3"] == "worker-3"


def test_dlq_remains_empty(sqs):
    attrs = sqs.get_queue_attributes(
        QueueUrl=DLQ_URL,
        AttributeNames=["ApproximateNumberOfMessages"],
    )
    assert int(attrs["Attributes"]["ApproximateNumberOfMessages"]) == 0
