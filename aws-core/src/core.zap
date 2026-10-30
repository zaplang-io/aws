# aws.core — the protocol-agnostic shared runtime for the Zap AWS SDK.
#
# This module is the "botocore runtime" half of the design (D-0011 §2): the
# bounded, hand-written pieces that ~70% of every AWS service rides on —
# credentials, a Request/Response model, a real SigV4 signer, an HTTPS transport
# over the stdlib `tls` sockets, error dispatch, and pagination hooks. The
# adjacent seams live in their own sibling modules (endpoint/region resolution in
# aws.endpoints #342, retry in aws.retry #343, the full credential chain in
# aws.credentials #341), imported by the consumers that need them so this module
# stays a dependency-free signing/transport base. Per-service modules (aws.s3,
# aws.dynamodb) build a `Request` and hand it here.
#
# PHASE 1 — REAL CANONICALIZATION. The v1 cut of this core predated most of the
# runtime's string surface and worked AROUND the gaps (pre-sorted literal header
# runs, pre-encoded URIs/queries, caller-supplied timestamps). Phase 0 landed the
# missing features, so the signer is now the genuine algorithm:
#   * CanonicalURI  = url.quote_path(path), double-encoded for every service
#     except S3 (AWS disables path normalization for S3) — zaplang-io/zap#335.
#   * CanonicalQuery = url.canonical_query(dict): each key/value percent-encoded
#     (RFC-3986) and the pairs sorted — zaplang-io/zap#335.
#   * Canonical headers: names lowercased, values trimmed, set sorted — generic
#     over a dict[str,str] the caller supplies (zaplang-io/zap#284/#299).
#   * x-amz-date / credential-scope date are built from `datetime` here
#     (zaplang-io/zap#286/#338); the SDK can stamp a live request itself. The v1
#     caller-supplied date env vars are gone (FRICTION #4 resolved).
#   * The payload hash is SHA-256 of the body (crypto.sha256), or the
#     x-amz-content-sha256 the caller set (e.g. UNSIGNED-PAYLOAD).
# The signer is proven byte-for-byte against AWS's published SigV4 vector in
# tests/sigv4_vectors.main.zap and the pinned service requests in
# tests/service_signing.main.zap (both re-derived by an independent oracle in
# tools/verify_vectors.py).

import crypto
import os
import tls
import url
import datetime

# ---------------------------------------------------------------------------
# Credentials (seam — the full provider chain is zaplang-io/zap#341)
# ---------------------------------------------------------------------------

# Resolved AWS credentials. `session_token` is "" when there is no temporary
# session (static keys); `has_session` says whether a token is present and is
# what the signer checks to decide whether to emit the x-amz-security-token
# header. Mirrors boto3's Credentials object. The signer consumes a value of
# this type through the credentials seam, so #341 (ini/profiles, IMDSv2,
# container, process, caching) can slot a richer resolver in behind it without
# touching the signer.
struct Credentials:
    str access_key
    str secret_key
    str session_token
    bool has_session

# Resolve credentials from the environment (provider #1 of the D-0011 chain:
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN). This also
# covers Lambda, which injects these. The shared-config-file, IMDSv2, and
# container providers are deferred to #341.
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
# Request / Response model
# ---------------------------------------------------------------------------

# An unsigned AWS request. Per-service code fills this in and hands it to the
# signer/transport; nothing here is protocol-specific. `query` is a dict of
# *decoded* key→value pairs (the signer percent-encodes them); `headers` maps
# the (lowercase) header names to sign → values (host, x-amz-date,
# x-amz-content-sha256, content-type, x-amz-target, x-amz-meta-*, ...); `body`
# is the raw payload. `service`/`region` drive both signing scope and endpoint
# resolution.
struct Request:
    str method
    str service
    str region
    str host
    str path
    dict[str, str] query
    dict[str, str] headers
    str body

# A parsed HTTP response: numeric status, lowercased header map, and the body.
struct Response:
    int64 status
    dict[str, str] headers
    str body

