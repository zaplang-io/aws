# Offline SQS messaging test — exercises aws.sqs (boto3-style Queue/Message over
# the generated SQS client) deterministically and pins the output in
# tests/expected/sqs_messaging.expected. No live AWS: a mock client returns canned
# response bodies through the same `call(op, params)` seam the generated client
# fills (mirrors tests/ec2_resources.main.zap).
#
# The headline assertions are the message-digest computations — body_md5 and the
# attribute-digest md5 (String, the full sorted set, and Binary) — cross-checked
# by an independent hashlib mirror in tools/verify_vectors.py (`sqs`). The send /
# receive / delete flow then rides the seam: SendMessage's client-side MD5
# validation passes against an echoing mock, a tampered digest is caught, and
# ReceiveMessage/DeleteMessage project/thread the canned shapes.
#
# Run: tools/run-tests.sh (via `zap run`) with the aws_core zenv active.

import aws_core.core
import aws_core.sqs

# --- mock SQS client over scripted bodies -----------------------------------

# Canned response bodies keyed by operation, plus a record of the ops seen. A
# single-element-list cursor is not needed (each op has one canned body); the
# fake is a plain lookup.
struct FakeSqs:
    dict[str, str] bodies
    list[str] ops

def new_fake(dict[str, str] bodies) -> FakeSqs:
    return FakeSqs(bodies=bodies, ops=[])

# The call seam: record the op, return its canned body as a 200 ("{}" if none).
def fake_call(FakeSqs f, str op, dict[str, str] params) -> core.Response:
    f.ops.append(op)
    Optional[str] b = f.bodies.get(op)
    return core.Response(status=200, headers={}, body=b.unwrap_or("{}"))

# Build a Queue over a fake client (the fake bound to a local before capture).
def over(FakeSqs f, str url) -> sqs.Queue:
    auto fake = f
    fn(str, dict[str, str]) -> core.Response call = lambda op, params: fake_call(fake, op, params)
    return sqs.queue(url, call)

# --- the attribute sets (match the oracle; deliberately unsorted) -----------

def attrs_all() -> list[sqs.MessageAttribute]:
    return [
        sqs.string_attribute("Population", "Number", "1250800"),
        sqs.string_attribute("City", "String", "Any City"),
        sqs.binary_attribute("Logo", "Binary", bytes([0, 1, 2, 3, 255])),
    ]

def attrs_string() -> list[sqs.MessageAttribute]:
    return [sqs.string_attribute("City", "String", "Any City")]

def attrs_binary() -> list[sqs.MessageAttribute]:
    return [sqs.binary_attribute("Logo", "Binary", bytes([0, 1, 2, 3, 255]))]

def main():
    auto body = "Hello, SQS!"

    # --- the digests (the crypto core, oracle-cross-checked) ---------------
    print("== body md5 ==")
    print(sqs.body_md5(body))
    print("== attributes md5 string ==")
    print(sqs.attributes_md5(attrs_string()))
    print("== attributes md5 all ==")
    print(sqs.attributes_md5(attrs_all()))
    print("== attributes md5 binary ==")
    print(sqs.attributes_md5(attrs_binary()))

    # --- send: the mock echoes the locally computed digests, so the SDK-style
    #     client-side validation passes --------------------------------------
    auto bmd5 = sqs.body_md5(body)
    auto amd5 = sqs.attributes_md5(attrs_all())
    auto send_body = "{\"MessageId\": \"msg-0001\", \"MD5OfMessageBody\": \"" + bmd5 + "\", \"MD5OfMessageAttributes\": \"" + amd5 + "\"}"
    dict[str, str] bodies = {}
    bodies["SendMessage"] = send_body
    auto q = over(
        new_fake(bodies),
        "https://sqs.us-east-1.amazonaws.com/123456789012/demo",
    )
    auto res = q.send_message(body, attrs_all())
    print("== send result ==")
    print(
        "id=" + res.message_id + " body-md5-match=" + str(res.md5_of_body == bmd5) + " attrs-md5-match=" + str(res.md5_of_attributes == amd5),
    )
    print("== verify ==")
    sqs.verify_send(res, body, attrs_all())
    print("ok")

    # --- tampered digest is caught -----------------------------------------
    print("== tampered ==")
    auto bad = sqs.SendResult(
        message_id="msg-0002",
        md5_of_body="00000000000000000000000000000000",
        md5_of_attributes=amd5,
        sequence_number="",
    )
    if sqs.send_matches(bad, body, attrs_all()):
        print("NOT detected")
    else:
        print("mismatch detected")

    # --- receive + delete --------------------------------------------------
    dict[str, str] rbodies = {}
    rbodies["ReceiveMessage"] = "{\"Messages\": [{\"MessageId\": \"m-1\", \"ReceiptHandle\": \"rh-1\", \"Body\": \"first\"}, {\"MessageId\": \"m-2\", \"ReceiptHandle\": \"rh-2\", \"Body\": \"second\"}]}"
    auto q2 = over(
        new_fake(rbodies),
        "https://sqs.us-east-1.amazonaws.com/123456789012/demo",
    )
    print("== receive ==")
    for m in q2.receive_messages(10, 0):
        print(m.message_id + " " + m.receipt_handle + " " + m.body)

    print("== delete ==")
    auto f3 = new_fake({})
    auto q3 = over(f3, "https://sqs.us-east-1.amazonaws.com/123456789012/demo")
    auto ign = q3.delete_message("rh-1")
    for op in f3.ops:
        print(op + " rh-1")
