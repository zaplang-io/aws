# aws.waiters — generic poll-until-state waiters for the Zap AWS SDK.
#
# A waiter repeatedly calls one operation until the resource it describes reaches
# a desired state ("wait until this S3 bucket exists", "wait until this EC2
# instance is running"). This module is the protocol-agnostic ENGINE: the config
# shape mirrors botocore's `waiters-2.json` model and the loop evaluates acceptors
# against each poll. Per-service waiter TABLES (one `WaiterConfig` per entry in a
# service's `waiters-2.json`) are emitted by aws-codegen — a FOLLOW-UP (see
# DECISIONS.md D-0004); the real-AWS fixtures wired into tests/waiters.main.zap
# stand in for that generated output and exercise every matcher kind.
#
# On top of the engine sits the ergonomic `Waiter` handle (the boto3
# `get_waiter(name).wait(...)` surface): it bundles a `WaiterConfig` with its poll
# closure and adds the boto3-faithful raise-on-failure/timeout semantics a
# generated `wait_<name>(self, ...)` client helper calls via `wait_or_raise` (see
# the handle section
# near the end of this file and DECISIONS.md D-0012).
#
# It is bundled AFTER aws.core (the same import contract aws.retry uses), so every
# type it leans on — `Response`, `AwsError`, `parse_error`, `is_success`,
# `Request`, `Credentials`, `sign_request_now`, `send` — is already in scope.
#
# ## The botocore waiter model (what `waiters-2.json` encodes)
# Each waiter is `{delay, maxAttempts, operation, acceptors[]}`. An acceptor is
# `{state, matcher, argument, expected}`:
#   * `state`   — success | failure | retry: the transition when the acceptor
#                 matches.
#   * `matcher` — how to test a response:
#                   status   — the HTTP status code equals `expected`.
#                   error    — the AWS error code equals `expected`.
#                   path     — the single value JMESPath `argument` selects
#                              equals `expected`.
#                   pathAll  — EVERY value `argument` selects equals `expected`
#                              (and at least one value is selected).
#                   pathAny  — AT LEAST ONE value `argument` selects equals
#                              `expected`.
#   * `argument`— the JMESPath into the parsed response (path matchers only).
#   * `expected`— the value to compare against, as a string ("200", "ACTIVE",
#                 "running", "ResourceNotFoundException", …).
# The engine polls, evaluates acceptors IN ORDER, and takes the first match's
# state. If none matches it keeps polling (botocore's default). Reaching
# `maxAttempts` without a terminal acceptor is a timeout.
#
# ## The parsed-response seam
# `path`/`pathAll`/`pathAny` run over a PARSED response model, not the wire bytes
# — exactly as botocore runs JMESPath over the deserialized output. The engine
# evaluates them over a `JsonValue` DOM the caller supplies with each poll. For
# JSON protocols that DOM is `json.loads(resp.body)` (see `parse_body` /
# `send_poll`); for XML protocols (e.g. EC2 query) the per-protocol adapter (the
# restxml codec's parse) produces the same DOM. `status`/`error` matchers read the
# `Response` directly and need no DOM, so status-only waiters (S3 HeadBucket) pass
# `JsonValue.Null`.
#
# ## Extension seam (mirrors aws.retry)
# The loop is driven by a caller-supplied `fn() -> Poll` — in tests a canned
# sequence of polls, in the live path `send_poll` (re-sign + send + parse) around
# an aws.core `Request`. Callers that do not want to wait never touch this module.

import core
import json
import time

# ---------------------------------------------------------------------------
# Acceptor states (the `state` field of a waiters-2.json acceptor)
# ---------------------------------------------------------------------------

# "retry" — the resource is not yet in a terminal state; keep polling. This is
# also the engine's verdict when NO acceptor matched a response.
def state_retry() -> int64:
    return 0

# "success" — the waiter's goal is reached; stop and report success.
def state_success() -> int64:
    return 1

# "failure" — the resource reached a terminal state that is NOT the goal (e.g.
# an instance was terminated while waiting for it to run); stop and report
# failure.
def state_failure() -> int64:
    return 2

# ---------------------------------------------------------------------------
# Matcher kinds (the `matcher` field of a waiters-2.json acceptor)
# ---------------------------------------------------------------------------

# "status" — compare the HTTP status code to `expected`.
def matcher_status() -> int64:
    return 0

# "error" — compare the parsed AWS error code to `expected`.
def matcher_error() -> int64:
    return 1

# "path" — the single value the JMESPath selects equals `expected`.
def matcher_path() -> int64:
    return 2

# "pathAll" — every value the JMESPath selects equals `expected` (non-empty).
def matcher_path_all() -> int64:
    return 3