# Convenience constructor: an empty query/body is the common case (awsJson POSTs
# and S3 object GET/PUT carry none).
def new_request(
    str method,
    str service,
    str region,
    str host,
    str path,
    dict[str, str] headers,
    dict[str, str] query = {},
    str body = "",
) -> Request:
    return Request(
        method=method,
        service=service,
        region=region,
        host=host,
        path=path,
        query=query,
        headers=headers,
        body=body,
    )

# ---------------------------------------------------------------------------
# SigV4 timestamps (datetime — resolves FRICTION #4)
# ---------------------------------------------------------------------------

# The two SigV4 time strings: the `x-amz-date` basic timestamp YYYYMMDDTHHMMSSZ
# and the `YYYYMMDD` credential-scope date.
struct SigningTime:
    str amz_date
    str date_stamp

# Build a SigningTime from explicit strings (used by the pinned tests, which fix
# AWS's published example timestamp for determinism).
def signing_time(str amz_date, str date_stamp) -> SigningTime:
    return SigningTime(amz_date=amz_date, date_stamp=date_stamp)

# The SigV4 timestamps for *now* (UTC), formatted with datetime.strftime
# (zaplang-io/zap#286). This is what lets the SDK sign a live request on its own
# — v1 could not reshape datetime.now() and had to read the timestamp from env
# vars the caller set with `date -u` (FRICTION #4).
def signing_time_now() -> SigningTime:
    auto dt = datetime.now()
    return SigningTime(
        amz_date=datetime.strftime(dt, "%Y%m%dT%H%M%SZ"),
        date_stamp=datetime.strftime(dt, "%Y%m%d"),
    )

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

# The decimal Content-Length of a body.
def content_length(str body) -> str:
    return str(len(body))

# ---------------------------------------------------------------------------
# Small ordered-string helper
# ---------------------------------------------------------------------------

# The sorted key list of a string dict (ascending byte/codepoint order), used to
# canonicalize headers deterministically regardless of the dict's own iteration
# order. v1 hand-rolled an insertion sort because `list` had no `.sort()`; the
# `sorted` builtin (zaplang-io/zap#336) replaces it.
def sorted_keys(dict[str, str] d) -> list[str]:
    list[str] ks = []
    for k in d.keys():
        ks.append(k)
    return sorted(ks)

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
# Canonical headers / query / URI (the generic SigV4 canonicalization)
# ---------------------------------------------------------------------------

# One "name:value\n" canonical header line (name lowercase, value trimmed).
def header_line(str lower_name, str value) -> str:
    return lower_name + ":" + value + "\n"

# The SigV4 canonical header block for a header dict: each header as
# "name:value\n" with the name lowercased and the value trimmed, the whole block
# sorted by lowercased name.
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

# The SigV4 CanonicalQueryString for a parameter dict: each key and value
# percent-encoded (RFC-3986), the pairs sorted and joined with "&". Delegates to
# `url.canonical_query` (zaplang-io/zap#335), so reserved characters in values —
# e.g. a "/" in an S3 `prefix` — are encoded as `%2F`, exactly as botocore does.
# Returns "" for an empty parameter set.
def canonical_query(dict[str, str] params) -> str:
    return url.canonical_query(params)

# The SigV4 CanonicalURI for a path. `url.quote_path` keeps "/" as the segment
# separator and percent-encodes everything else; AWS double-encodes the path for
# every service EXCEPT S3 (which disables path normalization), so non-S3 encodes
# twice. Resolves the v1 "URI must be pre-encoded" caveat (FRICTION #2).
def canonical_uri(str path, str service) -> str:
    auto once = url.quote_path(path)
    if service == "s3":
        return once
    return url.quote_path(once)

# The path as it appears on the HTTP request line: single percent-encoding (the
# double-encoding above is only for the SigV4 signature, never the wire).
def wire_path(str path) -> str:
    return url.quote_path(path)

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

