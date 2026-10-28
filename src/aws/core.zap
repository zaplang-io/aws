# aws.core — shared hand-written core for the Zap AWS SDK (thin vertical v1).
#
# This module is the "botocore runtime" half of the design (D-0011 §2): the
# bounded, hand-written pieces every service shares — credential resolution,
# SigV4 request signing, endpoint/host resolution, and an HTTPS transport over
# the stdlib `tls` sockets. The per-service modules (aws.s3, aws.dynamodb) build
# requests and hand them to the functions here.
#
# SCOPE NOTE (v1 is a hand-written thin vertical, not the codegen generator):
# AWS SigV4 is normally computed by *canonicalizing* a request — percent-encoding
# the path, lowercasing + sorting header names, trimming header values. The Zap
# runtime today exposes almost no string surgery (no indexing, slicing, char
# access, case conversion, comparison, or int->str; see FRICTION.md). So the
# canonicalization here works on inputs the caller has already normalized:
# header names are written as lowercase literals in a fixed sorted order, and the
# URI/query are expected pre-encoded. Everything in this file is built with the
# operations that DO work at runtime: string concatenation (`+`), `crypto`, and
# `os.getenv`. The signer is proven byte-for-byte against AWS's published vectors
# in tests/sigv4_vectors.main.zap.
#
# When imports + richer strings land, this file splits cleanly into an importable
# `aws-core` package and the generator emits per-service clients on top of it.

import crypto
import os
import tls

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

# Resolved AWS credentials. `session_token` is "" when there is no temporary
# session (static keys); `has_session` says whether a token is present. The
# explicit bool exists because the runtime cannot compare strings yet (no
# `session_token == ""`; see FRICTION.md), and the signer must know whether to
# emit the x-amz-security-token header. This mirrors boto3's Credentials object.
struct Credentials:
    str access_key
    str secret_key
    str session_token
    bool has_session

# Resolve credentials from the environment (provider #1 of the D-0011 chain:
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN). This also
# covers Lambda, which injects these. The shared-config-file, IMDSv2, and
# container providers are deferred (they need string parsing / IMDS calls that
# the thin vertical does not yet implement; see FRICTION.md and D-0011 §5).
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

# Build Credentials from literal values (for examples/tests or explicit config).
def credentials(str access_key, str secret_key) -> Credentials:
    return Credentials(
        access_key=access_key,
        secret_key=secret_key,
        session_token="",
        has_session=False,
    )

# Build temporary (session) Credentials, including a security token.
def credentials_with_token(
    str access_key, str secret_key, str session_token
) -> Credentials:
    return Credentials(
        access_key=access_key,
        secret_key=secret_key,
        session_token=session_token,
        has_session=True,
    )

# ---------------------------------------------------------------------------
# Payload hashing
# ---------------------------------------------------------------------------

# The SigV4 "x-amz-content-sha256" value for a body. Returns the lowercase hex
# SHA-256 of the payload. For an empty body this is the well-known
# e3b0c442...b7852b855.
def payload_hash(str body) -> str:
    return crypto.sha256(body)

# S3 accepts the literal "UNSIGNED-PAYLOAD" in place of a body hash to skip
# hashing large/streaming uploads (the body is still protected by TLS).
def unsigned_payload() -> str:
    return "UNSIGNED-PAYLOAD"

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
def signing_key(
    str secret, str date_stamp, str region, str service
) -> bytes:
    auto k_date = crypto.hmac_sha256_raw("AWS4" + secret, date_stamp)
    auto k_region = crypto.hmac_sha256_raw(k_date, region)
    auto k_service = crypto.hmac_sha256_raw(k_region, service)
    return crypto.hmac_sha256_raw(k_service, "aws4_request")

# The credential scope string: "YYYYMMDD/region/service/aws4_request".
def credential_scope(str date_stamp, str region, str service) -> str:
    return date_stamp + "/" + region + "/" + service + "/aws4_request"

# ---------------------------------------------------------------------------
# Canonical request + string-to-sign + signature (D-0011 §5)
# ---------------------------------------------------------------------------

# Assemble the SigV4 canonical request from already-canonical pieces:
#   method \n uri \n query \n canonical_headers \n signed_headers \n payload_sha
# `canonical_headers` must be the "name:value\n" block (each line terminated by
# \n, names lowercase, sorted); `signed_headers` the ";"-joined lowercase names.
def canonical_request(
    str method,
    str uri,
    str query,
    str canonical_headers,
    str signed_headers,
    str payload_sha,
) -> str:
    return (
        method
        + "\n"
        + uri
        + "\n"
        + query
        + "\n"
        + canonical_headers
        + "\n"
        + signed_headers
        + "\n"
        + payload_sha
    )

# One "name:value\n" canonical header line.
def header_line(str lower_name, str value) -> str:
    return lower_name + ":" + value + "\n"

# The SigV4 string-to-sign:
#   "AWS4-HMAC-SHA256" \n amz_date \n credential_scope \n hex(sha256(canon_req))
# `amz_date` is the full ISO basic timestamp YYYYMMDDTHHMMSSZ.
def string_to_sign(
    str amz_date, str cred_scope, str canon_req
) -> str:
    return (
        "AWS4-HMAC-SHA256"
        + "\n"
        + amz_date
        + "\n"
        + cred_scope
        + "\n"
        + crypto.sha256(canon_req)
    )

# The final hex signature = HMAC-SHA256(signing_key, string_to_sign).
def sign(bytes key, str sts) -> str:
    return crypto.hmac_sha256(key, sts)

# The value for the HTTP `Authorization` header.
def authorization_header(
    str access_key, str cred_scope, str signed_headers, str signature
) -> str:
    return (
        "AWS4-HMAC-SHA256 Credential="
        + access_key
        + "/"
        + cred_scope
        + ", SignedHeaders="
        + signed_headers
        + ", Signature="
        + signature
    )

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
# The stdlib `tls` client rides the netpoller; we send the request and read
# until the peer closes (the AWS endpoints honor our `Connection: close`).
#
# Response PARSING (splitting status/headers/body) needs string indexing/slicing
# that the runtime does not expose yet (FRICTION.md), so v1 returns the raw text
# and leaves parsing to the caller / a future richer-strings follow-up.
def send_https(str host, str raw_request) -> str:
    auto conn = tls.connect(host, 443)
    tls.send(conn, raw_request)
    auto out = ""
    auto chunk = tls.recv(conn, 65536)
    auto remaining = 64
    # Read in a bounded loop until a recv returns empty (peer closed) or the cap
    # is hit. `recv` returns "" at EOF.
    for i in range(0, remaining):
        out = out + chunk
        chunk = tls.recv(conn, 65536)
    tls.close_conn(conn)
    return out

# Build a raw HTTP/1.1 request from its parts. `headers_block` is the already
# assembled "Name: value\r\n"... run (including the signed AWS headers); the
# request line + Host + Connection: close framing is added here.
#
# NOTE: Content-Length must appear in `headers_block` and must match len(body).
# The runtime has no int->str yet (FRICTION.md), so the caller supplies the
# length as a string; the service modules thread it through as `content_length`.
def http_request_text(
    str method, str path, str headers_block, str body
) -> str:
    return (
        method
        + " "
        + path
        + " HTTP/1.1\r\n"
        + headers_block
        + "Connection: close\r\n"
        + "\r\n"
        + body
    )
