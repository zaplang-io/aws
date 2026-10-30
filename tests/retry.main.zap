# Offline retry test — exercises aws.retry (standard mode) deterministically and
# pins the output in tests/expected/retry.expected. No live AWS calls: the retry
# loop is driven by an injected response "script" (a canned sequence of
# `Response`s) through the same `fn() -> Response` seam the live client uses, so
# attempt counts, classification, backoff, and quota behavior are all asserted
# without a network.
#
# Everything printed is deterministic and RNG-implementation-independent:
# classification is a pure table, the backoff section pins the (RNG-free) caps
# and asserts the jittered draw only by in-bounds/determinism BOOLEANS, and the
# loop runs with base_delay 0 (so it neither sleeps nor consumes the RNG) while
# the jitter formula itself is checked separately under a seed.
#
# Run: tools/zrun.sh src/aws/core.zap src/aws/endpoints.zap src/aws/retry.zap \
#          tests/retry.main.zap

# --- injected transport: a scripted sequence of responses ------------------

# A canned response sequence with a mutable cursor (single-element list so the
# position persists across calls through the captured reference — the same shape
# the token bucket uses). `script_next` returns the responses in order, clamping
# to the last one if the loop asks for more than were scripted.
import aws_core.core
import aws_core.retry

struct Script:
    list[core.Response] items
    list[int64] cursor

def new_script(list[core.Response] items) -> Script:
    return Script(items=items, cursor=[0])

def script_next(Script s) -> core.Response:
    auto i = s.cursor[0]
    s.cursor[0] = i + 1
    if i >= len(s.items):
        return s.items[len(s.items) - 1]
    return s.items[i]

# Response builders.
def ok_resp() -> core.Response:
    return core.Response(status=200, headers={}, body="{}")

def err_resp(int64 status, str code) -> core.Response:
    auto body = "{\"__type\":\"" + code + "\",\"message\":\"boom\"}"
    return core.Response(status=status, headers={}, body=body)

def yn(bool b) -> str:
    if b:
        return "True"
    return "False"