# Sign `req` with `creds` at the given SigV4 timestamps and return ready-to-send
# HTTP/1.1 request text. This is the real SigV4 canonicalization (see the module
# header): the canonical URI and query are percent-encoded here, the header set
# is lowercased/trimmed/sorted, and the payload hash is the caller's
# x-amz-content-sha256 (if set) else SHA-256 of the body. The
# x-amz-security-token header is injected when the credentials carry a session.
# Only the headers in `req.headers` (plus the injected token) are signed.
def sign_request(Credentials creds, Request req, str amz_date, str date_stamp) -> str:
    auto to_sign = req.headers.copy()
    if creds.has_session:
        to_sign["x-amz-security-token"] = creds.session_token

    auto payload_sha = crypto.sha256(req.body)
    Optional[str] psha = to_sign.get("x-amz-content-sha256")
    payload_sha = psha.unwrap_or(payload_sha)

    auto canon_uri_str = canonical_uri(req.path, req.service)
    auto canon_q = url.canonical_query(req.query)
    auto canon = canonical_headers(to_sign)
    auto shead = signed_headers(to_sign)
    auto creq = canonical_request(
        req.method,
        canon_uri_str,
        canon_q,
        canon,
        shead,
        payload_sha,
    )
    auto cred_scope = credential_scope(date_stamp, req.region, req.service)
    auto sts = string_to_sign(amz_date, cred_scope, creq)
    auto key = signing_key(creds.secret_key, date_stamp, req.region, req.service)
    auto signature = sign(key, sts)
    auto auth = authorization_header(creds.access_key, cred_scope, shead, signature)

    auto headers_block = wire_headers(to_sign) + "content-length: " + content_length(req.body) + "\r\n" + "authorization: " + auth + "\r\n"
    auto target = wire_path(req.path)
    if len(canon_q) > 0:
        target = target + "?" + canon_q
    return http_request_text(req.method, target, headers_block, req.body)

# Sign `req` using the current UTC time (the usual live path). Equivalent to
# `sign_request` with `signing_time_now()`.
def sign_request_now(Credentials creds, Request req) -> str:
    auto t = signing_time_now()
    return sign_request(creds, req, t.amz_date, t.date_stamp)

# Build a raw HTTP/1.1 request from its parts. `headers_block` is the already
# assembled "name: value\r\n"... run (including the signed AWS headers,
# Content-Length and Authorization); the request line + Connection: close
# framing + the blank-line/body separator are added here.
def http_request_text(str method, str path, str headers_block, str body) -> str:
    return method + " " + path + " HTTP/1.1\r\n" + headers_block + "Connection: close\r\n" + "\r\n" + body

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

# Parse a raw HTTP/1.1 response into a Response: numeric status from the status
# line, a lowercased header map, and the body after the blank line. Best-effort
# and header-only (no chunked-transfer decode yet); enough for error dispatch
# and retry classification.
def parse_response(str raw) -> Response:
    dict[str, str] hdrs = {}
    auto status = 0
    auto body = ""
    auto head = raw
    auto sep = raw.find("\r\n\r\n")
    if sep >= 0:
        head = raw[0:sep]
        body = raw[sep + 4:len(raw)]
    auto first = True
    for line in head.split("\r\n"):
        if first:
            first = False
            auto parts = line.split(" ")
            if len(parts) >= 2:
                status = int(parts[1])
        else:
            auto colon = line.find(":")
            if colon >= 0:
                auto name = line[0:colon].strip().lower()
                auto value = line[colon + 1:len(line)].strip()
                hdrs[name] = value
    return Response(status=status, headers=hdrs, body=body)

# Send a raw request and return the parsed Response.
def send(str host, str raw_request) -> Response:
    return parse_response(send_https(host, raw_request))

# ---------------------------------------------------------------------------
# Retry seam (D-0011 §7)
# ---------------------------------------------------------------------------
#
# AWS "standard" retry mode — error classification, exponential backoff with
# full jitter, and a retry-quota token bucket wrapped around the sign+send path
# — lives in aws.retry (`retry_send` / `send_request_with_retry`, zaplang-io/
# zap#343), bundled after this module. The v1 baseline (a fixed attempt cap with
# no backoff) that used to sit here has been retired in its favor. Callers that
# want no retries keep using `send` / `send_https` directly.

# ---------------------------------------------------------------------------
# Error dispatch seam
# ---------------------------------------------------------------------------

