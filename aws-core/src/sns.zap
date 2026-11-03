# aws.sns — boto3-style SNS publish conveniences (Topic).
#
# A hand-written ERGONOMICS module (epic #432, D-0001): the boto3
# `topic = sns.Topic(arn)` / `topic.publish(...)` conveniences over the generated
# low-level SNS client. It builds the Publish request parameters — the topic ARN,
# the message, an optional subject, and the `MessageAttributes.entry.<i>.*`
# parameters (SNS's own attribute wire shape, distinct from SQS's
# `MessageAttribute.<i>.*`) — and projects the response into a typed
# `PublishResult`. Nothing here re-implements signing or the wire codec; it rides
# on `aws.core` for packaging and drives the generated client through the same
# `call(op, params) -> core.Response` seam aws.sqs / aws.ec2 use (a mock client
# in tests, no live AWS). SNS attribute values reuse `aws.sqs.MessageAttribute`
# so a caller models one attribute type for both services.
#
# Depends on aws.core (bundled ahead of this file) and aws.sqs (the shared
# `MessageAttribute` shape).

import core
import base64
import sqs
import json

# Parse a response body into a `JsonValue`, empty body -> Null (the aws.waiters
# idiom).
def _parse(str body) -> JsonValue:
    if len(body) == 0:
        return JsonValue.Null
    return json.loads(body)

# Read a string field out of a parsed JSON object ("" if absent / non-string).
def _field_str(JsonValue v, str name) -> str:
    match v:
        case JsonValue.Object(fields):
            Optional[JsonValue] f = fields.get(name)
            if not f.is_some():
                return ""
            match f.unwrap():
                case JsonValue.Str(s):
                    return s
                case _:
                    return ""
        case _:
            return ""

# ---------------------------------------------------------------------------
# SNS message-attribute request parameters (the `entry.<i>` wire shape)
# ---------------------------------------------------------------------------

# Add the `MessageAttributes.entry.<i>.*` request parameters for `attrs` to
# `params` (1-based). SNS carries attributes as a flattened map entry list — note
# the `entry.<i>` infix, which differs from SQS's indexed `MessageAttribute.<i>`.
# A Binary value is base64-encoded into `BinaryValue` (as SNS requires).
def add_attribute_params(dict[str, str] params, list[sqs.MessageAttribute] attrs):
    auto i = 1
    for a in attrs:
        auto pfx = "MessageAttributes.entry." + str(i) + "."
        params[pfx + "Name"] = a.name
        params[pfx + "Value.DataType"] = a.data_type
        if a.is_binary:
            params[pfx + "Value.BinaryValue"] = base64.encode(a.binary_value)
        else:
            params[pfx + "Value.StringValue"] = a.string_value
        i = i + 1

# ---------------------------------------------------------------------------
# Typed response shape
# ---------------------------------------------------------------------------

# The result of a Publish: the SNS-assigned message id (and the sequence number
# for FIFO topics).
struct PublishResult:
    str message_id
    str sequence_number

# ---------------------------------------------------------------------------
# The Topic resource (boto3's topic = sns.Topic(arn))
# ---------------------------------------------------------------------------

# A topic handle: the topic ARN plus the injected client seam.
struct Topic:
    str arn
    fn(str, dict[str, str]) -> core.Response call

    # Publish `message` with an optional `subject` ("" to omit) and optional
    # attributes. Builds the Publish parameters, calls the client, and projects
    # the response into a `PublishResult`. The fn-typed field is bound to a local
    # before the call.
    def publish(
        self,
        str message,
        str subject,
        list[sqs.MessageAttribute] attrs,
    ) -> PublishResult:
        dict[str, str] params = {}
        params["TopicArn"] = self.arn
        params["Message"] = message
        if len(subject) > 0:
            params["Subject"] = subject
        add_attribute_params(params, attrs)
        fn(str, dict[str, str]) -> core.Response c = self.call
        auto resp = c("Publish", params)
        auto dom = _parse(resp.body)
        return PublishResult(
            message_id=_field_str(dom, "MessageId"),
            sequence_number=_field_str(dom, "SequenceNumber"),
        )

# Construct a topic handle from its ARN and the client seam.
def topic(str arn, fn(str, dict[str, str]) -> core.Response call) -> Topic:
    return Topic(arn=arn, call=call)

# boto3's bare `topic.publish(Message=..)` (no subject, no attributes).
def publish_message(Topic t, str message) -> PublishResult:
    list[sqs.MessageAttribute] none = []
    return t.publish(message, "", none)