# "pathAny" — at least one value the JMESPath selects equals `expected`.
def matcher_path_any() -> int64:
    return 4

# ---------------------------------------------------------------------------
# Config data shape (mirrors waiters-2.json)
# ---------------------------------------------------------------------------

# One acceptor: the transition `state` to take when `matcher` matches. `argument`
# is the JMESPath (empty for status/error matchers); `expected` is the comparison
# value rendered as a string.
struct Acceptor:
    int64 state
    int64 matcher
    str argument
    str expected

# A waiter config: `delay` seconds between polls, `max_attempts` poll cap, and the
# ordered acceptor list. `name` is the waiter's model name (e.g. "BucketExists"),
# for diagnostics. `operation` is intentionally NOT modeled here — which operation
# to call and how to sign it is the caller's `poll_fn`, keeping the engine
# independent of any one service's request builders.
struct WaiterConfig:
    str name
    int64 delay
    int64 max_attempts
    list[Acceptor] acceptors

# Acceptor constructors — ergonomic table building (and what a generated waiter
# table would emit). `expected` is the status code as a string for status
# matchers.
def acceptor_status(int64 state, str expected) -> Acceptor:
    return Acceptor(
        state=state,
        matcher=matcher_status(),
        argument="",
        expected=expected,
    )

def acceptor_error(int64 state, str expected) -> Acceptor:
    return Acceptor(
        state=state,
        matcher=matcher_error(),
        argument="",
        expected=expected,
    )

def acceptor_path(int64 state, str argument, str expected) -> Acceptor:
    return Acceptor(
        state=state,
        matcher=matcher_path(),
        argument=argument,
        expected=expected,
    )

def acceptor_path_all(int64 state, str argument, str expected) -> Acceptor:
    return Acceptor(
        state=state,
        matcher=matcher_path_all(),
        argument=argument,
        expected=expected,
    )

def acceptor_path_any(int64 state, str argument, str expected) -> Acceptor:
    return Acceptor(
        state=state,
        matcher=matcher_path_any(),
        argument=argument,
        expected=expected,
    )

# ---------------------------------------------------------------------------
# JMESPath subset — the slice of JMESPath waiter `argument`s use
# ---------------------------------------------------------------------------
#
# Waiter paths are simple: dotted field access with `[]` flatten projections,
# e.g. `Table.TableStatus` or `Reservations[].Instances[].State.Name`. The
# evaluator walks a `JsonValue` DOM carrying a SET of "current" nodes: a field
# step keeps each node's named child, a `[]` step flattens each array node's
# elements into the set. The selected scalars are then compared to `expected`.

# The named field of `v` as a one-element list (empty if `v` is not an object or
# lacks the field). Returned as a list so callers can concat without a no-op
# match arm.
def object_field(JsonValue v, str name) -> list[JsonValue]:
    list[JsonValue] out = []
    match v:
        case JsonValue.Object(fields):
            Optional[JsonValue] f = fields.get(name)
            if f.is_some():
                out.append(f.unwrap())
        case _:
            out = out
    return out

# The elements of `v` if it is an array, else empty.
def array_items(JsonValue v) -> list[JsonValue]:
    list[JsonValue] out = []
    match v:
        case JsonValue.Array(items):
            out = items
        case _:
            out = out
    return out

# Apply a field step to every current node, collecting the named children.
def project_field(list[JsonValue] nodes, str name) -> list[JsonValue]:
    list[JsonValue] out = []
    for n in nodes:
        for v in object_field(n, name):
            out.append(v)
    return out

# Apply a `[]` flatten to every current node, splicing array elements one level.
def flatten_arrays(list[JsonValue] nodes) -> list[JsonValue]:
    list[JsonValue] out = []
    for n in nodes:
        for it in array_items(n):
            out.append(it)
    return out

# Select the nodes a JMESPath `argument` reaches in `root`. Each dot-segment is a
# field name, optionally suffixed with `[]` to flatten the result one level.
def select_path(JsonValue root, str argument) -> list[JsonValue]:
    list[JsonValue] current = [root]
    for seg in argument.split("."):
        auto name = seg
        auto flatten = False
        if seg.endswith("[]"):
            flatten = True
            name = seg[0:len(seg) - 2]
        if len(name) > 0:
            current = project_field(current, name)
        if flatten:
            current = flatten_arrays(current)
    return current

# Render a scalar `JsonValue` as the string compared against an acceptor's
# `expected`. Containers render as "" (a path that lands on a container never
# equals a scalar `expected`).
def scalar_str(JsonValue v) -> str:
    auto s = ""
    match v:
        case JsonValue.Str(sv):
            s = sv
        case JsonValue.Bool(b):
            if b:
                s = "true"
            else:
                s = "false"
        case JsonValue.Int(i):
            s = str(i)
        case JsonValue.Float(f):
            s = str(f)
        case _:
            s = s
    return s