# A surfaced AWS error. The full per-service error-shape registry (modeled
# exceptions, retry-after, etc.) is future work; this is the typed shape error
# dispatch produces now.
struct AwsError:
    str code
    str message
    int64 status

# Whether an HTTP status is 2xx success.
def is_success(int64 status) -> bool:
    return status >= 200 and status <= 299

# Extract a `"field":"value"` string from a JSON object body (best-effort, no
# full JSON parse — enough to surface an error code/message). Returns the value
# with its surrounding quotes removed, or none.
def json_string_field(str body, str field) -> Optional[str]:
    auto needle = "\"" + field + "\""
    auto k = body.find(needle)
    if k < 0:
        return Optional.None
    auto rest = body[k + len(needle):len(body)]
    auto c = rest.find(":")
    if c < 0:
        return Optional.None
    auto after = rest[c + 1:len(rest)]
    auto q1 = after.find("\"")
    if q1 < 0:
        return Optional.None
    auto tail = after[q1 + 1:len(after)]
    auto q2 = tail.find("\"")
    if q2 < 0:
        return Optional.None
    return Optional.Some(tail[0:q2])

# Extract the text of the first <tag>...</tag> element (best-effort; rest-xml
# error shapes). Returns none if the element is absent.
def xml_element_text(str body, str tag) -> Optional[str]:
    auto open_tag = "<" + tag + ">"
    auto close_tag = "</" + tag + ">"
    auto a = body.find(open_tag)
    if a < 0:
        return Optional.None
    auto start = a + len(open_tag)
    auto rest = body[start:len(body)]
    auto b = rest.find(close_tag)
    if b < 0:
        return Optional.None
    return Optional.Some(rest[0:b])

# Parse an error out of a response. Baseline: no error on 2xx; for awsJson read
# `__type`/`code` + `message`/`Message`, for rest-xml read `<Code>`/`<Message>`.
# Returns none when the status is success.
def parse_error(Response resp) -> Optional[AwsError]:
    if is_success(resp.status):
        return Optional.None
    auto code = ""
    auto message = ""
    Optional[str] jtype = json_string_field(resp.body, "__type")
    code = jtype.unwrap_or(code)
    Optional[str] jcode = json_string_field(resp.body, "code")
    code = jcode.unwrap_or(code)
    Optional[str] jmsg_lower = json_string_field(resp.body, "message")
    message = jmsg_lower.unwrap_or(message)
    Optional[str] jmsg_upper = json_string_field(resp.body, "Message")
    message = jmsg_upper.unwrap_or(message)
    Optional[str] xcode = xml_element_text(resp.body, "Code")
    code = xcode.unwrap_or(code)
    Optional[str] xmsg = xml_element_text(resp.body, "Message")
    message = xmsg.unwrap_or(message)
    return Optional.Some(AwsError(code=code, message=message, status=resp.status))

# ---------------------------------------------------------------------------
# Pagination hooks seam
# ---------------------------------------------------------------------------

# One step of a paginated listing: whether another page exists and the
# continuation token to carry into the next request. A paginator loops —
# sign+send, read the token, apply it to the next request — until `has_more` is
# false. Per-service code supplies the token field/element names and where the
# token goes on the next request; the full generated paginators are future work.
struct NextPage:
    bool has_more
    str token

# Read a continuation token from an awsJson body by field name (e.g.
# "NextToken"). `has_more` is true when a non-empty token is present.
def next_page_json(str body, str field) -> NextPage:
    Optional[str] t = json_string_field(body, field)
    auto tok = t.unwrap_or("")
    return NextPage(has_more=len(tok) > 0, token=tok)

# Read a continuation token from a rest-xml body by element name (e.g.
# "NextContinuationToken").
def next_page_xml(str body, str tag) -> NextPage:
    Optional[str] t = xml_element_text(body, tag)
    auto tok = t.unwrap_or("")
    return NextPage(has_more=len(tok) > 0, token=tok)

