# aws.core — shared hand-written core for the Zap AWS SDK.
#
# This module is the "botocore runtime" half of the design (D-0011 §2): the
# bounded, hand-written pieces every service shares — credential resolution,
# SigV4 request signing, endpoint/host resolution, and an HTTPS transport over
# the stdlib `tls` sockets. The per-service modules (aws.s3, aws.dynamodb) build
# requests and hand them to the functions here.
#
# ERGONOMIC REWRITE: the first cut of this core predated several language
# features and had to work around their absence (see FRICTION.md). SigV4
# canonicalization is *generic* here now that the runtime exposes real strings
# and dicts (zaplang-io/zap#284/#285/#299/#281): callers pass a `dict[str,str]`
# of headers and this module lowercases the names, trims the values, sorts them,
# and emits the canonical header block + signed-header list itself — no more
# hand-sorted literal header runs. Numeric wire fields (Content-Length) are
# rendered internally with `str(len(body))` instead of being threaded through
# the API as caller-supplied strings. The signer is still proven byte-for-byte
# against AWS's published vectors in tests/sigv4_vectors.main.zap.
#
# Still pre-normalized (documented limits, unchanged from v1): URI path segments
# and query keys/values must already be URI-safe (no per-segment percent-encode
# helper yet), and `X-Amz-Date`/the scope date are supplied by the caller
# (datetime has no SigV4 strftime yet; FRICTION.md #4).

import crypto
import os
import tls

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

# Resolved AWS credentials. `session_token` is "" when there is no temporary
# session (static keys); `has_session` says whether a token is present and is
# what the signer checks to decide whether to emit the x-amz-security-token
# header. (String `==` now works, but the explicit flag stays: it is the public
# shape callers already build against, and it reads clearly.) Mirrors boto3's
# Credentials object.
struct Credentials:
    str access_key
    str secret_key
    str session_token
    bool has_session

# Resolve credentials from the environment (provider #1 of the D-0011 chain:
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN). This also
# covers Lambda, which injects these. The shared-config-file, IMDSv2, and
# container providers are deferred (D-0011 §5).
def credentials_from_env() -> Credentials:
    auto token = ""
    auto has = False
    if os.hasenv("AWS_SESSION_TOKEN"):
        token = os.getenv("AWS_SESSION_TOKEN")
        has = True
    return Credentials(
        access_key=os.getenv("AWS_ACCESS_KEY_ID"),
        secret_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
        session_token=token,
        has_session=has,
    )

# Build Credentials from literal values. Pass `session_token` for temporary
# (session) credentials; omit it for static keys. `has_session` is derived.
def credentials(str access_key, str secret_key, str session_token = "") -> Credentials:
    auto has = len(session_token) > 0
    return Credentials(
        access_key=access_key,
        secret_key=secret_key,
        session_token=session_token,
        has_session=has,
    )

# Back-compat alias for the v1 three-argument constructor. `credentials` with a
# non-empty `session_token` is the preferred form.
def credentials_with_token(
    str access_key,
    str secret_key,
    str session_token,
) -> Credentials:
    return credentials(access_key, secret_key, session_token)

# ---------------------------------------------------------------------------
# Payload hashing
# ---------------------------------------------------------------------------

# The SigV4 "x-amz-content-sha256" value for a body: the lowercase hex SHA-256
# of the payload. For an empty body this is the well-known e3b0c442...7852b855.
def payload_hash(str body) -> str:
    return crypto.sha256(body)

# S3 accepts the literal "UNSIGNED-PAYLOAD" in place of a body hash to skip
# hashing large/streaming uploads (the body is still protected by TLS).
def unsigned_payload() -> str:
    return "UNSIGNED-PAYLOAD"

# The decimal Content-Length of a body. Rendered here with `str(len(body))`
# (zaplang-io/zap#285) — v1 could not turn an int into a string, so the length
# used to be threaded through every service API as a caller-supplied string.
def content_length(str body) -> str:
    return str(len(body))

# ---------------------------------------------------------------------------
# Small ordered-string helper
# ---------------------------------------------------------------------------

# Return a sorted copy of `xs` (ascending, byte/codepoint order via `str <`).
# Lists expose only append/index/len/iterate — no `.sort()` — so this is a
# hand-rolled insertion sort. It is written to never index with a negative
# subscript: Zap's `and`/`or` do NOT short-circuit (FRICTION.md), so a bounds
# check cannot guard an index in the same boolean expression.
def sorted_strings(list[str] xs) -> list[str]:
    list[str] out = []
    for x in xs:
        out.append(x)
    auto n = len(out)
    auto i = 1
    while i < n:
        auto key = out[i]
        auto j = i - 1
        auto placed = False
        while not placed:
            if j < 0:
                placed = True
            else:
                auto cur = out[j]
                if key < cur:
                    out[j + 1] = cur
                    j = j - 1
                else:
                    placed = True
        out[j + 1] = key
        i = i + 1
    return out

