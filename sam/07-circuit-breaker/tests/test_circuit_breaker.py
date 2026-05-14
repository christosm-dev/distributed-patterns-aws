"""
tests/test_circuit_breaker.py

Unit tests for the CircuitBreaker implementation.
Tests cover all state transitions and edge cases.

Run with:
    pytest tests/ -v
"""

import time
import pytest
import threading
from unittest.mock import MagicMock, patch
from circuit_breaker.circuit_breaker import CircuitBreaker, CircuitOpenError


# ── Helpers ────────────────────────────────────────────────────────────────────

def make_cb(**kwargs) -> CircuitBreaker:
    defaults = dict(
        failure_threshold=3,
        recovery_timeout=1,
        window_seconds=60,
        expected_exception=(ValueError,),
        name="test",
    )
    defaults.update(kwargs)
    return CircuitBreaker(**defaults)


def succeeding():
    return "ok"


def failing():
    raise ValueError("downstream error")


# ── State transition tests ─────────────────────────────────────────────────────

class TestClosedState:
    def test_passes_through_successful_calls(self):
        cb = make_cb()
        assert cb.call(succeeding) == "ok"

    def test_stays_closed_below_threshold(self):
        cb = make_cb(failure_threshold=3)
        for _ in range(2):
            with pytest.raises(ValueError):
                cb.call(failing)
        assert cb.state == CircuitBreaker.CLOSED

    def test_opens_at_threshold(self):
        cb = make_cb(failure_threshold=3)
        for _ in range(3):
            with pytest.raises(ValueError):
                cb.call(failing)
        assert cb.state == CircuitBreaker.OPEN

    def test_does_not_count_unexpected_exceptions(self):
        cb = make_cb(failure_threshold=3, expected_exception=(ValueError,))
        for _ in range(5):
            with pytest.raises(RuntimeError):
                cb.call(lambda: (_ for _ in ()).throw(RuntimeError("unexpected")))
        assert cb.state == CircuitBreaker.CLOSED


class TestOpenState:
    def test_raises_circuit_open_error(self):
        cb = make_cb(failure_threshold=1)
        with pytest.raises(ValueError):
            cb.call(failing)
        assert cb.state == CircuitBreaker.OPEN
        with pytest.raises(CircuitOpenError):
            cb.call(succeeding)

    def test_does_not_call_func_when_open(self):
        cb = make_cb(failure_threshold=1)
        with pytest.raises(ValueError):
            cb.call(failing)
        mock_func = MagicMock()
        with pytest.raises(CircuitOpenError):
            cb.call(mock_func)
        mock_func.assert_not_called()


class TestHalfOpenState:
    def test_transitions_to_half_open_after_timeout(self):
        cb = make_cb(failure_threshold=1, recovery_timeout=0)
        with pytest.raises(ValueError):
            cb.call(failing)
        time.sleep(0.01)
        # Trigger state update by attempting a call
        cb.call(succeeding)
        # Should have transitioned through HALF_OPEN back to CLOSED
        assert cb.state == CircuitBreaker.CLOSED

    def test_closes_on_successful_probe(self):
        cb = make_cb(failure_threshold=1, recovery_timeout=0)
        with pytest.raises(ValueError):
            cb.call(failing)
        time.sleep(0.01)
        result = cb.call(succeeding)
        assert result == "ok"
        assert cb.state == CircuitBreaker.CLOSED

    def test_reopens_on_failed_probe(self):
        cb = make_cb(failure_threshold=1, recovery_timeout=0)
        with pytest.raises(ValueError):
            cb.call(failing)
        time.sleep(0.01)
        with pytest.raises(ValueError):
            cb.call(failing)
        assert cb.state == CircuitBreaker.OPEN


class TestSlidingWindow:
    def test_old_failures_outside_window_are_pruned(self):
        cb = make_cb(failure_threshold=3, window_seconds=1)
        for _ in range(2):
            with pytest.raises(ValueError):
                cb.call(failing)
        time.sleep(1.1)
        # Old failures pruned — circuit should still be closed
        assert cb.failure_count == 0
        assert cb.state == CircuitBreaker.CLOSED


class TestThreadSafety:
    def test_concurrent_calls_do_not_corrupt_state(self):
        cb = make_cb(failure_threshold=10, recovery_timeout=60)
        errors = []

        def make_call():
            try:
                cb.call(succeeding)
            except Exception as e:
                errors.append(e)

        threads = [threading.Thread(target=make_call) for _ in range(50)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert not errors
        assert cb.state == CircuitBreaker.CLOSED


class TestRepr:
    def test_repr_includes_state_and_failures(self):
        cb = make_cb(name="my-service", failure_threshold=5)
        r = repr(cb)
        assert "my-service" in r
        assert "closed" in r
        assert "0/5" in r
