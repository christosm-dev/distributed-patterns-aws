import requests

from conftest import FLASK_BASE_URL, FLASK_DIRECT_URL, TABLE_NAME, wait_for


def test_alb_health_check():
    # Confirm the ALB is routing traffic to the flask-api container.
    resp = requests.get(f"{FLASK_BASE_URL}/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


def test_counter_increments_on_each_request():
    counter_id = "test-increment"

    first  = requests.post(f"{FLASK_BASE_URL}/counter", json={"id": counter_id})
    second = requests.post(f"{FLASK_BASE_URL}/counter", json={"id": counter_id})

    assert first.status_code == 200
    assert second.status_code == 200
    assert second.json()["value"] == first.json()["value"] + 1


def test_counter_persisted_in_dynamodb(table):
    counter_id = "test-persistence"

    resp = requests.post(f"{FLASK_BASE_URL}/counter", json={"id": counter_id})
    assert resp.status_code == 200
    api_value = resp.json()["value"]

    item = table.get_item(Key={"counter_id": counter_id}).get("Item")
    assert item is not None
    assert int(item["value"]) == api_value


def test_independent_counters_do_not_interfere():
    requests.post(f"{FLASK_BASE_URL}/counter", json={"id": "counter-a"})
    requests.post(f"{FLASK_BASE_URL}/counter", json={"id": "counter-b"})

    a = requests.post(f"{FLASK_BASE_URL}/counter", json={"id": "counter-a"}).json()["value"]
    b = requests.post(f"{FLASK_BASE_URL}/counter", json={"id": "counter-b"}).json()["value"]

    assert a >= 2
    assert b >= 2


def test_default_counter_id_is_global():
    resp = requests.post(f"{FLASK_BASE_URL}/counter", json={})
    assert resp.status_code == 200
    assert resp.json()["counter_id"] == "global"


def test_alb_and_direct_share_same_dynamodb_state(table):
    # A write via ALB must be visible via a direct DynamoDB read —
    # confirming the container behind the ALB is the same one using the table.
    counter_id = "shared-state-check"

    resp = requests.post(f"{FLASK_BASE_URL}/counter", json={"id": counter_id})
    assert resp.status_code == 200
    alb_value = resp.json()["value"]

    item = table.get_item(Key={"counter_id": counter_id}).get("Item")
    assert int(item["value"]) == alb_value