# The sorted key list of a string dict (used to canonicalize headers/params
# deterministically regardless of the dict's own iteration order).
def sorted_keys(dict[str, str] d) -> list[str]:
    list[str] ks = []
    for k in d.keys():
        ks.append(k)
    return sorted_strings(ks)

# ---------------------------------------------------------------------------
# SigV4 signing-key derivation (D-0011 §5)
# ---------------------------------------------------------------------------

# Derive the SigV4 signing key:
#   kDate    = HMAC("AWS4" + secret, date_stamp)
#   kRegion  = HMAC(kDate, region)
#   kService = HMAC(kRegion, service)
#   kSigning = HMAC(kService, "aws4_request")
# Each step feeds the previous step's RAW digest bytes as the next key — exactly
# what crypto.hmac_sha256_raw (I#153) was added for. `date_stamp` is YYYYMMDD.
def signing_key(str secret, str date_stamp, str region, str service) -> bytes:
    auto k_date = crypto.hmac_sha256_raw("AWS4" + secret, date_stamp)
    auto k_region = crypto.hmac_sha256_raw(k_date, region)
    auto k_service = crypto.hmac_sha256_raw(k_region, service)
    return crypto.hmac_sha256_raw(k_service, "aws4_request")

# The credential scope string: "YYYYMMDD/region/service/aws4_request".
def credential_scope(str date_stamp, str region, str service) -> str:
    return date_stamp + "/" + region + "/" + service + "/aws4_request"

# ---------------------------------------------------------------------------
# Canonical headers / query from dicts (the generic SigV4 canonicalization)
# ---------------------------------------------------------------------------

# One "name:value\n" canonical header line (name lowercase, value trimmed).
def header_line(str lower_name, str value) -> str:
    return lower_name + ":" + value + "\n"

# The SigV4 canonical header block for a header dict: each header as
# "name:value\n" with the name lowercased and the value trimmed, the whole block
# sorted by lowercased name. The caller just builds a dict of the headers it
# intends to sign; this does the lowercase/trim/sort SigV4 requires.
def canonical_headers(dict[str, str] headers) -> str:
    auto block = ""
    for name in sorted_keys(headers):
        Optional[str] v = headers.get(name)
        block = block + name.lower() + ":" + v.unwrap_or("").strip() + "\n"
    return block

# The ";"-joined, sorted, lowercased signed-header name list for a header dict.
def signed_headers(dict[str, str] headers) -> str:
    auto out = ""
    auto first = True
    for name in sorted_keys(headers):
        if first:
            out = name.lower()
            first = False
        else:
            out = out + ";" + name.lower()
    return out

# The SigV4 canonical query string for a parameter dict: "key=value" pairs,
# sorted by key, joined with "&". Keys and values must already be URI-encoded
# (no percent-encode helper yet; see the module header). Returns "" for an empty
# parameter set.
def canonical_query(dict[str, str] params) -> str:
    auto out = ""
    auto first = True
    for key in sorted_keys(params):
        Optional[str] v = params.get(key)
        auto pair = key + "=" + v.unwrap_or("")
        if first:
            out = pair
            first = False
        else:
            out = out + "&" + pair
    return out

# ---------------------------------------------------------------------------
# Canonical request + string-to-sign + signature (D-0011 §5)
# ---------------------------------------------------------------------------

# Assemble the SigV4 canonical request from already-canonical pieces:
#   method \n uri \n query \n canonical_headers \n signed_headers \n payload_sha
def canonical_request(
    str method,
    str uri,
    str query,
    str canon_headers,
    str signed_header_list,
    str payload_sha,
) -> str:
    return method + "\n" + uri + "\n" + query + "\n" + canon_headers + "\n" + signed_header_list + "\n" + payload_sha

# The SigV4 string-to-sign:
#   "AWS4-HMAC-SHA256" \n amz_date \n credential_scope \n hex(sha256(canon_req))
# `amz_date` is the full ISO basic timestamp YYYYMMDDTHHMMSSZ.
def string_to_sign(str amz_date, str cred_scope, str canon_req) -> str:
    return "AWS4-HMAC-SHA256" + "\n" + amz_date + "\n" + cred_scope + "\n" + crypto.sha256(canon_req)

# The final hex signature = HMAC-SHA256(signing_key, string_to_sign).
def sign(bytes key, str sts) -> str:
    return crypto.hmac_sha256(key, sts)

