# Project 07 — Circuit Breaker

**Pattern:** Circuit Breaker

## Concept

The Circuit Breaker pattern prevents cascading failures in distributed systems. When a downstream service starts failing consistently, the circuit breaker opens and subsequent calls fail immediately — without waiting for a timeout — protecting the caller from resource exhaustion and allowing the downstream time to recover.

The pattern takes its name from an electrical circuit breaker: when a fault is detected, the circuit opens to prevent damage, then after a recovery period it enters a half-open probe state to test whether the fault has cleared.

```
                    ┌─────────────────────────────────────────┐
                    │           Circuit Breaker                │
                    │                                          │
  Caller ──────────►│  CLOSED ──(failures≥threshold)──► OPEN  │
                    │     ▲                        │          │
                    │     │                        │          │
                    │  (success)            (recovery_timeout) │
                    │     │                        │          │
                    │  HALF_OPEN ◄─────────────────┘          │
                    └─────────────────────────────────────────┘
                                     │
                              ┌──────▼──────┐
                              │  Downstream │
                              │   Service   │
                              └─────────────┘
```

### The three states

**CLOSED** — normal operation. All calls pass through to the downstream service. Failures are counted within a sliding time window. When the failure count reaches `failure_threshold`, the circuit opens.

**OPEN** — the downstream is considered unavailable. All calls fail immediately with `CircuitOpenError` — no call is made to the downstream. After `recovery_timeout` seconds the circuit transitions to HALF_OPEN.

**HALF_OPEN** — recovery probe state. One call is allowed through to test whether the downstream has recovered. If it succeeds, the circuit closes. If it fails, it reopens and the recovery timer resets.

### Why this matters

Without a circuit breaker, a slow or failing downstream causes callers to block waiting for timeouts — consuming threads, connections, and memory. This can cascade: one failing service brings down the services that depend on it. The circuit breaker converts slow failures into fast failures, giving callers the information they need to degrade gracefully.

### Graceful degradation

The correct response to `CircuitOpenError` is not a 500 — it is a **degraded but functional response**. In this project the API Lambda returns a partial profile with `"degraded": true` rather than failing the request entirely. The user gets a response; the system surfaces its constraints transparently.

---

## What is built

- **`circuit_breaker/circuit_breaker.py`** — production-quality implementation with:
  - Sliding window failure counting (old failures outside `window_seconds` are pruned)
  - Thread-safe state transitions using `threading.Lock`
  - Probe serialisation in HALF_OPEN (only one probe call at a time)
  - Structured logging on all state transitions
  - Custom `CircuitOpenError` exception type

- **`api/handler.py`** — API Lambda that calls the downstream via the circuit breaker, with graceful degradation on `CircuitOpenError`

- **`downstream/handler.py`** — simulated flaky service with a configurable `FAILURE_RATE` (0.0–1.0), allowing you to observe circuit state transitions without a real external dependency

- **`tests/test_circuit_breaker.py`** — unit tests covering all state transitions, sliding window behaviour, and thread safety

---

## Running locally with SAM

### Prerequisites

LocalStack must be running:
```bash
cd localstack && docker compose up -d
```

### Start the downstream service

In one terminal, start the downstream Lambda on port 3001:
```bash
cd sam/07-circuit-breaker
sam local start-lambda --port 3001 --env-vars env.json
```

### Start the API service

In a second terminal, start the API Lambda on port 3000:
```bash
cd sam/07-circuit-breaker
sam local start-api --port 3000 --env-vars env.json
```

### Observe a healthy circuit

```bash
# Fetch a profile — circuit is CLOSED, downstream responds normally
curl http://localhost:3000/profile/user-001

# Check circuit state
curl http://localhost:3000/health
# {"status": "ok", "circuit_breakers": {"profile-service": {"state": "closed", ...}}}
```

### Simulate an outage — watch the circuit open

Edit `env.json` and set `FAILURE_RATE` to `1.0` for the DownstreamFunction, then restart the downstream Lambda. Now make repeated calls:

```bash
# First 3 calls fail (failure_threshold=3) — circuit opens on the 3rd
for i in 1 2 3; do curl http://localhost:3000/profile/user-001; echo; done

# Subsequent calls are blocked immediately — degraded response returned
curl http://localhost:3000/profile/user-001
# {"user_id": "user-001", "profile": {"status": "unavailable"}, "degraded": true, ...}

# Circuit state is now OPEN
curl http://localhost:3000/health
```

### Simulate recovery — watch HALF_OPEN probe

Set `FAILURE_RATE` back to `0.0` and restart the downstream. After `recovery_timeout` (10 seconds by default), the next call will probe:

```bash
sleep 10
curl http://localhost:3000/profile/user-001
# Circuit transitions OPEN → HALF_OPEN → CLOSED on successful probe
curl http://localhost:3000/health
# {"state": "closed", ...}
```

### Run the unit tests

```bash
cd sam/07-circuit-breaker
pip install pytest
pytest tests/ -v
```

---

## Key design decisions

**Sliding window over simple counter**
Failures are counted within a `window_seconds` window. Without this, a burst of failures from hours ago would prevent the circuit from closing even after the downstream has fully recovered.

**Lock scope**
The `threading.Lock` protects only state reads and writes — not the actual function call. Holding a lock across the downstream call would serialise all concurrent requests, defeating the purpose of a non-blocking circuit breaker.

**One probe at a time in HALF_OPEN**
The `_half_open_probe` flag ensures only one call is allowed through during the probe state. Without this, a thundering herd of concurrent calls could all probe simultaneously, overwhelming a recovering downstream.

**Custom exception type**
`CircuitOpenError` is a distinct exception type so callers can distinguish "circuit is open" from any other runtime error and handle each appropriately.

**Per-dependency circuit breakers**
One circuit breaker per downstream dependency. If the identity service fails, the payments circuit should remain closed. Shared circuit breakers would cause unrelated services to interfere with each other.

---

## Relationship to other patterns

| Pattern | Relationship |
|---|---|
| Ambassador (Project 02) | The natural home for a circuit breaker — the ambassador wraps the downstream call and the circuit breaker sits inside it |
| Retry (code comprehension exercise) | Complementary — retry handles transient failures, circuit breaker handles sustained failures. Use both: retry first, circuit breaker as the outer guard |
| Work queue (Project 06) | A circuit breaker on the queue producer prevents message accumulation when the queue is unavailable |

---

## Files

```
sam/07-circuit-breaker/
├── circuit_breaker/
│   └── circuit_breaker.py      Core implementation
├── api/
│   └── handler.py              API Lambda with graceful degradation
├── downstream/
│   └── handler.py              Simulated flaky downstream service
├── tests/
│   └── test_circuit_breaker.py Unit tests
├── template.yaml               SAM template
├── env.json                    SAM local environment variables
└── events.json                 Sample invocation events

terraform/projects/07-circuit-breaker/
└── main.tf                     Lambda and IAM resources
```