# Return a copy of `req` with a query parameter set — the common way to carry a
# continuation token into the next page of a REST listing.
def with_query_param(Request req, str param, str value) -> Request:
    auto q = req.query.copy()
    q[param] = value
    return Request(
        method=req.method,
        service=req.service,
        region=req.region,
        host=req.host,
        path=req.path,
        query=q,
        headers=req.headers,
        body=req.body,
    )

# ---------------------------------------------------------------------------
# Streaming bodies + aws-chunked SigV4 (#358)
# ---------------------------------------------------------------------------
#
# S3 large objects and multipart uploads stream the payload instead of buffering
# it whole: the request body is split into chunks, each framed with its length
# and a per-chunk SigV4 signature, and the content hash sent as the literal
# sentinel STREAMING-AWS4-HMAC-SHA256-PAYLOAD. The chunk signatures form a
# rolling chain — the seed is the request's own SigV4 signature, and each chunk
# signs over the previous chunk's signature — so the stream cannot be reordered
# or truncated without detection. This is the aws-chunked content-encoding.
#
# These additions are purely additive: the non-streaming `sign_request` path and
# its pinned byte-diff fixtures are untouched. A streaming caller builds a normal
# `Request` plus a `StreamingBody` and calls `sign_streaming_request`; the
# receive side decodes a Transfer-Encoding: chunked response with
# `decode_chunked`. The rolling-signature algorithm is re-derived independently by
# the Python oracle (tools/verify_vectors.py) against AWS's published example.

# The x-amz-content-sha256 sentinel that selects aws-chunked streaming: the body
# is not hashed up front, each chunk carries its own signature instead.
def streaming_content_sha() -> str:
    return "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"

# A streaming (aws-chunked) request body: the ordered payload chunks that will be
# framed and signed on the wire. The trailing zero-length terminating chunk is
# appended by the encoder, so `chunks` holds only the real data pieces.
struct StreamingBody:
    list[str] chunks

# Build a StreamingBody from its ordered data chunks.
def streaming_body(list[str] chunks) -> StreamingBody:
    return StreamingBody(chunks=chunks)

# The decimal total payload length across all chunks — the value for the
# x-amz-decoded-content-length header (the length of the body AFTER aws-chunked
# framing is stripped). Signed as part of the request.
def decoded_content_length(list[str] chunks) -> str:
    auto total = 0
    for c in chunks:
        total = total + len(c)
    return str(total)

# Lowercase hexadecimal of a non-negative integer, used for the per-chunk length
# prefix on the wire (aws-chunked frames each chunk as "<hex-len>;...").
def hex_lower(int64 n) -> str:
    if n <= 0:
        return "0"
    auto digits = "0123456789abcdef"
    auto s = ""
    auto x = n
    while x > 0:
        auto d = x % 16
        s = digits[d:d + 1] + s
        x = x // 16
    return s

# The SigV4 chunk string-to-sign for one chunk (STREAMING-AWS4-HMAC-SHA256-
# PAYLOAD):
#   "AWS4-HMAC-SHA256-PAYLOAD" \n amz_date \n scope \n prev_sig \n
#   hex(sha256("")) \n hex(sha256(chunk_data))
# `prev_sig` is the previous signature in the chain (the request's seed signature
# for the first chunk). The fifth line is always the hash of the empty string.
def chunk_string_to_sign(
    str amz_date,
    str cred_scope,
    str prev_sig,
    str chunk_data,
) -> str:
    return "AWS4-HMAC-SHA256-PAYLOAD" + "\n" + amz_date + "\n" + cred_scope + "\n" + prev_sig + "\n" + crypto.sha256("") + "\n" + crypto.sha256(chunk_data)

# One chunk's signature = HMAC-SHA256(signing_key, chunk_string_to_sign), hex.
# `key` is the SigV4 signing key (from `signing_key`); `prev_sig` chains the roll.
def chunk_signature(
    bytes key,
    str amz_date,
    str cred_scope,
    str prev_sig,
    str chunk_data,
) -> str:
    auto sts = chunk_string_to_sign(amz_date, cred_scope, prev_sig, chunk_data)
    return crypto.hmac_sha256(key, sts)

