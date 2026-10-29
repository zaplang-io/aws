# aws.dynamodb — DynamoDB client (awsJson 1.0 protocol).
#
# Depends on aws.core (bundled ahead of this file; see FRICTION.md #1 on why
# there is no `import aws.core` yet). DynamoDB is the cleanest service for the
# hand-written vertical: the awsJson protocol puts everything in the body, the
# path is always "/", there is no query string, and the signed header set is
# small.
#
# Each operation builds an aws.core `Request` and hands it to `sign_request`.
# Items and keys are ordinary `dict[str, str]` maps built at the call site and
# turned into AttributeValue JSON by dict iteration (zaplang-io/zap#299).
# Attribute names are emitted in sorted order so the wire body is deterministic
# regardless of dict iteration order. Numeric ("N") attributes are passed as a
# second dict.
#
# JSON string values must still not contain characters needing JSON escaping
# (no escaping pass yet); numbers are passed as their decimal digits.
#
# v1 operations: get_item, put_item. Requests are SigV4-signed via
# aws.core.sign_request and returned as ready-to-send HTTP/1.1 text.

# awsJson 1.0 content type and the DynamoDB target prefix (API version).
def ddb_content_type() -> str:
    return "application/x-amz-json-1.0"

def ddb_target(str op) -> str:
    return "DynamoDB_20120810." + op

# --- AttributeValue JSON (built from dicts) --------------------------------

# One `"name":{"S":"value"}` string-attribute fragment.
def ddb_attr_s(str name, str value) -> str:
    return "\"" + name + "\":{\"S\":\"" + value + "\"}"

# One `"name":{"N":"value"}` number-attribute fragment (value is the decimal
# digits).
def ddb_attr_n(str name, str value) -> str:
    return "\"" + name + "\":{\"N\":\"" + value + "\"}"

# Render an attribute map as the comma-joined body of a JSON object (no
# surrounding braces): string attributes from `strings`, number attributes from
# `numbers`. Names across both maps are emitted in a single sorted order, so the
# output is deterministic. A name present in both maps is emitted as its string
# form (callers should not overload a name across types).
def ddb_attributes(dict[str, str] strings, dict[str, str] numbers) -> str:
    list[str] names = []
    for k in strings.keys():
        names.append(k)
    for k in numbers.keys():
        if not k in strings:
            names.append(k)
    auto out = ""
    auto first = True
    for name in sorted(names):
        auto frag = ""
        if name in strings:
            Optional[str] sv = strings.get(name)
            frag = ddb_attr_s(name, sv.unwrap_or(""))
        else:
            Optional[str] nv = numbers.get(name)
            frag = ddb_attr_n(name, nv.unwrap_or(""))
        if first:
            out = frag
            first = False
        else:
            out = out + "," + frag
    return out

# GetItem body: {"TableName":"T","Key":{<key attrs>}}.
def get_item_body(str table, dict[str, str] key) -> str:
    dict[str, str] no_numbers = {}
    return "{\"TableName\":\"" + table + "\",\"Key\":{" + ddb_attributes(key, no_numbers) + "}}"

# PutItem body: {"TableName":"T","Item":{<item attrs>}}.
def put_item_body(str table, dict[str, str] strings, dict[str, str] numbers) -> str:
    return "{\"TableName\":\"" + table + "\",\"Item\":{" + ddb_attributes(strings, numbers) + "}}"

# --- operations ------------------------------------------------------------

# The signed header set shared by DynamoDB operations (awsJson, fixed path "/").
def ddb_headers(str host, str body_sha, str amz_date, str op) -> dict[str, str]:
    dict[str, str] h = {}
    h["content-type"] = ddb_content_type()
    h["host"] = host
    h["x-amz-content-sha256"] = body_sha
    h["x-amz-date"] = amz_date
    h["x-amz-target"] = ddb_target(op)
    return h

# GetItem. `key` is the primary key as an attribute map, e.g. {"id": "alice"}
# (reads like boto3's `Key=...`). Returns ready-to-send HTTP/1.1 request text.
def get_item_request(
    Credentials creds,
    str region,
    str table,
    dict[str, str] key,
    str amz_date,
    str date_stamp,
) -> str:
    auto host = regional_host("dynamodb", region)
    auto body = get_item_body(table, key)
    auto body_sha = payload_hash(body)
    auto headers = ddb_headers(host, body_sha, amz_date, "GetItem")
    dict[str, str] query = {}
    auto req = Request(
        method="POST",
        service="dynamodb",
        region=region,
        host=host,
        path="/",
        query=query,
        headers=headers,
        body=body,
    )
    return sign_request(creds, req, amz_date, date_stamp)

# PutItem. `item` is the string attributes as a map (e.g. {"id": "alice",
# "name": "Alice"}); pass `numbers` for numeric ("N") attributes
# (e.g. {"age": "30"}). Returns ready-to-send HTTP/1.1 request text.
def put_item_request(
    Credentials creds,
    str region,
    str table,
    dict[str, str] item,
    str amz_date,
    str date_stamp,
    dict[str, str] numbers = {},
) -> str:
    auto host = regional_host("dynamodb", region)
    auto body = put_item_body(table, item, numbers)
    auto body_sha = payload_hash(body)
    auto headers = ddb_headers(host, body_sha, amz_date, "PutItem")
    dict[str, str] query = {}
    auto req = Request(
        method="POST",
        service="dynamodb",
        region=region,
        host=host,
        path="/",
        query=query,
        headers=headers,
        body=body,
    )
    return sign_request(creds, req, amz_date, date_stamp)
