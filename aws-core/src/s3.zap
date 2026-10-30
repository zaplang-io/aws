# aws.s3 — S3 client (SigV4, virtual-hosted-style).
#
# Depends on aws.core (bundled ahead of this file). S3 exercises the parts of
# SigV4 that DynamoDB does not: a non-"/" canonical URI (the object key path), a
# per-request payload hash in x-amz-content-sha256 (or the literal
# UNSIGNED-PAYLOAD), a query string for listings, and signed object metadata.
#
# Each operation builds an aws.core `Request` and hands it to `sign_request`.
# Operations take keyword arguments with sensible defaults (zaplang-io/zap#298)
# so call sites read like boto3 —
#   s3_put_object(creds, region, bucket, key, body, amz_date, date_stamp,
#                 content_type="text/plain", metadata={"owner": "alice"})
# `metadata` is a `dict[str, str]` that becomes signed `x-amz-meta-*` headers,
# and list options (`prefix`, `max_keys`) are keyword params placed into the
# request's query dict — the signer percent-encodes and sorts them.
#
# CANONICAL-URI: the object key is placed into the path as-is; the signer now
# URI-encodes each path segment (zaplang-io/zap#335), so keys with spaces or
# other reserved characters sign correctly (the v1 "key must be URI-safe" caveat
# is resolved). "/" inside a key stays a separator, matching S3's behavior.

# Virtual-hosted-style host for a bucket: <bucket>.s3.<region>.amazonaws.com.
# Thin shim over aws.endpoints (default options, always bucket-in-host); the
# resolver carries partition/FIPS/dualstack/global and the path-vs-virtual
# choice (see `resolve_s3`).
import core
import endpoints
import errors

def s3_host(str bucket, str region) -> str:
    return endpoints.s3_virtual_host_for(bucket, region, endpoints.default_s3_options())

# Regional S3 endpoint host (path-style / service-level ops): s3.<region>...
# Thin shim over aws.endpoints `s3_service_host`.
def s3_regional_host(str region) -> str:
    return endpoints.s3_service_host(region, endpoints.default_s3_options())

# Canonical object-key path: "/" + key.
def s3_key_path(str key) -> str:
    return "/" + key

# The request path for an object under a resolved S3 endpoint: the bucket path
# prefix (empty for virtual-hosted, "/<bucket>" for path-style) followed by the
# "/<key>" object path. For virtual-hosted buckets this is just "/<key>", so the
# signed request is unchanged from the v1 virtual-hosted-only path.
def s3_object_path(endpoints.S3Endpoint ep, str bucket, str key) -> str:
    return endpoints.s3_path_prefix(ep, bucket) + s3_key_path(key)

# The request path for a bucket-level operation (e.g. ListObjectsV2) under a
# resolved S3 endpoint: "/<bucket>" for path-style, else "/".
def s3_bucket_path(endpoints.S3Endpoint ep, str bucket) -> str:
    auto prefix = endpoints.s3_path_prefix(ep, bucket)
    if len(prefix) == 0:
        return "/"
    return prefix

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
    core.Credentials creds,
    str region,
    str bucket,
    str key,
    str amz_date,
    str date_stamp,
) -> str:
    auto ep = endpoints.resolve_s3(bucket, region, endpoints.default_s3_options())
    auto host = ep.host
    auto sha = core.payload_hash("")
    auto headers = s3_base_headers(host, sha, amz_date)
    dict[str, str] query = {}
    auto req = core.Request(
        method="GET",
        service="s3",
        region=region,
        host=host,
        path=s3_object_path(ep, bucket, key),
        query=query,
        headers=headers,
        body="",
    )
    return core.sign_request(creds, req, amz_date, date_stamp)

# PutObject: PUT /<key> with `body`. `content_type` sets the Content-Type header
# (signed); `metadata` entries become signed `x-amz-meta-<key>` headers (names
# lowercased). Both are optional keyword arguments.
def put_object_request(
    core.Credentials creds,
    str region,
    str bucket,
    str key,
    str body,
    str amz_date,
    str date_stamp,
    str content_type = "application/octet-stream",
    dict[str, str] metadata = {},
) -> str:
    auto ep = endpoints.resolve_s3(bucket, region, endpoints.default_s3_options())
    auto host = ep.host
    auto sha = core.payload_hash(body)
    auto headers = s3_base_headers(host, sha, amz_date)
    headers["content-type"] = content_type
    for name in metadata.keys():
        Optional[str] v = metadata.get(name)
        headers["x-amz-meta-" + name.lower()] = v.unwrap_or("")
    dict[str, str] query = {}
    auto req = core.Request(
        method="PUT",
        service="s3",
        region=region,
        host=host,
        path=s3_object_path(ep, bucket, key),
        query=query,
        headers=headers,
        body=body,
    )
    return core.sign_request(creds, req, amz_date, date_stamp)

