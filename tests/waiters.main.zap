# Offline waiter test — exercises aws.waiters (the generic poll-until-state
# engine) deterministically and pins the output in tests/expected/waiters.expected.
# No live AWS calls: the loop is driven by an injected poll "script" (a canned
# sequence of `Poll`s) through the same `fn() -> Poll` seam the live client uses,
# so acceptor evaluation and the success/failure/timeout transitions are asserted
# without a network (mirrors tests/retry.main.zap).
#
# The fixtures are REAL waiters lifted from AWS's own `waiters-2.json` models —
# S3 `BucketExists`/`BucketNotExists` (status matchers), DynamoDB `TableExists`
# (path + error matchers), and EC2 `InstanceRunning` (pathAll/pathAny over a
# flattening JMESPath) — so every matcher kind is exercised against genuine
# acceptor specs. These stand in for the per-service waiter tables aws-codegen
# will emit from `waiters-2.json` (DECISIONS.md D-0004 follow-up).
#
# The path matchers run over a parsed-response DOM (`JsonValue`), exactly as
# botocore runs JMESPath over the deserialized output — independent of the JSON
# vs XML wire format. The EC2 DescribeInstances model is XML on the wire; the DOM
# here is the equivalent parsed shape, which is what the matcher actually sees.
#
# Run: tools/zrun.sh (via tools/run-tests.sh) with the aws_core zenv active.

import aws_core.core
import aws_core.waiters

# --- injected transport: a scripted sequence of polls ----------------------

# A canned poll sequence with a mutable cursor (single-element list, so the
# position persists across calls through the captured reference — the shape
# retry.main.zap's Script uses). `script_next` clamps to the last poll if the
# loop asks for more than were scripted.
struct Script:
    list[waiters.Poll] items
    list[int64] cursor

def new_script(list[waiters.Poll] items) -> Script:
    return Script(items=items, cursor=[0])

def script_next(Script s) -> waiters.Poll:
    auto i = s.cursor[0]
    s.cursor[0] = i + 1
    if i >= len(s.items):
        return s.items[len(s.items) - 1]
    return s.items[i]

# One poll from a status + body: the body is parsed into the matcher DOM exactly
# as the live `send_poll` does (so this also exercises `waiters.parse_body`).
def poll(int64 status, str body) -> waiters.Poll:
    auto r = core.Response(status=status, headers={}, body=body)
    return waiters.Poll(response=r, parsed=waiters.parse_body(r))

# --- canned response bodies (the parsed output model the matchers see) ------

# DynamoDB DescribeTable output: {"Table": {"TableStatus": "<status>"}}.
def ddb_body(str status) -> str:
    return "{\"Table\": {\"TableStatus\": \"" + status + "\"}}"

# EC2 DescribeInstances output: two reservations, one instance each, with the
# given State.Name values — exercises both `[]` flattens in the JMESPath.
def ec2_body(str n1, str n2) -> str:
    auto i1 = "{\"Instances\": [{\"State\": {\"Name\": \"" + n1 + "\"}}]}"
    auto i2 = "{\"Instances\": [{\"State\": {\"Name\": \"" + n2 + "\"}}]}"
    return "{\"Reservations\": [" + i1 + ", " + i2 + "]}"

# --- real waiter fixtures (verbatim from AWS waiters-2.json) ----------------

# s3/2006-03-01/waiters-2.json "BucketExists": HeadBucket, 200/301/403 mean the
# bucket is reachable (success), 404 keeps polling.
def s3_bucket_exists() -> waiters.WaiterConfig:
    return waiters.WaiterConfig(
        name="BucketExists",
        delay=5,
        max_attempts=20,
        acceptors=[
            waiters.acceptor_status(waiters.state_success(), "200"),
            waiters.acceptor_status(waiters.state_success(), "301"),
            waiters.acceptor_status(waiters.state_success(), "403"),
            waiters.acceptor_status(waiters.state_retry(), "404"),
        ],
    )

# s3/2006-03-01/waiters-2.json "BucketNotExists": a 404 means the bucket is gone.
def s3_bucket_not_exists() -> waiters.WaiterConfig:
    return waiters.WaiterConfig(
        name="BucketNotExists",
        delay=5,
        max_attempts=20,
        acceptors=[waiters.acceptor_status(waiters.state_success(), "404")],
    )

# dynamodb/2012-08-10/waiters-2.json "TableExists": DescribeTable, Table.TableStatus
# == ACTIVE is success, a ResourceNotFoundException keeps polling.
def ddb_table_exists() -> waiters.WaiterConfig:
    return waiters.WaiterConfig(
        name="TableExists",
        delay=20,
        max_attempts=25,
        acceptors=[
            waiters.acceptor_path(
                waiters.state_success(),
                "Table.TableStatus",
                "ACTIVE",
            ),
            waiters.acceptor_error(waiters.state_retry(), "ResourceNotFoundException"),
        ],
    )