# ---------------------------------------------------------------------------
# Matcher evaluation
# ---------------------------------------------------------------------------

# status: the HTTP status code equals `expected` (compared as strings).
def match_status(core.Response resp, str expected) -> bool:
    return str(resp.status) == expected

# error: the AWS error code parsed from the response equals `expected`.
def match_error(core.Response resp, str expected) -> bool:
    Optional[core.AwsError] e = core.parse_error(resp)
    if e.is_some():
        return e.unwrap().code == expected
    return False

# path: the single selected value equals `expected`. More or fewer than one
# selected value never matches (a `path` argument is scalar-shaped).
def match_path(JsonValue parsed, str argument, str expected) -> bool:
    auto vals = select_path(parsed, argument)
    if len(vals) != 1:
        return False
    return scalar_str(vals[0]) == expected

# pathAll: non-empty AND every selected value equals `expected`.
def match_path_all(JsonValue parsed, str argument, str expected) -> bool:
    auto vals = select_path(parsed, argument)
    if len(vals) == 0:
        return False
    for v in vals:
        if scalar_str(v) != expected:
            return False
    return True

# pathAny: at least one selected value equals `expected`.
def match_path_any(JsonValue parsed, str argument, str expected) -> bool:
    auto vals = select_path(parsed, argument)
    for v in vals:
        if scalar_str(v) == expected:
            return True
    return False

# Whether `acc` matches `(resp, parsed)`, dispatching on the matcher kind.
def acceptor_matches(Acceptor acc, core.Response resp, JsonValue parsed) -> bool:
    if acc.matcher == matcher_status():
        return match_status(resp, acc.expected)
    if acc.matcher == matcher_error():
        return match_error(resp, acc.expected)
    if acc.matcher == matcher_path():
        return match_path(parsed, acc.argument, acc.expected)
    if acc.matcher == matcher_path_all():
        return match_path_all(parsed, acc.argument, acc.expected)
    if acc.matcher == matcher_path_any():
        return match_path_any(parsed, acc.argument, acc.expected)
    return False

# Evaluate the acceptors in order against one response. Returns the first
# matching acceptor's `state`, or `state_retry` when none matched (keep polling).
def evaluate(list[Acceptor] acceptors, core.Response resp, JsonValue parsed) -> int64:
    for acc in acceptors:
        if acceptor_matches(acc, resp, parsed):
            return acc.state
    return state_retry()

# ---------------------------------------------------------------------------
# The poll + the waiter loop
# ---------------------------------------------------------------------------

# One poll of the operation: the `Response` plus the parsed-response DOM the path
# matchers evaluate over. `parsed` is `JsonValue.Null` for status/error-only
# waiters.
struct Poll:
    core.Response response
    JsonValue parsed

# Terminal waiter results.
def result_success() -> int64:
    return 0

def result_failure() -> int64:
    return 1

def result_timeout() -> int64:
    return 2

# The outcome of a wait: the terminal `result`, the number of polls made, and the
# last response seen (the one that resolved the wait, or the final poll on
# timeout).
struct WaiterOutcome:
    int64 result
    int64 attempts
    core.Response response

# Parse a response body into the DOM the path matchers walk. Empty bodies (S3
# HeadBucket and other status-only responses) parse to `JsonValue.Null`. JSON
# protocols only; an XML protocol supplies its own adapter (see the module
# header).
def parse_body(core.Response resp) -> JsonValue:
    if len(resp.body) == 0:
        return JsonValue.Null
    return json.loads(resp.body)

# Run a waiter: poll via `poll_fn`, evaluate acceptors, and loop with `cfg.delay`
# between polls until a success/failure acceptor fires or `cfg.max_attempts`
# polls have been made (timeout). The delay is slept BEFORE the next poll, never
# after the last — a terminal poll returns immediately.
def wait(WaiterConfig cfg, fn() -> Poll poll_fn) -> WaiterOutcome:
    auto attempt = 0
    auto last_resp = core.Response(status=0, headers={}, body="")
    while attempt < cfg.max_attempts:
        auto p = poll_fn()
        attempt = attempt + 1
        last_resp = p.response
        auto st = evaluate(cfg.acceptors, p.response, p.parsed)
        if st == state_success():
            return WaiterOutcome(
                result=result_success(),
                attempts=attempt,
                response=last_resp,
            )
        if st == state_failure():
            return WaiterOutcome(
                result=result_failure(),
                attempts=attempt,
                response=last_resp,
            )
        if attempt < cfg.max_attempts:
            time.sleep(float64(cfg.delay))
    return WaiterOutcome(result=result_timeout(), attempts=attempt, response=last_resp)