# ListObjectsV2: GET /?list-type=2 on the bucket's virtual host. `prefix`
# restricts keys; `max_keys` caps the page size (0 = omit, server default). The
# options go into the request's query dict as decoded values; the signer
# percent-encodes them (so a "/" in `prefix` is sent as %2F, per SigV4).
def list_objects_v2_request(
    core.Credentials creds,
    str region,
    str bucket,
    str amz_date,
    str date_stamp,
    str prefix = "",
    int64 max_keys = 0,
) -> str:
    auto ep = endpoints.resolve_s3(bucket, region, endpoints.default_s3_options())
    auto host = ep.host
    auto sha = core.payload_hash("")
    dict[str, str] params = {}
    params["list-type"] = "2"
    if len(prefix) > 0:
        params["prefix"] = prefix
    if max_keys > 0:
        params["max-keys"] = str(max_keys)
    auto headers = s3_base_headers(host, sha, amz_date)
    auto req = core.Request(
        method="GET",
        service="s3",
        region=region,
        host=host,
        path=s3_bucket_path(ep, bucket),
        query=params,
        headers=headers,
        body="",
    )
    return core.sign_request(creds, req, amz_date, date_stamp)

# ---------------------------------------------------------------------------
# Typed errors (#361) — the per-service enum + classifier aws-codegen emits
# ---------------------------------------------------------------------------
#
# This is the hand-wired S3 proof of the typed-error contract in `errors.zap`
# (DECISIONS.md D-0006): the open-enum shape and the classifier aws-codegen will
# generate for every service from its modeled error shapes. A representative S3
# error set is modeled by name; every other code (new shapes, cross-service
# surprises) lands in `Unknown(code)`, so a caller built against this model keeps
# working when S3 adds an error. These S3 codes are the rest-xml `<Error><Code>`
# spellings botocore maps.

# S3's modeled service errors (a representative subset) + the open-enum catch-all.
enum S3ErrorKind:
    NoSuchKey
    NoSuchBucket
    NoSuchUpload
    BucketAlreadyExists
    BucketAlreadyOwnedByYou
    InvalidObjectState
    EntityTooLarge
    SignatureDoesNotMatch
    AccessDenied
    Unknown(str code)

# Classify an AWS error code into `S3ErrorKind`. The code is normalized first
# (`errors.error_code` strips any namespace/suffix), then matched by name; an
# unmodeled code becomes `Unknown(name)`, carrying the normalized code.
def s3_error_kind(str code) -> S3ErrorKind:
    auto name = errors.error_code(code)
    if name == "NoSuchKey":
        return S3ErrorKind.NoSuchKey
    if name == "NoSuchBucket":
        return S3ErrorKind.NoSuchBucket
    if name == "NoSuchUpload":
        return S3ErrorKind.NoSuchUpload
    if name == "BucketAlreadyExists":
        return S3ErrorKind.BucketAlreadyExists
    if name == "BucketAlreadyOwnedByYou":
        return S3ErrorKind.BucketAlreadyOwnedByYou
    if name == "InvalidObjectState":
        return S3ErrorKind.InvalidObjectState
    if name == "EntityTooLarge":
        return S3ErrorKind.EntityTooLarge
    if name == "SignatureDoesNotMatch":
        return S3ErrorKind.SignatureDoesNotMatch
    if name == "AccessDenied":
        return S3ErrorKind.AccessDenied
    return S3ErrorKind.Unknown(name)

# Convenience: classify straight from a typed carrier.
def s3_error_kind_of(errors.AwsServiceError e) -> S3ErrorKind:
    return s3_error_kind(e.code)

# The canonical name of a classified S3 error. The `match` is exhaustive over
# every variant (the compiler enforces it), so adding a variant to `S3ErrorKind`
# forces this to be updated — the generator emits both together. `Unknown` is
# rendered with its carried code. This dispatcher lives in the service module so
# the `match` is module-local (a caller passes the typed value in and gets the
# name/branch out), which is the portable pattern until the compiler resolves
# module-qualified variant patterns in a caller's own `match` (see DECISIONS.md
# D-0006).
def s3_error_name(S3ErrorKind k) -> str:
    match k:
        case S3ErrorKind.NoSuchKey:
            return "NoSuchKey"
        case S3ErrorKind.NoSuchBucket:
            return "NoSuchBucket"
        case S3ErrorKind.NoSuchUpload:
            return "NoSuchUpload"
        case S3ErrorKind.BucketAlreadyExists:
            return "BucketAlreadyExists"
        case S3ErrorKind.BucketAlreadyOwnedByYou:
            return "BucketAlreadyOwnedByYou"
        case S3ErrorKind.InvalidObjectState:
            return "InvalidObjectState"
        case S3ErrorKind.EntityTooLarge:
            return "EntityTooLarge"
        case S3ErrorKind.SignatureDoesNotMatch:
            return "SignatureDoesNotMatch"
        case S3ErrorKind.AccessDenied:
            return "AccessDenied"
        case S3ErrorKind.Unknown(c):
            return "Unknown(" + c + ")"
