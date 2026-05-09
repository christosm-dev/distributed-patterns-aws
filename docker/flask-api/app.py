"""
flask-api — shared application container for Projects 01 and 03.

Endpoints:
  GET  /health   — health check, no dependencies, always 200
  GET  /items    — list items (in-memory store)
  POST /items    — create item (in-memory store)
  POST /counter  — atomically increment a DynamoDB counter (Project 03)
"""

import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError
from flask import Flask, jsonify, request

app = Flask(__name__)

# ── Logging setup ──────────────────────────────────────────────────────────
# Log to both stdout (picked up by Docker/ECS) and a file in a shared volume
# (picked up by the Fluent Bit sidecar).

LOG_DIR = os.environ.get("LOG_DIR", "/var/log/app")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")

os.makedirs(LOG_DIR, exist_ok=True)


class JSONFormatter(logging.Formatter):
    """Emit log records as single-line JSON for structured log parsing."""

    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "service": "flask-api",
        }
        if hasattr(record, "extra"):
            log_entry.update(record.extra)
        if record.exc_info:
            log_entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_entry)


def build_logger(name: str) -> logging.Logger:
    logger = logging.getLogger(name)
    logger.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))

    formatter = JSONFormatter()

    # stdout handler
    stream_handler = logging.StreamHandler()
    stream_handler.setFormatter(formatter)
    logger.addHandler(stream_handler)

    # file handler — written to shared volume for Fluent Bit to tail
    file_handler = logging.FileHandler(os.path.join(LOG_DIR, "app.log"))
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    return logger


logger = build_logger("flask-api")

# ── DynamoDB client (Project 03) ──────────────────────────────────────────

DYNAMODB_TABLE   = os.environ.get("DYNAMODB_TABLE")
DYNAMODB_ENDPOINT = os.environ.get("DYNAMODB_ENDPOINT_URL")

_dynamodb = boto3.resource(
    "dynamodb",
    region_name=os.environ.get("AWS_DEFAULT_REGION", "eu-west-1"),
    endpoint_url=DYNAMODB_ENDPOINT,
    aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
    aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
)

# ── In-memory store (intentionally simple for this demo) ──────────────────

_items: dict[str, dict] = {}


# ── Routes ─────────────────────────────────────────────────────────────────

@app.route("/health")
def health():
    """Lightweight health check — no dependencies, always returns 200."""
    return jsonify({"status": "ok", "timestamp": datetime.now(timezone.utc).isoformat()})


@app.route("/items", methods=["GET"])
def list_items():
    start = time.monotonic()
    items = list(_items.values())
    duration_ms = round((time.monotonic() - start) * 1000, 2)

    logger.info(
        "GET /items",
        extra={
            "extra": {
                "method": "GET",
                "path": "/items",
                "count": len(items),
                "duration_ms": duration_ms,
            }
        },
    )
    return jsonify({"items": items, "count": len(items)})


@app.route("/items", methods=["POST"])
def create_item():
    start = time.monotonic()
    payload = request.get_json(silent=True) or {}

    if "name" not in payload:
        logger.warning(
            "POST /items — missing required field: name",
            extra={"extra": {"method": "POST", "path": "/items", "error": "missing_field"}},
        )
        return jsonify({"error": "name is required"}), 400

    item_id = str(uuid.uuid4())
    item = {
        "id": item_id,
        "name": payload["name"],
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    _items[item_id] = item
    duration_ms = round((time.monotonic() - start) * 1000, 2)

    logger.info(
        "POST /items — item created",
        extra={
            "extra": {
                "method": "POST",
                "path": "/items",
                "item_id": item_id,
                "duration_ms": duration_ms,
            }
        },
    )
    return jsonify(item), 201


@app.route("/counter", methods=["POST"])
def increment_counter():
    if not DYNAMODB_TABLE:
        return jsonify({"error": "DYNAMODB_TABLE not configured"}), 503

    start = time.monotonic()
    counter_id = request.get_json(silent=True, force=True) or {}
    counter_id = counter_id.get("id", "global")

    try:
        table = _dynamodb.Table(DYNAMODB_TABLE)
        result = table.update_item(
            Key={"counter_id": counter_id},
            UpdateExpression="ADD #v :inc",
            ExpressionAttributeNames={"#v": "value"},
            ExpressionAttributeValues={":inc": 1},
            ReturnValues="UPDATED_NEW",
        )
        value = int(result["Attributes"]["value"])
    except ClientError as exc:
        logger.error("counter update failed", extra={"extra": {"error": str(exc)}})
        return jsonify({"error": "counter update failed"}), 500

    duration_ms = round((time.monotonic() - start) * 1000, 2)
    logger.info(
        "POST /counter",
        extra={"extra": {"counter_id": counter_id, "value": value, "duration_ms": duration_ms}},
    )
    return jsonify({"counter_id": counter_id, "value": value})


# ── Entry point ────────────────────────────────────────────────────────────

if __name__ == "__main__":
    logger.info("Starting flask-api", extra={"extra": {"log_dir": LOG_DIR}})
    app.run(host="0.0.0.0", port=5000, debug=False)