# The value for the HTTP `Authorization` header.
def authorization_header(
    str access_key,
    str cred_scope,
    str signed_header_list,
    str signature,
) -> str:
    return "AWS4-HMAC-SHA256 Credential=" + access_key + "/" + cred_scope + ", SignedHeaders=" + signed_header_list + ", Signature=" + signature

# ---------------------------------------------------------------------------
# One-call request signing + HTTP/1.1 assembly
# ---------------------------------------------------------------------------

# The wire header run for a signed-header dict: "name: value\r\n" per header,
# names lowercased, sorted. AWS treats header names case-insensitively, so the
# canonical lowercase spelling is used verbatim on the wire too.
def wire_headers(dict[str, str] headers) -> str:
    auto out = ""
    for name in sorted_keys(headers):
        Optional[str] v = headers.get(name)
        out = out + name.lower() + ": " + v.unwrap_or("") + "\r\n"
    return out

# Sign a request described by its headers dict and return ready-to-send
# HTTP/1.1 text. `headers` maps the (lowercase) header names to sign -> values;
# the caller includes host, x-amz-date, x-amz-content-sha256, and any
# service-specific headers (x-amz-target, content-type, x-amz-meta-*, ...). The
# x-amz-security-token header is injected here when the credentials carry a
# session. `payload_sha` is the x-amz-content-sha256 value (body hash or
# UNSIGNED-PAYLOAD) and must match the header. `query` is the canonical query
# string (from canonical_query) or "". Content-Length is computed from `body`.
#
# The wire request carries the signed headers, then Content-Length, then
# Authorization (Connection: close is added by http_request_text). Only the
# headers in `headers` are signed.
def sign_request(
    Credentials creds,
    str region,
    str service,
    str method,
    str path,
    str query,
    str body,
    str payload_sha,
    str amz_date,
    str date_stamp,
    dict[str, str] headers,
) -> str:
    auto to_sign = headers.copy()
    if creds.has_session:
        to_sign["x-amz-security-token"] = creds.session_token

    auto canon = canonical_headers(to_sign)
    auto shead = signed_headers(to_sign)
    auto creq = canonical_request(method, path, query, canon, shead, payload_sha)
    auto cred_scope = credential_scope(date_stamp, region, service)
    auto sts = string_to_sign(amz_date, cred_scope, creq)
    auto key = signing_key(creds.secret_key, date_stamp, region, service)
    auto signature = sign(key, sts)
    auto auth = authorization_header(creds.access_key, cred_scope, shead, signature)

    auto headers_block = wire_headers(to_sign) + "content-length: " + content_length(body) + "\r\n" + "authorization: " + auth + "\r\n"
    auto target = path
    if len(query) > 0:
        target = path + "?" + query
    return http_request_text(method, target, headers_block, body)

# ---------------------------------------------------------------------------
# Endpoint / host resolution (D-0011 §6 — simple template, no ruleset engine)
# ---------------------------------------------------------------------------

# Regional host for a global-style service, e.g. ("dynamodb","us-east-1") ->
# "dynamodb.us-east-1.amazonaws.com".
def regional_host(str service, str region) -> str:
    return service + "." + region + ".amazonaws.com"

# Virtual-hosted-style S3 host for a bucket, e.g.
# ("my-bucket","us-east-1") -> "my-bucket.s3.us-east-1.amazonaws.com".
def s3_virtual_host(str bucket, str region) -> str:
    return bucket + ".s3." + region + ".amazonaws.com"

# ---------------------------------------------------------------------------
# HTTPS transport over the stdlib tls sockets (D-0011 §6)
# ---------------------------------------------------------------------------

# Send a fully-formed HTTP/1.1 request string over a verified TLS connection to
# `host`:443 and return the raw response text (status line + headers + body).
# The AWS endpoints honor our `Connection: close`, so we read until EOF.
def send_https(str host, str raw_request) -> str:
    auto conn = tls.connect(host, 443)
    tls.send(conn, raw_request)
    auto out = ""
    auto chunk = tls.recv(conn, 65536)
    auto remaining = 64
    for i in range(0, remaining):
        out = out + chunk
        chunk = tls.recv(conn, 65536)
    tls.close_conn(conn)
    return out

# Build a raw HTTP/1.1 request from its parts. `headers_block` is the already
# assembled "name: value\r\n"... run (including the signed AWS headers,
# Content-Length and Authorization); the request line + Connection: close
# framing + the blank-line/body separator are added here.
def http_request_text(str method, str path, str headers_block, str body) -> str:
    return method + " " + path + " HTTP/1.1\r\n" + headers_block + "Connection: close\r\n" + "\r\n" + body
