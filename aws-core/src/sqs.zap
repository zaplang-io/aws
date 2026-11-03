# aws.sqs — boto3-style SQS messaging conveniences (Queue / Message).
#
# A hand-written ERGONOMICS module (epic #432, D-0001): the boto3
# `sqs = boto3.resource('sqs')` / `queue = sqs.Queue(url)` conveniences over the
# generated low-level SQS client. A `Queue` sends, receives and deletes messages
# without hand-threading the request parameters, and the parsed response shapes
# surface as thin typed `Message` objects. Nothing here re-implements signing or
# the wire codec — it rides on `aws.core` for packaging (the import contract every
# sibling ergonomics module uses) and drives the generated client through a seam,
# exactly as aws.ec2 / aws.batch_writer do.
#
# ## The SQS message-attribute MD5 (the validatable core)
# SQS returns `MD5OfMessageBody` and `MD5OfMessageAttributes` on SendMessage, and
# the AWS SDKs validate them client-side against a locally computed MD5 to detect
# corruption in transit. `MD5OfMessageBody` is a plain MD5 of the body text;
# `MD5OfMessageAttributes` follows the attribute-digest algorithm AWS specifies
# (aws-sdk-java `calculateMessageAttributesMd5`):
#
#   for each attribute, in ascending name order:
#       update(4-byte-BE-len(name)      + name-utf8)
#       update(4-byte-BE-len(dataType)  + dataType-utf8)
#       if String / Number value:  update(byte 1) ; update(4-byte-BE-len + value-utf8)
#       if Binary value:           update(byte 2) ; update(4-byte-BE-len + value-bytes)
#
# `body_md5` / `attributes_md5` implement exactly that (raw bytes assembled with
# `bytes([...])`, digested incrementally with `crypto.md5_new`/`update`/
# `hexdigest`), so a caller can `verify_send(...)` a SendMessage result and raise
# on mismatch — the ergonomic AWS SDKs provide and callers otherwise hand-roll.
#
# ## The client SEAM (mirrors aws.ec2 / aws.batch_writer / aws.waiters)
# The generated SQS client is injected as one closure, `call(op, params) ->
# core.Response`, so this module is independent of any one request builder and is
# driven by a mock client in tests (no live AWS). `params` is the decoded
# request-parameter dict (`QueueUrl`, `MessageBody`, `MessageAttribute.<i>.*`, …)
# the generated client percent-encodes and signs — the same decoded-params
# contract aws.ec2's describe seam uses. The response `body` is the parsed-DOM
# JSON the live adapter projects each SQS response into (`{"MessageId":..,
# "MD5OfMessageBody":..}` for SendMessage, `{"Messages":[{...}, ...]}` for
# ReceiveMessage) — the flat shape the waiter matchers already run over; no nested
# generic collections (zaplang-io/zap#625).
#
# Depends on aws.core (bundled ahead of this file) and aws.sns (the sibling SNS
# publish surface) stands alone.

import core
import base64
import crypto
import json

# Parse a response body into a `JsonValue`, treating an empty body as Null (the
# aws.waiters `parse_body` idiom; a status-only response has no DOM).
def _parse(str body) -> JsonValue:
    if len(body) == 0:
        return JsonValue.Null
    return json.loads(body)

# ---------------------------------------------------------------------------
# Message attributes
# ---------------------------------------------------------------------------

# One SQS message attribute. `data_type` is the SQS data type ("String",
# "Number", or "Binary", possibly with a custom ".suffix"). A String/Number
# attribute carries `string_value`; a Binary attribute carries `binary_value`
# (and `is_binary` selects which — a plain-data field rather than an Optional so
# the value shape stays one the codegen backend already lowers).
struct MessageAttribute:
    str name
    str data_type
    str string_value
    bytes binary_value
    bool is_binary

# A String (or Number) attribute: the common case.
def string_attribute(str name, str data_type, str value) -> MessageAttribute:
    return MessageAttribute(
        name=name,
        data_type=data_type,
        string_value=value,
        binary_value=bytes(),
        is_binary=False,
    )

# A Binary attribute.
def binary_attribute(str name, str data_type, bytes value) -> MessageAttribute:
    return MessageAttribute(
        name=name,
        data_type=data_type,
        string_value="",
        binary_value=value,
        is_binary=True,
    )

# ---------------------------------------------------------------------------
# The MD5 digests SQS returns and the SDKs validate
# ---------------------------------------------------------------------------