# One aws-chunked wire frame for a chunk: "<hex-len>;chunk-signature=<sig>\r\n"
# then the chunk data then "\r\n". The terminating chunk is `encode_chunk("",
# <its signature>)`, which yields "0;chunk-signature=<sig>\r\n\r\n".
def encode_chunk(str data, str signature) -> str:
    return hex_lower(len(data)) + ";chunk-signature=" + signature + "\r\n" + data + "\r\n"

# The full aws-chunked body plus the final (terminating-chunk) signature. Each
# data chunk is signed in turn, chaining `prev` from `seed_sig`; then a
# zero-length chunk is signed and appended to close the stream. `key`/`cred_scope`
# come from the same SigV4 derivation as the seed signature.
struct ChunkedBody:
    str body
    str final_sig

def aws_chunked_body(
    bytes key,
    str amz_date,
    str cred_scope,
    str seed_sig,
    list[str] chunks,
) -> ChunkedBody:
    auto prev = seed_sig
    auto out = ""
    for data in chunks:
        auto sig = chunk_signature(key, amz_date, cred_scope, prev, data)
        out = out + encode_chunk(data, sig)
        prev = sig
    auto fsig = chunk_signature(key, amz_date, cred_scope, prev, "")
    out = out + encode_chunk("", fsig)
    return ChunkedBody(body=out, final_sig=fsig)

# The request's SigV4 signature alone (the seed of the chunk chain), computed the
# same way as `sign_request` but returning just the hex signature. The payload
# hash is the caller's x-amz-content-sha256 (for streaming, the sentinel) or
# SHA-256 of the body. Factored out so streaming callers and the test vectors can
# obtain the seed without assembling a full HTTP request.
def request_signature(
    Credentials creds,
    Request req,
    str amz_date,
    str date_stamp,
) -> str:
    auto to_sign = req.headers.copy()
    if creds.has_session:
        to_sign["x-amz-security-token"] = creds.session_token
    auto payload_sha = crypto.sha256(req.body)
    Optional[str] psha = to_sign.get("x-amz-content-sha256")
    payload_sha = psha.unwrap_or(payload_sha)
    auto canon_uri_str = canonical_uri(req.path, req.service)
    auto canon_q = url.canonical_query(req.query)
    auto canon = canonical_headers(to_sign)
    auto shead = signed_headers(to_sign)
    auto creq = canonical_request(
        req.method,
        canon_uri_str,
        canon_q,
        canon,
        shead,
        payload_sha,
    )
    auto cred_scope = credential_scope(date_stamp, req.region, req.service)
    auto sts = string_to_sign(amz_date, cred_scope, creq)
    auto key = signing_key(creds.secret_key, date_stamp, req.region, req.service)
    return sign(key, sts)

# Sign `req` as an aws-chunked streaming upload and return ready-to-send HTTP/1.1
# request text whose body is the signed chunk stream. The streaming markers are
# injected into the signed header set: content-encoding: aws-chunked,
# x-amz-content-sha256: STREAMING-AWS4-HMAC-SHA256-PAYLOAD, and
# x-amz-decoded-content-length (the raw payload length). The seed signature signs
# that header set; each chunk then signs over the previous signature. The on-wire
# content-length is the encoded (framed) length and is not itself signed, matching
# `sign_request`. `req.body` is ignored — the payload comes from `sbody`.
def sign_streaming_request(
    Credentials creds,
    Request req,
    StreamingBody sbody,
    str amz_date,
    str date_stamp,
) -> str:
    auto to_sign = req.headers.copy()
    if creds.has_session:
        to_sign["x-amz-security-token"] = creds.session_token
    to_sign["content-encoding"] = "aws-chunked"
    to_sign["x-amz-content-sha256"] = streaming_content_sha()
    to_sign["x-amz-decoded-content-length"] = decoded_content_length(sbody.chunks)

    auto canon_uri_str = canonical_uri(req.path, req.service)
    auto canon_q = url.canonical_query(req.query)
    auto canon = canonical_headers(to_sign)
    auto shead = signed_headers(to_sign)
    auto creq = canonical_request(
        req.method,
        canon_uri_str,
        canon_q,
        canon,
        shead,
        streaming_content_sha(),
    )
    auto cred_scope = credential_scope(date_stamp, req.region, req.service)
    auto sts = string_to_sign(amz_date, cred_scope, creq)
    auto key = signing_key(creds.secret_key, date_stamp, req.region, req.service)
    auto seed_sig = sign(key, sts)
    auto auth = authorization_header(creds.access_key, cred_scope, shead, seed_sig)

    auto chunked = aws_chunked_body(key, amz_date, cred_scope, seed_sig, sbody.chunks)
    auto headers_block = wire_headers(to_sign) + "content-length: " + str(len(chunked.body)) + "\r\n" + "authorization: " + auth + "\r\n"
    auto target = wire_path(req.path)
    if len(canon_q) > 0:
        target = target + "?" + canon_q
    return http_request_text(req.method, target, headers_block, chunked.body)

