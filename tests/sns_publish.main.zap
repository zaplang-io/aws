# Offline SNS publish test — exercises aws.sns (boto3-style Topic.publish over the
# generated SNS client) deterministically and pins the output in
# tests/expected/sns_publish.expected. No live AWS: a mock client records the
# request parameters it was handed and returns a canned Publish body, through the
# same `call(op, params)` seam the generated client fills (mirrors
# tests/ec2_resources.main.zap / tests/sqs_messaging.main.zap).
#
# Asserts: the Publish parameters for a bare message and for a message with a
# subject + mixed String/Number/Binary attributes (the SNS `entry.<i>` attribute
# wire shape, with the Binary value base64-encoded), printed in sorted-key order
# for determinism, plus the parsed MessageId.
#
# Run: tools/run-tests.sh (via `zap run`) with the aws_core zenv active.

import aws_core.core
import aws_core.sqs
import aws_core.sns

# --- mock SNS client --------------------------------------------------------

# Records the last params dict it was called with (a single-element list so the
# captured reference sees the write) and returns a canned Publish body.
struct FakeSns:
    str body
    list[dict[str, str]] last

def new_fake(str body) -> FakeSns:
    list[dict[str, str]] seed = []
    return FakeSns(body=body, last=seed)

def fake_call(FakeSns f, str op, dict[str, str] params) -> core.Response:
    f.last.append(params)
    return core.Response(status=200, headers={}, body=f.body)

def over(FakeSns f, str arn) -> sns.Topic:
    auto fake = f
    fn(str, dict[str, str]) -> core.Response call = lambda op, params: fake_call(fake, op, params)
    return sns.topic(arn, call)

# Print a params dict one `key=value` per line, in sorted-key order.
def show_params(dict[str, str] params):
    for k in core.sorted_keys(params):
        Optional[str] v = params.get(k)
        print(k + "=" + v.unwrap_or(""))

def main():
    auto arn = "arn:aws:sns:us-east-1:123456789012:demo"

    # --- bare message ------------------------------------------------------
    print("== publish message only ==")
    auto f1 = new_fake("{\"MessageId\": \"msg-sns-1\"}")
    auto t1 = over(f1, arn)
    auto r1 = t1.publish("hello there", "", [])
    show_params(f1.last[0])
    print("id=" + r1.message_id)

    # --- subject + mixed attributes ----------------------------------------
    print("== publish subject + attrs ==")
    auto f2 = new_fake("{\"MessageId\": \"msg-sns-2\"}")
    auto t2 = over(f2, arn)
    list[sqs.MessageAttribute] attrs = [
        sqs.string_attribute("env", "String", "prod"),
        sqs.string_attribute("priority", "Number", "5"),
        sqs.binary_attribute("blob", "Binary", bytes([1, 2, 3])),
    ]
    auto r2 = t2.publish("full payload", "Daily", attrs)
    show_params(f2.last[0])
    print("id=" + r2.message_id)