# A 4-byte big-endian length prefix (the `writeInt` AWS uses before each field).
def encode_u32_be(int64 n) -> bytes:
    return bytes([n >> 24 & 255, n >> 16 & 255, n >> 8 & 255, n & 255])

# A length-prefixed byte field: 4-byte BE length, then the bytes themselves.
def length_and_bytes(bytes data) -> bytes:
    return encode_u32_be(len(data)) + data

# MD5 of the message body (hex) — SQS's `MD5OfMessageBody`.
def body_md5(str body) -> str:
    return crypto.md5(body)

# Order `attrs` by attribute name (ascending), the order the MD5 is computed in.
# Names are unique within a message, so a name->attribute map keyed through
# `core.sorted_keys` gives the canonical order without a hand-rolled sort.
def sorted_attributes(list[MessageAttribute] attrs) -> list[MessageAttribute]:
    dict[str, MessageAttribute] by_name = {}
    for a in attrs:
        by_name[a.name] = a
    list[MessageAttribute] out = []
    for name in sorted(_names(attrs)):
        Optional[MessageAttribute] got = by_name.get(name)
        if got.is_some():
            out.append(got.unwrap())
    return out

# The attribute names (helper for `sorted_attributes`).
def _names(list[MessageAttribute] attrs) -> list[str]:
    list[str] ns = []
    for a in attrs:
        ns.append(a.name)
    return ns

# MD5 of the message attributes (hex) — SQS's `MD5OfMessageAttributes`, following
# the AWS attribute-digest algorithm (see the module header). The buffer is
# assembled field by field in ascending name order and digested incrementally.
def attributes_md5(list[MessageAttribute] attrs) -> str:
    auto h = crypto.md5_new()
    for a in sorted_attributes(attrs):
        crypto.update(h, length_and_bytes(bytes(a.name)))
        crypto.update(h, length_and_bytes(bytes(a.data_type)))
        if a.is_binary:
            crypto.update(h, bytes([2]))
            crypto.update(h, length_and_bytes(a.binary_value))
        else:
            crypto.update(h, bytes([1]))
            crypto.update(h, length_and_bytes(bytes(a.string_value)))
    return crypto.hexdigest(h)

# ---------------------------------------------------------------------------
# Request-parameter assembly (the decoded params the client percent-encodes)
# ---------------------------------------------------------------------------

# Add the `MessageAttribute.<i>.*` request parameters for `attrs` to `params`
# (1-based, in the caller's order). A Binary value is base64-encoded into
# `BinaryValue`, as the SQS query wire requires (and boto3 does).
def add_attribute_params(dict[str, str] params, list[MessageAttribute] attrs):
    auto i = 1
    for a in attrs:
        auto pfx = "MessageAttribute." + str(i) + "."
        params[pfx + "Name"] = a.name
        params[pfx + "Value.DataType"] = a.data_type
        if a.is_binary:
            params[pfx + "Value.BinaryValue"] = base64.encode(a.binary_value)
        else:
            params[pfx + "Value.StringValue"] = a.string_value
        i = i + 1

# ---------------------------------------------------------------------------
# Typed response shapes
# ---------------------------------------------------------------------------

# The result of a SendMessage: the ids/digests SQS returns.
struct SendResult:
    str message_id
    str md5_of_body
    str md5_of_attributes
    str sequence_number

# A received message (boto3's `Message` resource, as plain data). `.delete()` in
# boto3 is `queue.delete_message(msg.receipt_handle)` here — the receipt handle
# lives on the message, the action on the queue, so the wrapper stays closure-free
# (the aws.ec2 convention: yielded wrappers carry no seam).
struct Message:
    str message_id
    str receipt_handle
    str body
    str md5_of_body
    JsonValue raw

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

# Project a parsed ReceiveMessage message item into a typed `Message`.
def as_message(JsonValue v) -> Message:
    return Message(
        message_id=_field_str(v, "MessageId"),
        receipt_handle=_field_str(v, "ReceiptHandle"),
        body=_field_str(v, "Body"),
        md5_of_body=_field_str(v, "MD5OfBody"),
        raw=v,
    )

# ---------------------------------------------------------------------------
# The Queue resource (boto3's queue = sqs.Queue(url))
# ---------------------------------------------------------------------------

