"""
circuit_breaker.py

A thread-safe implementation of the Circuit Breaker pattern.

States:
  CLOSED    — normal operation, calls pass through
  OPEN      — downstream failing, calls blocked immediately
  HALF_OPEN — recovery probe, one call allowed through to test recovery

Usage:
    cb = CircuitBreaker(failure_threshold=5, recovery_timeout=30)

    def call_downstream():
        return requests.get("http://service/endpoint", timeout=2)

    try:
        result = cb.call(call_downstream)
    except CircuitOpenError:
        # handle fast failure — downstream is known to be unavailable
        return fallback_response()
"""

import time
import threading
import logging
from collections import deque
from typing import Callable

logger = logging.getLogger(__name__)


class CircuitOpenError(Exception):
    """Raised when a call is attempted while the circuit is open."""
    pass


class CircuitBreaker:
    CLOSED    = "closed"
    OPEN      = "open"
    HALF_OPEN = "half_open"

    def __init__(
        self,
        failure_threshold: int = 5,
        recovery_timeout: int = 30,
        window_seconds: int = 60,
        expected_exception: tuple = (Exception,),
        name: str = "default",
    ):
        """
        Args:
            failure_threshold:  Number of failures within window_seconds before opening.
            recovery_timeout:   Seconds to wait in OPEN before probing with HALF_OPEN.
            window_seconds:     Sliding window for counting failures.
            expected_exception: Exception types that count as failures.
            name:               Identifier for logging and metrics.
        """
        self.failure_threshold  = failure_threshold
        self.recovery_timeout   = recovery_timeout
        self.window_seconds     = window_seconds
        self.expected_exception = expected_exception
        self.name               = name

        self._state             = self.CLOSED
        self._failures          = deque()   # timestamps of recent failures
        self._last_failure_time = None
        self._half_open_probe   = False     # True while a probe call is in flight
        self._lock              = threading.Lock()

    # ── Public interface ───────────────────────────────────────────────────────

    def call(self, func: Callable, *args, **kwargs):
        """
        Execute func through the circuit breaker.

        Raises:
            CircuitOpenError: if the circuit is open and the call is blocked.
            Any exception raised by func if the circuit is closed or half-open.
        """
        with self._lock:
            self._prune_old_failures()
            self._update_state()

            if self._state == self.OPEN:
                logger.warning(
                    "Circuit open — call blocked",
                    extra={"circuit": self.name, "failures": len(self._failures)},
                )
                raise CircuitOpenError(
                    f"Circuit '{self.name}' is open — downstream unavailable"
                )

            if self._state == self.HALF_OPEN:
                if self._half_open_probe:
                    # Another probe is already in flight — block this call
                    raise CircuitOpenError(
                        f"Circuit '{self.name}' is half-open — probe in progress"
                    )
                self._half_open_probe = True

        # Execute outside the lock so concurrent calls are not serialised
        try:
            result = func(*args, **kwargs)
            self._on_success()
            return result
        except self.expected_exception as e:
            self._on_failure()
            raise

    @property
    def state(self) -> str:
        return self._state

    @property
    def failure_count(self) -> int:
        with self._lock:
            self._prune_old_failures()
            return len(self._failures)

    # ── State transitions ──────────────────────────────────────────────────────

    def _update_state(self):
        """Transition OPEN → HALF_OPEN if recovery_timeout has elapsed."""
        if (
            self._state == self.OPEN
            and self._last_failure_time is not None
            and time.time() - self._last_failure_time >= self.recovery_timeout
        ):
            logger.info(
                "Circuit transitioning to half-open",
                extra={"circuit": self.name},
            )
            self._state = self.HALF_OPEN
            self._half_open_probe = False

    def _on_success(self):
        with self._lock:
            prev_state = self._state
            self._failures.clear()
            self._half_open_probe = False
            self._state = self.CLOSED
            if prev_state != self.CLOSED:
                logger.info(
                    "Circuit closed — downstream recovered",
                    extra={"circuit": self.name},
                )

    def _on_failure(self):
        with self._lock:
            now = time.time()
            self._failures.append(now)
            self._last_failure_time = now
            self._half_open_probe = False

            if len(self._failures) >= self.failure_threshold:
                prev_state = self._state
                self._state = self.OPEN
                if prev_state != self.OPEN:
                    logger.error(
                        "Circuit opened — failure threshold reached",
                        extra={
                            "circuit":   self.name,
                            "failures":  len(self._failures),
                            "threshold": self.failure_threshold,
                        },
                    )

    def _prune_old_failures(self):
        """Remove failure timestamps outside the sliding window."""
        cutoff = time.time() - self.window_seconds
        while self._failures and self._failures[0] < cutoff:
            self._failures.popleft()

    # ── Representation ─────────────────────────────────────────────────────────

    def __repr__(self) -> str:
        return (
            f"CircuitBreaker("
            f"name={self.name!r}, "
            f"state={self._state}, "
            f"failures={len(self._failures)}/{self.failure_threshold})"
        )