def main():
    print("== classification ==")
    print("429/'' -> " + str(retry.retry_class(429, "")))
    print("503/SlowDown -> " + str(retry.retry_class(503, "SlowDown")))
    print("500/'' -> " + str(retry.retry_class(500, "")))
    print("0/'' -> " + str(retry.retry_class(0, "")))
    print(
        "400/ThrottlingException -> " + str(retry.retry_class(400, "ThrottlingException")),
    )
    print("403/AccessDenied -> " + str(retry.retry_class(403, "AccessDenied")))
    print("404/NoSuchKey -> " + str(retry.retry_class(404, "NoSuchKey")))
    print("400/RequestTimeout -> " + str(retry.retry_class(400, "RequestTimeout")))
    print(
        "retryable 500=" + yn(retry.is_retryable(500, "")) + " 403=" + yn(retry.is_retryable(403, "AccessDenied")),
    )

    print("== backoff ==")
    auto cfg = retry.standard_retry_config()
    auto caps = ""
    for a in range(0, 7):
        caps = caps + " " + str(int64(retry.backoff_cap(cfg, a)))
    print("caps" + caps)
    # Determinism: the same seed yields the same jittered draw.
    retry.seed_jitter(123)
    auto d1 = retry.backoff_delay(cfg, 2)
    retry.seed_jitter(123)
    auto d2 = retry.backoff_delay(cfg, 2)
    print("deterministic " + yn(d1 == d2))
    # Full jitter stays within [0, cap] for every attempt under a fixed seed.
    retry.seed_jitter(7)
    auto in_bounds = True
    for a in range(0, 6):
        auto d = retry.backoff_delay(cfg, a)
        if d < 0.0:
            in_bounds = False
        if d > retry.backoff_cap(cfg, a):
            in_bounds = False
    print("in-bounds " + yn(in_bounds))

    print("== quota ==")
    auto q = retry.new_retry_quota()
    print("start " + str(retry.quota_balance(q)))
    print(
        "acquire5 " + yn(retry.quota_acquire(q, 5)) + " bal " + str(retry.quota_balance(q)),
    )
    print(
        "acquire10 " + yn(retry.quota_acquire(q, 10)) + " bal " + str(retry.quota_balance(q)),
    )
    retry.quota_release(q, 5)
    print("release5 bal " + str(retry.quota_balance(q)))
    retry.quota_release(q, 100)
    print("release100-capped bal " + str(retry.quota_balance(q)))
    auto qs = retry.new_retry_quota(7)
    print(
        "small acquire5 " + yn(retry.quota_acquire(qs, 5)) + " bal " + str(retry.quota_balance(qs)),
    )
    print(
        "small acquire5 " + yn(retry.quota_acquire(qs, 5)) + " bal " + str(retry.quota_balance(qs)),
    )

    print("== loop ==")
    # Zero-backoff config: deterministic, no sleeps, no RNG — isolates the loop.
    auto fast = retry.RetryConfig(
        max_attempts=3,
        base_delay=0.0,
        max_backoff=0.0,
        retry_cost=5,
        timeout_retry_cost=10,
        no_retry_refill=1,
    )

    # Clean success on the first try: one attempt, quota refilled (capped).
    auto q1 = retry.new_retry_quota()
    auto s1 = new_script([ok_resp()])
    fn() -> core.Response f1 = lambda: script_next(s1)
    auto o1 = retry.retry_send(fast, q1, f1)
    print(
        "clean: attempts " + str(o1.attempts) + " status " + str(o1.response.status) + " exh " + yn(o1.quota_exhausted) + " bal " + str(retry.quota_balance(q1)),
    )

    # Transient 500 then success: two attempts, tokens returned on success.
    auto q2 = retry.new_retry_quota()
    auto s2 = new_script([err_resp(500, "InternalFailure"), ok_resp()])
    fn() -> core.Response f2 = lambda: script_next(s2)
    auto o2 = retry.retry_send(fast, q2, f2)
    print(
        "transient-then-ok: attempts " + str(o2.attempts) + " status " + str(o2.response.status) + " exh " + yn(o2.quota_exhausted) + " bal " + str(retry.quota_balance(q2)),
    )

    # Throttle (by code) then success.
    auto q3 = retry.new_retry_quota()
    auto s3 = new_script([err_resp(400, "ThrottlingException"), ok_resp()])
    fn() -> core.Response f3 = lambda: script_next(s3)
    auto o3 = retry.retry_send(fast, q3, f3)
    print(
        "throttle-then-ok: attempts " + str(o3.attempts) + " status " + str(o3.response.status) + " exh " + yn(o3.quota_exhausted),
    )

    # All transient: give up at the attempt cap, surface the error.
    auto q4 = retry.new_retry_quota()
    auto s4 = new_script(
        [
            err_resp(503, "ServiceUnavailable"),
            err_resp(503, "ServiceUnavailable"),
            err_resp(503, "ServiceUnavailable"),
        ],
    )
    fn() -> core.Response f4 = lambda: script_next(s4)
    auto o4 = retry.retry_send(fast, q4, f4)
    auto c4 = ""
    if o4.error.is_some():
        c4 = o4.error.unwrap().code
    print(
        "exhaust-attempts: attempts " + str(o4.attempts) + " status " + str(o4.response.status) + " exh " + yn(o4.quota_exhausted) + " code " + c4 + " bal " + str(retry.quota_balance(q4)),
    )

    # Permanent 403: not retryable, surfaced on the first attempt.
    auto q5 = retry.new_retry_quota()
    auto s5 = new_script([err_resp(403, "AccessDenied")])
    fn() -> core.Response f5 = lambda: script_next(s5)
    auto o5 = retry.retry_send(fast, q5, f5)
    auto c5 = ""
    if o5.error.is_some():
        c5 = o5.error.unwrap().code
    print(
        "permanent: attempts " + str(o5.attempts) + " status " + str(o5.response.status) + " exh " + yn(o5.quota_exhausted) + " code " + c5,
    )

    # Quota drain: a small bucket + a high attempt cap means the token bucket,
    # not the attempt cap, stops the storm.
    auto drain_cfg = retry.RetryConfig(
        max_attempts=9,
        base_delay=0.0,
        max_backoff=0.0,
        retry_cost=5,
        timeout_retry_cost=10,
        no_retry_refill=1,
    )
    auto q6 = retry.new_retry_quota(7)
    auto s6 = new_script(
        [
            err_resp(500, "InternalFailure"),
            err_resp(500, "InternalFailure"),
            err_resp(500, "InternalFailure"),
            err_resp(500, "InternalFailure"),
        ],
    )
    fn() -> core.Response f6 = lambda: script_next(s6)
    auto o6 = retry.retry_send(drain_cfg, q6, f6)
    print(
        "quota-drain: attempts " + str(o6.attempts) + " exh " + yn(o6.quota_exhausted) + " bal " + str(retry.quota_balance(q6)),
    )