# A queue handle: the queue URL plus the injected client seam. Built from a
# generated SQS client by the live adapter, or from a mock in tests.
struct Queue:
    str url
    fn(str, dict[str, str]) -> core.Response call

    # Send a message with optional attributes. Builds the SendMessage parameters
    # (QueueUrl + MessageBody + MessageAttribute.<i>.*), calls the client, and
    # projects the response into a `SendResult`. The fn-typed field is bound to a
    # local before the call (a direct `self.call(...)` parses as a method call).
    def send_message(self, str body, list[MessageAttribute] attrs) -> SendResult:
        dict[str, str] params = {}
        params["QueueUrl"] = self.url
        params["MessageBody"] = body
        add_attribute_params(params, attrs)
        fn(str, dict[str, str]) -> core.Response c = self.call
        auto resp = c("SendMessage", params)
        auto dom = _parse(resp.body)
        return SendResult(
            message_id=_field_str(dom, "MessageId"),
            md5_of_body=_field_str(dom, "MD5OfMessageBody"),
            md5_of_attributes=_field_str(dom, "MD5OfMessageAttributes"),
            sequence_number=_field_str(dom, "SequenceNumber"),
        )

    # Receive up to `max_number` messages, long-polling `wait_seconds`. Returns
    # the parsed `Message` list (empty when the queue is empty). Defaults
    # (boto3's MaxNumberOfMessages=1) live on the free `receive_from` wrapper, not
    # here — defaulted parameters on struct METHODS are kept explicit per the repo
    # convention (the zap#481 method-default history).
    def receive_messages(self, int64 max_number, int64 wait_seconds) -> list[Message]:
        dict[str, str] params = {}
        params["QueueUrl"] = self.url
        params["MaxNumberOfMessages"] = str(max_number)
        params["WaitTimeSeconds"] = str(wait_seconds)
        fn(str, dict[str, str]) -> core.Response c = self.call
        auto resp = c("ReceiveMessage", params)
        auto dom = _parse(resp.body)
        list[Message] out = []
        for it in _messages_of(dom):
            out.append(as_message(it))
        return out

    # Delete one message by its receipt handle (boto3's `message.delete()`).
    def delete_message(self, str receipt_handle) -> core.Response:
        dict[str, str] params = {}
        params["QueueUrl"] = self.url
        params["ReceiptHandle"] = receipt_handle
        fn(str, dict[str, str]) -> core.Response c = self.call
        return c("DeleteMessage", params)

    # Purge the queue (boto3's `queue.purge()`).
    def purge(self) -> core.Response:
        dict[str, str] params = {}
        params["QueueUrl"] = self.url
        fn(str, dict[str, str]) -> core.Response c = self.call
        return c("PurgeQueue", params)

# The elements of the parsed response's `Messages` array (empty if absent).
def _messages_of(JsonValue dom) -> list[JsonValue]:
    list[JsonValue] out = []
    match dom:
        case JsonValue.Object(fields):
            Optional[JsonValue] f = fields.get("Messages")
            if f.is_some():
                match f.unwrap():
                    case JsonValue.Array(items):
                        out = items
                    case _:
                        out = out
        case _:
            out = out
    return out

# Construct a queue handle from its URL and the client seam.
def queue(str url, fn(str, dict[str, str]) -> core.Response call) -> Queue:
    return Queue(url=url, call=call)

# boto3's default receive (one message, no long poll).
def receive_from(Queue q) -> list[Message]:
    return q.receive_messages(1, 0)

# ---------------------------------------------------------------------------
# Client-side validation (boto3 / the AWS SDKs do this on SendMessage)
# ---------------------------------------------------------------------------

# Whether a SendMessage result's digests match the locally computed MD5s of the
# body and attributes that were sent — the integrity check the AWS SDKs perform.
# A service that omits a digest (e.g. no attributes) matches when the local digest
# is likewise empty, so `""` attributes verify against an empty returned digest.
def send_matches(SendResult r, str body, list[MessageAttribute] attrs) -> bool:
    if r.md5_of_body != body_md5(body):
        return False
    if len(attrs) == 0:
        return len(r.md5_of_attributes) == 0
    return r.md5_of_attributes == attributes_md5(attrs)

# Raise unless the SendMessage result validates (boto3 raises a checksum error).
def verify_send(SendResult r, str body, list[MessageAttribute] attrs):
    if not send_matches(r, body, attrs):
        raise "sqs: MD5 checksum mismatch on SendMessage (message " + r.message_id + ")"
