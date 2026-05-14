"""
downstream/handler.py

Downstream Lambda — simulates a flaky external service.

Behaviour is controlled via the FAILURE_RATE environment variable (0.0–1.0).
Set to 0.0 for a healthy service, 1.0 to simulate complete outage.

This lets you observe the circuit breaker opening, entering HALF_OPEN,
and recovering — all without needing a real external dependency.

Endpoints:
    GET /users/{user_id}  — returns a fake user profile, or fails per FAILURE_RATE
    GET /health           — always returns 200 (the downstream's own health)
"""

import json
import logging
import os
import random

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

FAILURE_RATE = float(os.environ.get("FAILURE_RATE", "0.0"))

FAKE_USERS = {
    "user-001": {"name": "Alice Smith",   "email": "alice@example.com",  "plan": "standard"},
    "user-002": {"name": "Bob Jones",     "email": "bob@example.com",    "plan": "premium"},
    "user-003": {"name": "Carol White",   "email": "carol@example.com",  "plan": "standard"},
}


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event: dict, context) -> dict:
    path = event.get("path", "/")
    path_params = event.get("pathParameters") or {}

    # ── GET /health ────────────────────────────────────────────────────────────
    if path == "/health":
        return _response(200, {"status": "ok", "failure_rate": FAILURE_RATE})

    # ── GET /users/{user_id} ───────────────────────────────────────────────────
    user_id = path_params.get("user_id")
    if not user_id:
        return _response(400, {"error": "user_id is required"})

    # Simulate flakiness
    if random.random() < FAILURE_RATE:
        logger.warning("Simulating downstream failure", extra={"user_id": user_id})
        # Raise an exception — SAM local invoke will surface this as a Lambda error
        raise RuntimeError(f"Simulated downstream failure for user {user_id}")

    user = FAKE_USERS.get(user_id)
    if not user:
        return _response(404, {"error": f"user {user_id!r} not found"})

    logger.info("Returning user profile", extra={"user_id": user_id})
    return _response(200, user)
