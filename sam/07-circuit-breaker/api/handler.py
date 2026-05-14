"""
api/handler.py

API Lambda — receives requests and calls the downstream service
via a circuit breaker. Demonstrates graceful degradation when the
downstream is unavailable.

Endpoints (via API Gateway):
    GET  /profile/{user_id}   — fetch user profile, with fallback
    GET  /health              — returns circuit breaker state
"""

import json
import logging
import os
import urllib.request
import urllib.error
from circuit_breaker.circuit_breaker import CircuitBreaker, CircuitOpenError

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

DOWNSTREAM_URL = os.environ.get("DOWNSTREAM_URL", "http://localhost:3001")

# Initialised once per Lambda execution environment (warm instance)
# expected_exception covers network-level failures
profile_cb = CircuitBreaker(
    name="profile-service",
    failure_threshold=3,
    recovery_timeout=10,
    window_seconds=30,
    expected_exception=(urllib.error.URLError, urllib.error.HTTPError, OSError),
)


def _fetch_profile(user_id: str) -> dict:
    """Call the downstream profile service. Raises on any network error."""
    url = f"{DOWNSTREAM_URL}/users/{user_id}"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=2) as resp:
        return json.loads(resp.read().decode())


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
        return _response(200, {
            "status": "ok",
            "circuit_breakers": {
                "profile-service": {
                    "state":         profile_cb.state,
                    "failures":      profile_cb.failure_count,
                    "threshold":     profile_cb.failure_threshold,
                    "representation": repr(profile_cb),
                }
            },
        })

    # ── GET /profile/{user_id} ─────────────────────────────────────────────────
    user_id = path_params.get("user_id")
    if not user_id:
        return _response(400, {"error": "user_id is required"})

    try:
        profile = profile_cb.call(_fetch_profile, user_id)
        return _response(200, {"user_id": user_id, "profile": profile})

    except CircuitOpenError:
        # Fast failure — downstream is known to be unavailable
        # Return a degraded but functional response rather than 503
        logger.warning("Returning degraded profile — circuit open",
                        extra={"user_id": user_id})
        return _response(200, {
            "user_id":   user_id,
            "profile":   {"status": "unavailable"},
            "degraded":  True,
            "reason":    "profile service temporarily unavailable",
        })

    except Exception as e:
        logger.error("Unexpected error fetching profile",
                     extra={"user_id": user_id, "error": str(e)})
        return _response(503, {"error": "service unavailable"})
