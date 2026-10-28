# aws.s3 — S3 client, thin vertical v1 (SigV4, virtual-hosted-style).
#
# Depends on aws.core (bundled ahead of this file). S3 exercises the parts of
# SigV4 that DynamoDB does not: a non-"/" canonical URI (the object key path), a
# per-request payload hash in x-amz-content-sha256 (or the literal
# UNSIGNED-PAYLOAD), a query string for listings, and both virtual-hosted and
# path-style hosts.
#
# v1 operations: get_object, put_object, list_objects_v2. Responses for S3 are
# rest-xml; the thin vertical returns the raw response text (no xml module yet —
# D-0011 §4 defers rest-xml parsing). aws.core.send_https delivers the request.
#
# CANONICAL-URI CAVEAT: the object key is placed into the path as-is. Real SigV4
# URI-encodes each path segment (percent-encoding reserved bytes); the runtime
# cannot do per-character encoding yet (FRICTION.md), so v1 is correct only for
# keys whose characters are already URI-safe (A-Z a-z 0-9 - _ . ~ and "/").
# Keys with spaces or other reserved characters need the string work to land.

# Virtual-hosted-style host for a bucket: <bucket>.s3.<region>.amazonaws.com.
def s3_host(str bucket, str region) -> str:
    return bucket + ".s3." + region + ".amazonaws.com"

# Regional S3 endpoint host (path-style / service-level ops like ListBuckets):
# s3.<region>.amazonaws.com.
def s3_regional_host(str region) -> str:
    return "s3." + region + ".amazonaws.com"

# Canonical object-key path: "/" + key (see CANONICAL-URI CAVEAT above).
def s3_key_path(str key) -> str:
    return "/" + key

# --- SigV4-signed request assembly -----------------------------------------

# Sign an S3 request and return ready-to-send HTTP/1.1 text. `host` is the
# chosen endpoint (s3_host / s3_regional_host); `payload_sha` is the hex SHA-256
# of the body or aws.core.unsigned_payload(); `query` is the (pre-encoded,
# sorted) canonical query string or ""; `content_length` is len(body) as a
# decimal string (no int->str at runtime; FRICTION.md). For GET/DELETE with no
# body pass body="" and payload_sha=payload_hash("").
def s3_signed_request(
    Credentials creds,
    str region,
    str host,
    str method,
    str path,
    str query,
    str body,
    str payload_sha,
    str amz_date,
    str date_stamp,
    str content_length,
) -> str:
    # Sorted lowercase canonical header set: host, x-amz-content-sha256,
    # x-amz-date, [x-amz-security-token].
    auto canon_headers = ""
    auto signed_headers = ""
    if creds.has_session:
        canon_headers = (
            header_line("host", host)
            + header_line("x-amz-content-sha256", payload_sha)
            + header_line("x-amz-date", amz_date)
            + header_line("x-amz-security-token", creds.session_token)
        )
        signed_headers = (
            "host;x-amz-content-sha256;x-amz-date;x-amz-security-token"
        )
    else:
        canon_headers = (
            header_line("host", host)
            + header_line("x-amz-content-sha256", payload_sha)
            + header_line("x-amz-date", amz_date)
        )
        signed_headers = "host;x-amz-content-sha256;x-amz-date"

    auto creq = canonical_request(
        method, path, query, canon_headers, signed_headers, payload_sha
    )
    auto cred_scope = credential_scope(date_stamp, region, "s3")
    auto sts = string_to_sign(amz_date, cred_scope, creq)
    auto key = signing_key(creds.secret_key, date_stamp, region, "s3")
    auto signature = sign(key, sts)
    auto auth = authorization_header(
        creds.access_key, cred_scope, signed_headers, signature
    )

    auto token_header = ""
    if creds.has_session:
        token_header = "X-Amz-Security-Token: " + creds.session_token + "\r\n"
    # The request-target includes the query string when present.
    auto target = path
    if len(query) > 0:
        target = path + "?" + query
    auto headers_block = (
        "Host: " + host + "\r\n"
        + "X-Amz-Date: " + amz_date + "\r\n"
        + "X-Amz-Content-Sha256: " + payload_sha + "\r\n"
        + "Content-Length: " + content_length + "\r\n"
        + token_header
        + "Authorization: " + auth + "\r\n"
    )
    return http_request_text(method, target, headers_block, body)

# GetObject: GET /<key> on the bucket's virtual host (empty body).
def get_object_request(
    Credentials creds,
    str region,
    str bucket,
    str key,
    str amz_date,
    str date_stamp,
) -> str:
    return s3_signed_request(
        creds,
        region,
        s3_host(bucket, region),
        "GET",
        s3_key_path(key),
        "",
        "",
        payload_hash(""),
        amz_date,
        date_stamp,
        "0",
    )

# PutObject: PUT /<key> with `body`; `content_length` is len(body) as a string.
def put_object_request(
    Credentials creds,
    str region,
    str bucket,
    str key,
    str body,
    str content_length,
    str amz_date,
    str date_stamp,
) -> str:
    return s3_signed_request(
        creds,
        region,
        s3_host(bucket, region),
        "PUT",
        s3_key_path(key),
        "",
        body,
        payload_hash(body),
        amz_date,
        date_stamp,
        content_length,
    )

# ListObjectsV2: GET /?list-type=2 on the bucket's virtual host.
def list_objects_v2_request(
    Credentials creds,
    str region,
    str bucket,
    str amz_date,
    str date_stamp,
) -> str:
    return s3_signed_request(
        creds,
        region,
        s3_host(bucket, region),
        "GET",
        "/",
        "list-type=2",
        "",
        payload_hash(""),
        amz_date,
        date_stamp,
        "0",
    )
