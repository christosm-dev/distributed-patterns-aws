import requests

from conftest import FLASK_BASE_URL, S3_BUCKET, wait_for


def test_health_returns_ok():
    resp = requests.get(f"{FLASK_BASE_URL}/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


def test_create_item_returns_201():
    resp = requests.post(
        f"{FLASK_BASE_URL}/items",
        json={"name": "sidecar-test-item"},
    )
    assert resp.status_code == 201
    body = resp.json()
    assert "id" in body
    assert body["name"] == "sidecar-test-item"


def test_list_items_contains_created_item():
    name = "list-check-item"
    create = requests.post(f"{FLASK_BASE_URL}/items", json={"name": name})
    assert create.status_code == 201
    item_id = create.json()["id"]

    resp = requests.get(f"{FLASK_BASE_URL}/items")
    assert resp.status_code == 200
    ids = [i["id"] for i in resp.json()["items"]]
    assert item_id in ids


def test_create_item_without_name_returns_400():
    resp = requests.post(f"{FLASK_BASE_URL}/items", json={})
    assert resp.status_code == 400
    assert "error" in resp.json()


def test_logs_shipped_to_s3(s3):
    # Record S3 object count before generating traffic.
    before = {obj["Key"] for obj in
              s3.list_objects_v2(Bucket=S3_BUCKET).get("Contents", [])}

    # Generate enough requests to ensure log lines are written.
    for _ in range(5):
        requests.get(f"{FLASK_BASE_URL}/health")
        requests.post(f"{FLASK_BASE_URL}/items", json={"name": "log-ship-probe"})

    # Wait for the sidecar to flush (FLUSH_INTERVAL=30s; allow 60s headroom).
    def new_objects_exist():
        current = {obj["Key"] for obj in
                   s3.list_objects_v2(Bucket=S3_BUCKET).get("Contents", [])}
        return current - before

    new_keys = wait_for(new_objects_exist, timeout=60, interval=5)
    assert new_keys, "no new log objects found in S3 after 60s"
    assert all(k.startswith("logs/") for k in new_keys)
