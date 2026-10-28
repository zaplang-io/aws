# aws.dynamodb — DynamoDB client, thin vertical v1 (awsJson 1.0 protocol).
#
# Depends on aws.core (bundled ahead of this file; see FRICTION.md #1 on why
# there is no `import aws.core` yet). DynamoDB is the cleanest first service for
# the thin vertical: the awsJson protocol puts everything in the body, the path
# is always "/", there is no query string, and the header set is fixed — so no
# percent-encoding or runtime header sorting is needed (both unavailable today).
#
# v1 operations: get_item, put_item. Requests are signed with SigV4 and returned
# as ready-to-send HTTP/1.1 text; aws.core.send_https delivers them.
#
# AttributeValue JSON is built by concatenation (the runtime has no JSON string
# escaping / int->str yet), so string attribute values must not contain
# characters needing JSON escaping. Richer item building waits on the json
# derive + string work (FRICTION.md).

# awsJson 1.0 content type and the DynamoDB target prefix (API version).
def ddb_content_type() -> str:
    return "application/x-amz-json-1.0"

def ddb_target(str op) -> str:
    return "DynamoDB_20120810." + op

# --- request body builders (string-keyed AttributeValues) ------------------

# {"name":{"S":"value"}} — one string ("S") attribute fragment.
def ddb_attr_s(str name, str value) -> str:
    return "\"" + name + "\":{\"S\":\"" + value + "\"}"

# {"name":{"N":"value"}} — one number ("N") attribute fragment (value is the
# decimal digits as a string, since there is no int->str at runtime).
def ddb_attr_n(str name, str value) -> str:
    return "\"" + name + "\":{\"N\":\"" + value + "\"}"

# GetItem body: {"TableName":"T","Key":{"<key_name>":{"S":"<key_value>"}}}.
def get_item_body(str table, str key_name, str key_value) -> str:
    return (
        "{\"TableName\":\""
        + table
        + "\",\"Key\":{"
        + ddb_attr_s(key_name, key_value)
        + "}}"
    )

# PutItem body from a pre-built item object body (the "{...}" of attribute
# fragments, joined with commas by the caller):
#   {"TableName":"T","Item":{<item_attrs>}}
def put_item_body(str table, str item_attrs) -> str:
    return (
        "{\"TableName\":\""
        + table
        + "\",\"Item\":{"
        + item_attrs
        + "}}"
    )

# --- SigV4-signed request assembly -----------------------------------------

# Sign a DynamoDB request and return the full HTTP/1.1 request text, ready for
# aws.core.send_https(host, text). `op` is e.g. "GetItem"/"PutItem", `body` the
# awsJson body, `amz_date` the YYYYMMDDTHHMMSSZ timestamp, `date_stamp` the
# YYYYMMDD scope date, and `content_length` len(body) rendered as a decimal
# string (threaded in because the runtime has no int->str; FRICTION.md).
def ddb_signed_request(
    Credentials creds,
    str region,
    str op,
    str body,
    str amz_date,
    str date_stamp,
    str content_length,
) -> str:
    auto host = regional_host("dynamodb", region)
    auto body_sha = payload_hash(body)
    auto ctype = ddb_content_type()
    auto target = ddb_target(op)

    # Canonical headers MUST be lowercase, newline-terminated, and sorted by
    # name. We write them in that order by hand: content-type, host,
    # x-amz-content-sha256, x-amz-date, [x-amz-security-token,] x-amz-target.
    auto canon_headers = ""
    auto signed_headers = ""
    if creds.has_session:
        canon_headers = (
            header_line("content-type", ctype)
            + header_line("host", host)
            + header_line("x-amz-content-sha256", body_sha)
            + header_line("x-amz-date", amz_date)
            + header_line("x-amz-security-token", creds.session_token)
            + header_line("x-amz-target", target)
        )
        signed_headers = (
            "content-type;host;x-amz-content-sha256;x-amz-date;"
            + "x-amz-security-token;x-amz-target"
        )
    else:
        canon_headers = (
            header_line("content-type", ctype)
            + header_line("host", host)
            + header_line("x-amz-content-sha256", body_sha)
            + header_line("x-amz-date", amz_date)
            + header_line("x-amz-target", target)
        )
        signed_headers = (
            "content-type;host;x-amz-content-sha256;x-amz-date;x-amz-target"
        )

    auto creq = canonical_request(
        "POST", "/", "", canon_headers, signed_headers, body_sha
    )
    auto cred_scope = credential_scope(date_stamp, region, "dynamodb")
    auto sts = string_to_sign(amz_date, cred_scope, creq)
    auto key = signing_key(creds.secret_key, date_stamp, region, "dynamodb")
    auto signature = sign(key, sts)
    auto auth = authorization_header(
        creds.access_key, cred_scope, signed_headers, signature
    )

    # Wire headers (casing is cosmetic; AWS lowercases for verification). The
    # security-token header is included on the wire only when present.
    auto token_header = ""
    if creds.has_session:
        token_header = "X-Amz-Security-Token: " + creds.session_token + "\r\n"
    auto headers_block = (
        "Host: " + host + "\r\n"
        + "Content-Type: " + ctype + "\r\n"
        + "X-Amz-Date: " + amz_date + "\r\n"
        + "X-Amz-Content-Sha256: " + body_sha + "\r\n"
        + "X-Amz-Target: " + target + "\r\n"
        + "Content-Length: " + content_length + "\r\n"
        + token_header
        + "Authorization: " + auth + "\r\n"
    )
    return http_request_text("POST", "/", headers_block, body)

# Convenience: build + sign a GetItem request in one call.
def get_item_request(
    Credentials creds,
    str region,
    str table,
    str key_name,
    str key_value,
    str amz_date,
    str date_stamp,
    str content_length,
) -> str:
    auto body = get_item_body(table, key_name, key_value)
    return ddb_signed_request(
        creds, region, "GetItem", body, amz_date, date_stamp, content_length
    )
