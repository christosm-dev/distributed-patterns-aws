import json
import uuid

import requests

from conftest import API_ENDPOINT, RESULTS_BUCKET, TABLE_NAME, wait_for


def test_ingest_returns_message_and_item_id():
    resp = requests.post(API_ENDPOINT, json={"title": "test item", "source": "pytest"})
    assert resp.status_code == 200
    body = resp.json()
    assert "message_id" in body
    assert "item_id" in body


def test_missing_title_returns_400():
    resp = requests.post(API_ENDPOINT, json={"source": "pytest"})
    assert resp.status_code == 400
    assert "error" in resp.json()


def test_item_written_to_dynamodb(table):
    item_id = str(uuid.uuid4())
    resp = requests.post(API_ENDPOINT, json={"id": item_id, "title": "dynamodb check", "source": "pytest"})
    assert resp.status_code == 200

    def item_exists():
        return table.get_item(Key={"id": item_id}).get("Item")

    item = wait_for(item_exists)
    assert item["title"] == "dynamodb check"
    assert "score" in item
    assert "expires_at" in item


def test_score_equals_word_count(table):
    item_id = str(uuid.uuid4())
    title = "one two three four"   # 4 words
    requests.post(API_ENDPOINT, json={"id": item_id, "title": title, "source": "pytest"})

    def item_exists():
        return table.get_item(Key={"id": item_id}).get("Item")

    item = wait_for(item_exists)
    assert int(item["score"]) == 4


def test_notification_written_to_s3(s3):
    item_id = str(uuid.uuid4())
    requests.post(API_ENDPOINT, json={"id": item_id, "title": "s3 notify check", "source": "pytest"})

    def object_exists():
        resp = s3.list_objects_v2(Bucket=RESULTS_BUCKET, Prefix=f"notifications/{item_id}.json")
        return resp.get("KeyCount", 0) > 0

    wait_for(object_exists)
    obj = s3.get_object(Bucket=RESULTS_BUCKET, Key=f"notifications/{item_id}.json")
    notification = json.loads(obj["Body"].read())
    assert notification["item_id"] == item_id


def test_duplicate_item_id_is_deduplicated(table):
    item_id = str(uuid.uuid4())
    requests.post(API_ENDPOINT, json={"id": item_id, "title": "first write", "source": "pytest"})

    def item_exists():
        return table.get_item(Key={"id": item_id}).get("Item")

    wait_for(item_exists)

    # Second publish with same id — process lambda should skip it
    requests.post(API_ENDPOINT, json={"id": item_id, "title": "second write", "source": "pytest"})

    import time; time.sleep(5)
    item = table.get_item(Key={"id": item_id})["Item"]
    assert item["title"] == "first write"