# ---------------------------------------------------------------------------
# Streaming response bodies (Transfer-Encoding: chunked)
# ---------------------------------------------------------------------------

# A response whose body is exposed as its ordered data chunks rather than one
# buffered string — the receive side of streaming (large S3 GetObject responses
# arrive chunked). The full body is the concatenation of `chunks`.
struct StreamingResponse:
    int64 status
    dict[str, str] headers
    list[str] chunks

# The value of a hexadecimal string (lowercase or uppercase), stopping at the
# first non-hex character — enough to read an HTTP chunk-size line, whose size
# may be followed by a ";ext" chunk extension.
def parse_hex(str s) -> int64:
    auto digits = "0123456789abcdef"
    auto v = 0
    for i in range(0, len(s)):
        auto d = digits.find(s[i:i + 1].lower())
        if d < 0:
            return v
        v = v * 16 + d
    return v

# Decode an HTTP/1.1 Transfer-Encoding: chunked body into its ordered data
# chunks. Each wire chunk is "<hex-len>[;ext]\r\n<data>\r\n"; a zero-length chunk
# terminates the body. Returns the decoded chunk payloads (their concatenation is
# the full entity body). Best-effort: a malformed frame stops decoding. This is
# the inverse of the aws-chunked framing on the send side and fills the
# chunked-decode gap `parse_response` left open.
def decode_chunked(str raw_body) -> list[str]:
    list[str] out = []
    auto rest = raw_body
    auto going = True
    while going:
        auto nl = rest.find("\r\n")
        if nl < 0:
            going = False
        else:
            auto size_line = rest[0:nl]
            auto semi = size_line.find(";")
            auto hexlen = size_line
            if semi >= 0:
                hexlen = size_line[0:semi]
            auto clen = parse_hex(hexlen.strip())
            if clen <= 0:
                going = False
            else:
                auto data_start = nl + 2
                out.append(rest[data_start:data_start + clen])
                rest = rest[data_start + clen + 2:len(rest)]
    return out

# ---------------------------------------------------------------------------
# Presigned URLs — query-parameter SigV4 (#359)
# ---------------------------------------------------------------------------
#
# A presigned URL carries the SigV4 signature in the query string instead of the
# Authorization header, so the URL alone grants time-boxed access (an S3 GET/PUT
# link a browser or curl can use directly until X-Amz-Expires elapses). Same
# canonicalization machinery as header signing (canonical URI / query / headers,
# signing key, string-to-sign), with four differences:
#   * the auth-carrying params — X-Amz-Algorithm, X-Amz-Credential, X-Amz-Date,
#     X-Amz-Expires, X-Amz-SignedHeaders (+ X-Amz-Security-Token for temporary
#     credentials) — are merged into the canonical query string rather than an
#     Authorization header;
#   * the signed-header set is usually just `host` (whatever is in req.headers);
#   * the payload hash is the literal UNSIGNED-PAYLOAD for S3 (the body is not
#     known when the link is minted) — overridable via `payload_sha`;
#   * the computed X-Amz-Signature is appended to the query string as the final
#     parameter and is NOT itself part of the canonical request.
#
# Purely additive: the header-signing `sign_request` path, the streaming path,
# and their pinned byte-diff fixtures are untouched. Proven host-side against
# AWS's published presigned-URL known-answer vector (S3 docs, "Authenticating
# Requests: Using Query Parameters") in tests/presign_url.main.zap, re-derived
# independently by tools/verify_vectors.py.

