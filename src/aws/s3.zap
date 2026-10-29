# aws.s3 — S3 client (SigV4, virtual-hosted-style).
#
# Depends on aws.core (bundled ahead of this file). S3 exercises the parts of
# SigV4 that DynamoDB does not: a non-"/" canonical URI (the object key path), a
# per-request payload hash in x-amz-content-sha256 (or the literal
# UNSIGNED-PAYLOAD), a query string for listings, and signed object metadata.
#
# ERGONOMIC REWRITE: the operations now take keyword arguments with sensible
# defaults (zaplang-io/zap#298) so call sites read like boto3 —
#   s3_put_object(creds, region, bucket, key, body, amz_date, date_stamp,
#                 content_type="text/plain", metadata={"owner": "alice"})
# `metadata` is a `dict[str, str]` that becomes signed `x-amz-meta-*` headers,
# and list options (`prefix`, `max_keys`) are keyword params turned into a
# canonical query via a dict. Content-Length is computed from the body, not
# threaded through the API.
#
# CANONICAL-URI CAVEAT (unchanged): the object key is placed into the path
# as-is. Real SigV4 URI-encodes each path segment; there is no per-segment
# percent-encode helper yet (FRICTION.md), so this is correct only for keys
# whose characters are already URI-safe (A-Z a-z 0-9 - _ . ~ and "/").

# Virtual-hosted-style host for a bucket: <bucket>.s3.<region>.amazonaws.com.
def s3_host(str bucket, str region) -> str:
    return bucket + ".s3." + region + ".amazonaws.com"

# Regional S3 endpoint host (path-style / service-level ops): s3.<region>...
def s3_regional_host(str region) -> str:
    return "s3." + region + ".amazonaws.com"

# Canonical object-key path: "/" + key (see CANONICAL-URI CAVEAT above).
def s3_key_path(str key) -> str:
    return "/" + key

# The base signed header set for an S3 request: host, the payload hash, and the
# date. Callers add content-type / x-amz-meta-* as needed.
def s3_base_headers(str host, str payload_sha, str amz_date) -> dict[str, str]:
    dict[str, str] h = {}
    h["host"] = host
    h["x-amz-content-sha256"] = payload_sha
    h["x-amz-date"] = amz_date
    return h

# GetObject: GET /<key> on the bucket's virtual host (empty body).
def get_object_request(
    Credentials creds,
    str region,
    str bucket,
    str key,
    str amz_date,
    str date_stamp,
) -> str:
    auto host = s3_host(bucket, region)
    auto sha = payload_hash("")
    auto headers = s3_base_headers(host, sha, amz_date)
    return sign_request(
        creds,
        region,
        "s3",
        "GET",
        s3_key_path(key),
        "",
        "",
        sha,
        amz_date,
        date_stamp,
        headers,
    )

# PutObject: PUT /<key> with `body`. `content_type` sets the Content-Type header
# (signed); `metadata` entries become signed `x-amz-meta-<key>` headers (names
# lowercased). Both are optional keyword arguments.
def put_object_request(
    Credentials creds,
    str region,
    str bucket,
    str key,
    str body,
    str amz_date,
    str date_stamp,
    str content_type = "application/octet-stream",
    dict[str, str] metadata = {},
) -> str:
    auto host = s3_host(bucket, region)
    auto sha = payload_hash(body)
    auto headers = s3_base_headers(host, sha, amz_date)
    headers["content-type"] = content_type
    for name in metadata.keys():
        Optional[str] v = metadata.get(name)
        headers["x-amz-meta-" + name.lower()] = v.unwrap_or("")
    return sign_request(
        creds,
        region,
        "s3",
        "PUT",
        s3_key_path(key),
        "",
        body,
        sha,
        amz_date,
        date_stamp,
        headers,
    )

# ListObjectsV2: GET /?list-type=2 on the bucket's virtual host. `prefix`
# restricts keys; `max_keys` caps the page size (0 = omit, server default).
def list_objects_v2_request(
    Credentials creds,
    str region,
    str bucket,
    str amz_date,
    str date_stamp,
    str prefix = "",
    int64 max_keys = 0,
) -> str:
    auto host = s3_host(bucket, region)
    auto sha = payload_hash("")
    dict[str, str] params = {}
    params["list-type"] = "2"
    if len(prefix) > 0:
        params["prefix"] = prefix
    if max_keys > 0:
        params["max-keys"] = str(max_keys)
    auto query = canonical_query(params)
    auto headers = s3_base_headers(host, sha, amz_date)
    return sign_request(
        creds,
        region,
        "s3",
        "GET",
        "/",
        query,
        "",
        sha,
        amz_date,
        date_stamp,
        headers,
    )