# Live convenience: one poll that re-signs `req` with a fresh SigV4 timestamp,
# sends it, and parses the JSON body into the matcher DOM — the waiter analogue of
# aws.retry's `send_request_with_retry`. A live JSON-protocol waiter is
# `wait(cfg, lambda: send_poll(host, creds, req))`.
def send_poll(str host, core.Credentials creds, core.Request req) -> Poll:
    auto resp = core.send(host, core.sign_request_now(creds, req))
    return Poll(response=resp, parsed=parse_body(resp))

# ---------------------------------------------------------------------------
# The ergonomic Waiter handle (boto3's get_waiter(name).wait(...))
# ---------------------------------------------------------------------------
#
# Everything above is the generic ENGINE. This is the boto3-recognizable surface
# over it: a `Waiter` bundles a `WaiterConfig` (one entry of a service's
# `waiters-2.json` table) with the `fn() -> Poll` that polls the operation, so a
# generated client can expose a clean per-waiter helper — the paginator analogue
# of `paginate_<op>` (D-0011). The chosen client surface is a typed
# `wait_<name>(self, ...)` method per waiter (see DECISIONS.md D-0012), emitted by
# aws-codegen from `waiters-2.json`; each builds the config + poll closure and
# delegates here, e.g. an S3 `BucketExists` helper:
#
#   def wait_bucket_exists(self, str bucket):
#       auto cfg = _bucket_exists_waiter()          # generated table entry
#       auto req = self._head_bucket_request(bucket)
#       fn() -> waiters.Poll p = lambda: waiters.send_poll(self.host, self.creds, req)
#       waiters.waiter(cfg, p).wait_or_raise()      # returns, or raises
#
# `run()` returns the raw `WaiterOutcome` for callers that branch on
# `succeeded`/`failed`/`timed_out`; `wait_or_raise()` is the boto3-faithful form
# that returns normally once the resource reaches the desired state and raises on a
# failure acceptor or timeout (boto3's `waiter.wait()` / WaiterError). Zap's
# `raise` carries a str message today (no typed payload — see aws.errors,
# zaplang-io/zap#22), so the raised value is the formatted diagnostic below,
# recovered by a single `except ... as e:`, exactly as aws.errors' raise bridge
# and aws.batch_writer do.

# A ready-to-run waiter: a config table entry plus the poll closure that calls the
# operation. Mirrors aws.paginators' `Paginator` (config + fetch closure), but the
# loop is a terminal poll rather than a `yield` iterator.
struct Waiter:
    WaiterConfig config
    fn() -> Poll poll

    # Run the waiter loop and return the outcome WITHOUT raising. The
    # function-typed field is bound to a `fn(...)`-annotated local before use (the
    # always-valid form aws.middleware / aws.paginators use, I#163/D-0067).
    def run(self) -> WaiterOutcome:
        fn() -> Poll p = self.poll
        return wait(self.config, p)

    # boto3's `waiter.wait(...)`: return normally once a success acceptor fires, or
    # raise the formatted diagnostic on a failure acceptor or on exhausting
    # `max_attempts` (timeout). Named `wait_or_raise`, not `wait`, because the
    # module-level `wait` engine function occupies that name in this module's scope
    # (an imported struct method cannot shadow the imported free function).
    def wait_or_raise(self):
        auto o = self.run()
        if o.result != result_success():
            raise waiter_error_message(self.config, o)

# Construct a `Waiter` from a table entry and its poll closure — the boto3
# `client.get_waiter('name')` analogue once the config and operation binding are
# in hand. `waiter(cfg, poll).wait_or_raise()` is `get_waiter('name').wait(...)`.
def waiter(WaiterConfig cfg, fn() -> Poll poll) -> Waiter:
    return Waiter(config=cfg, poll=poll)

# Outcome predicates, for callers that drive `run()` rather than the raising
# `wait()`.
def succeeded(WaiterOutcome o) -> bool:
    return o.result == result_success()

def failed(WaiterOutcome o) -> bool:
    return o.result == result_failure()

def timed_out(WaiterOutcome o) -> bool:
    return o.result == result_timeout()

# The message the raising `wait()` throws — boto3's WaiterError text: the waiter
# name, why it stopped (a failure acceptor fired, or the attempt budget ran out),
# and the last HTTP status + attempt count for diagnosis.
def waiter_error_message(WaiterConfig cfg, WaiterOutcome o) -> str:
    auto why = "an unexpected resource state was reached"
    if o.result == result_timeout():
        why = "max attempts exceeded"
    auto tail = " (last-status=" + str(o.response.status)
    tail = tail + ", attempts=" + str(o.attempts) + ")"
    return "Waiter " + cfg.name + " failed: " + why + tail