# The X-Amz-Algorithm value shared by header signing and presigning.
def presign_algorithm() -> str:
    return "AWS4-HMAC-SHA256"

# A minted presigned URL: the full https URL (all query params, including the
# trailing X-Amz-Signature), the canonical query string with the signature
# appended, and the hex X-Amz-Signature on its own.
struct PresignedUrl:
    str url
    str query
    str signature

# The SigV4 presigning query parameters: the auth-carrying params that become
# part of the canonical query string. `extra` is merged first (e.g. an S3
# `response-content-disposition` the caller wants on the link); `signed_hdrs` is
# the ";"-joined signed-header name list (typically "host"). X-Amz-Security-Token
# is added only for temporary (session) credentials.
def presign_params(
    Credentials creds,
    str cred_scope,
    str amz_date,
    int64 expires,
    str signed_hdrs,
    dict[str, str] extra,
) -> dict[str, str]:
    auto p = extra.copy()
    p["X-Amz-Algorithm"] = presign_algorithm()
    p["X-Amz-Credential"] = creds.access_key + "/" + cred_scope
    p["X-Amz-Date"] = amz_date
    p["X-Amz-Expires"] = str(expires)
    p["X-Amz-SignedHeaders"] = signed_hdrs
    if creds.has_session:
        p["X-Amz-Security-Token"] = creds.session_token
    return p

# Mint a presigned URL for `req`, valid for `expires` seconds from `amz_date`.
# `req.headers` is the set of headers to sign (usually just {"host": ...});
# `req.query` holds any extra query params to carry on the link. The payload hash
# defaults to UNSIGNED-PAYLOAD (the S3 presign convention); pass `payload_sha` to
# override it (e.g. the hash of a fixed body for a non-S3 query-presigned GET).
def presign_url(
    Credentials creds,
    Request req,
    int64 expires,
    str amz_date,
    str date_stamp,
    str payload_sha = "UNSIGNED-PAYLOAD",
) -> PresignedUrl:
    auto cred_scope = credential_scope(date_stamp, req.region, req.service)
    auto shead = signed_headers(req.headers)
    auto params = presign_params(creds, cred_scope, amz_date, expires, shead, req.query)
    auto canon_q = url.canonical_query(params)
    auto canon_uri_str = canonical_uri(req.path, req.service)
    auto canon = canonical_headers(req.headers)
    auto creq = canonical_request(
        req.method,
        canon_uri_str,
        canon_q,
        canon,
        shead,
        payload_sha,
    )
    auto sts = string_to_sign(amz_date, cred_scope, creq)
    auto key = signing_key(creds.secret_key, date_stamp, req.region, req.service)
    auto signature = sign(key, sts)
    auto full_q = canon_q + "&X-Amz-Signature=" + signature
    auto url_str = "https://" + req.host + wire_path(req.path) + "?" + full_q
    return PresignedUrl(url=url_str, query=full_q, signature=signature)

# The X-Amz-Signature alone for a presigned `req` (mirrors `request_signature`
# for the header path) — the hex signature without assembling the URL. Handy for
# test vectors that assert the signature against a known-answer value.
def presign_signature(
    Credentials creds,
    Request req,
    int64 expires,
    str amz_date,
    str date_stamp,
    str payload_sha = "UNSIGNED-PAYLOAD",
) -> str:
    auto signed = presign_url(creds, req, expires, amz_date, date_stamp, payload_sha)
    return signed.signature

# Mint a presigned URL using the current UTC time (the usual live path).
# Equivalent to `presign_url` with `signing_time_now()`.
def presign_url_now(
    Credentials creds,
    Request req,
    int64 expires,
    str payload_sha = "UNSIGNED-PAYLOAD",
) -> PresignedUrl:
    auto t = signing_time_now()
    return presign_url(creds, req, expires, t.amz_date, t.date_stamp, payload_sha)