# ec2/.../waiters-2.json "InstanceRunning": DescribeInstances, every instance
# State.Name == running is success; any terminal state is failure.
def ec2_instance_running() -> waiters.WaiterConfig:
    auto arg = "Reservations[].Instances[].State.Name"
    return waiters.WaiterConfig(
        name="InstanceRunning",
        delay=15,
        max_attempts=40,
        acceptors=[
            waiters.acceptor_path_all(waiters.state_success(), arg, "running"),
            waiters.acceptor_path_any(waiters.state_failure(), arg, "shutting-down"),
            waiters.acceptor_path_any(waiters.state_failure(), arg, "terminated"),
            waiters.acceptor_path_any(waiters.state_failure(), arg, "stopping"),
        ],
    )

# A delay-0 copy so the loop neither sleeps nor depends on wall-clock (mirrors
# retry.main.zap's `fast`); `capped` also shrinks max_attempts for the timeout
# case. The acceptor list is shared by reference — behavior is unchanged.
def fast(waiters.WaiterConfig c) -> waiters.WaiterConfig:
    return waiters.WaiterConfig(
        name=c.name,
        delay=0,
        max_attempts=c.max_attempts,
        acceptors=c.acceptors,
    )

def capped(waiters.WaiterConfig c, int64 n) -> waiters.WaiterConfig:
    return waiters.WaiterConfig(
        name=c.name,
        delay=0,
        max_attempts=n,
        acceptors=c.acceptors,
    )

# --- print helpers ----------------------------------------------------------

def state_name(int64 s) -> str:
    if s == waiters.state_success():
        return "success"
    if s == waiters.state_failure():
        return "failure"
    return "retry"

def result_name(int64 r) -> str:
    if r == waiters.result_success():
        return "success"
    if r == waiters.result_failure():
        return "failure"
    return "timeout"

# Evaluate one poll against a config's acceptors → the transition name.
def ev(waiters.WaiterConfig c, waiters.Poll p) -> str:
    return state_name(waiters.evaluate(c.acceptors, p.response, p.parsed))

# Run a waiter over a scripted poll sequence.
def run(waiters.WaiterConfig c, Script s) -> waiters.WaiterOutcome:
    fn() -> waiters.Poll f = lambda: script_next(s)
    return waiters.wait(c, f)

def show(str label, waiters.WaiterOutcome o) -> str:
    return label + ": " + result_name(o.result) + " attempts " + str(o.attempts)

def show_cfg(waiters.WaiterConfig c) -> str:
    auto s = c.name + " delay " + str(c.delay)
    s = s + " max " + str(c.max_attempts)
    s = s + " acc " + str(len(c.acceptors))
    return s

def main():
    auto be = s3_bucket_exists()
    auto bne = s3_bucket_not_exists()
    auto te = ddb_table_exists()
    auto ir = ec2_instance_running()
    # The DescribeTable error body when the table is not yet visible.
    auto rnf = "{\"__type\": \"ResourceNotFoundException\"}"

    # Config shape: the fixtures carry the real waiters-2.json delay / maxAttempts
    # / acceptor counts.
    print("== config ==")
    print(show_cfg(be))
    print(show_cfg(bne))
    print(show_cfg(te))
    print(show_cfg(ir))

    # Per-matcher acceptor evaluation against single responses.
    print("== matchers ==")
    print("be 200 -> " + ev(be, poll(200, "{}")))
    print("be 404 -> " + ev(be, poll(404, "")))
    print("be 500 -> " + ev(be, poll(500, "{}")))
    print("te active -> " + ev(te, poll(200, ddb_body("ACTIVE"))))
    print("te creating -> " + ev(te, poll(200, ddb_body("CREATING"))))
    print("te missing -> " + ev(te, poll(400, rnf)))
    print("ir running -> " + ev(ir, poll(200, ec2_body("running", "running"))))
    print("ir terminated -> " + ev(ir, poll(200, ec2_body("terminated", "running"))))
    print("ir pending -> " + ev(ir, poll(200, ec2_body("pending", "pending"))))

    # Full poll loops: transitions over a scripted sequence.
    print("== loop ==")
    # Bucket appears on the third poll (404, 404, 200).
    auto l1 = run(fast(be), new_script([poll(404, ""), poll(404, ""), poll(200, "{}")]))
    print(show("bucket-exists", l1))
    # Bucket never appears within the (capped) attempt budget → timeout.
    auto l2 = run(capped(be, 3), new_script([poll(404, "")]))
    print(show("bucket-exists-timeout", l2))
    # BucketNotExists: the first 404 is success.
    auto l3 = run(fast(bne), new_script([poll(404, "")]))
    print(show("bucket-not-exists", l3))
    # TableExists: RNF (retry via error) → CREATING (retry via path) → ACTIVE.
    auto l4 = run(
        fast(te),
        new_script(
            [
                poll(400, rnf),
                poll(200, ddb_body("CREATING")),
                poll(200, ddb_body("ACTIVE")),
            ],
        ),
    )
    print(show("table-exists", l4))
    # InstanceRunning: pending (retry) → all running (success via pathAll).
    auto l5 = run(
        fast(ir),
        new_script(
            [
                poll(200, ec2_body("pending", "pending")),
                poll(200, ec2_body("running", "running")),
            ],
        ),
    )
    print(show("instance-running", l5))
    # InstanceRunning: a terminated instance is a terminal failure (pathAny).
    auto l6 = run(fast(ir), new_script([poll(200, ec2_body("terminated", "running"))]))
    print(show("instance-failed", l6))
