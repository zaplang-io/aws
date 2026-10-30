# aws.dynamic — the opt-in dynamic `call()` escape hatch (D-0011 §8, #365).
#
# The generated typed per-service clients (aws-codegen, D-0001) are the product.
# But coverage is never 100%: after the #364 rollout + the #424/#426 gap fixes a
# small residual of operations is still skipped, and the 25 smithy-rpc-v2-cbor
# services have no codec yet (#428). This module is the escape hatch for exactly
# those — a low-level way to invoke an AWS operation the generated clients don't
# cover, WITHOUT hand-rolling SigV4, endpoint resolution and transport each time.
#
# HOW DYNAMIC — the one design question the ticket ("call(name, params)") leaves
# open. This is deliberately NOT a runtime botocore-model loader: loading the
# Smithy model at runtime and projecting arbitrary operations would fight the
# AOT/LLVM compilation model (the shapes a program touches must be known to the
# compiler) AND undercut generated-is-product (it would become a second, dynamic
# client surface competing with the typed one). Instead this is a THIN envelope
# over the primitives aws.core already ships: the CALLER supplies the wire details
# (service, region, HTTP method, path, query, headers, a PRE-SERIALIZED body, and
# which signing/path convention), and `call()` does the three things that are
# genuinely tedious and error-prone to repeat — endpoint resolution, SigV4
# signing, and send/parse — returning the raw `core.Response`, with typed-error
# mapping available through aws.errors (#361). The caller owns protocol framing
# (serializing the body, the Content-Type, an awsJson `X-Amz-Target`, a CBOR
# `smithy-protocol` header, a REST path's encoding); this module owns none of it,
# which is what keeps it a protocol-agnostic escape hatch rather than a codec.
#
# SIGNS IDENTICALLY. The whole point is that the escape hatch produces the exact
# same signed bytes a generated client would. It does so by reusing the SAME two
# signer entry points the generated clients use, chosen by `PathMode`:
#   * Decoded    → `core.sign_request` — the POST-"/" protocols (awsJson, query)
#     and any op whose `path` is the DECODED path (the signer percent-encodes it,
#     double-encoding the canonical URI for every service except S3). This is the
#     path `awsjson.awsjson_request` / `query.query_sign` take.
#   * PreEncoded → `binding.binding_sign` — the REST protocols (rest-json,
#     rest-xml) and the CBOR services, whose `path` is the ALREADY wire-encoded
#     URI (the binding owns per-label encoding, so the signer must not re-encode).
#     This is the path `restjson.rest_json_sign` / `restxml` take.
# The signing headers aws.core expects (host, x-amz-date, x-amz-content-sha256)
# are injected to match what the codecs set, so for the same inputs the canonical
# request — and therefore the signature and the ready-to-send bytes — are
# byte-identical to the generated/oracle path. `tests/dynamic_call.main.zap`
# pins this: an awsJson op, a query op and a CBOR-style pre-encoded op each built
# both ways and asserted equal.
#
# Additive and opt-in: importing this module IS the opt-in. It adds no surface to
# aws.core, aws.binding or the codecs, and touches no signing/codec/oracle path —
# it only reuses them (like D-0002/D-0003/D-0004/D-0005/D-0006).

import core
import endpoints
import errors
import binding

# ---------------------------------------------------------------------------
# Path / signing convention
# ---------------------------------------------------------------------------

# Which signer a dynamic request rides, i.e. how its `path` is treated:
#   * Decoded    — `path` is the decoded URI; sign with `core.sign_request`, which
#     percent-encodes it (double-encoding the canonical URI off S3). The POST-"/"
#     protocols (awsJson, query) and most path-less ops.
#   * PreEncoded — `path` is the already wire-encoded URI; sign with
#     `binding.binding_sign`, which does not re-encode it. The REST protocols and
#     the CBOR services (whose path is a fixed `/service/X/operation/Y`).
enum PathMode:
    Decoded
    PreEncoded

# ---------------------------------------------------------------------------
# The dynamic request descriptor
# ---------------------------------------------------------------------------

# A fully caller-specified AWS request for the escape hatch. Every wire detail is
# the caller's: `method`/`path`/`query`/`headers`/`body` are the request as it
# should go on the wire (the body already serialized by the caller in whatever
# protocol the operation speaks), and `service`/`region` drive both SigV4 scope
# and endpoint resolution. `host` is optional — "" resolves the standard regional
# endpoint via aws.endpoints; pass it to override (S3 virtual-hosting, FIPS/
# dualstack, a custom endpoint). `headers` holds the caller's protocol headers
# (Content-Type, awsJson X-Amz-Target, a CBOR smithy-protocol header, …); the
# signing headers (host, x-amz-date, x-amz-content-sha256) are injected by
# `build_request`, so the caller does not set them. `path_mode` selects the signer.
struct DynamicRequest:
    str method
    str service
    str region
    str host
    str path
    dict[str, str] query
    dict[str, str] headers
    str body
    PathMode path_mode

# Build a DynamicRequest. Only `method`/`service`/`region` are required; `headers`
# defaults to empty (pass the operation's protocol headers), `body` to "", `path`
# to "/", `query` to empty, `host` to "" (resolve the regional endpoint), and
# `path_mode` to Decoded (the POST-"/" / `core.sign_request` convention). Use
# PreEncoded for a REST or CBOR op whose `path` is already wire-encoded.
def dynamic_request(
    str method,
    str service,
    str region,
    dict[str, str] headers = {},
    str body = "",
    str path = "/",
    dict[str, str] query = {},
    str host = "",
    PathMode path_mode = PathMode.Decoded,
) -> DynamicRequest:
    return DynamicRequest(
        method=method,
        service=service,
        region=region,
        host=host,
        path=path,
        query=query,
        headers=headers,
        body=body,
        path_mode=path_mode,
    )

# ---------------------------------------------------------------------------
# Endpoint resolution + request assembly
# ---------------------------------------------------------------------------

# The host a dynamic request targets: the caller's `host` when set, else the
# standard regional endpoint for `service`/`region` (aws.endpoints). An op that
# needs S3 addressing or FIPS/dualstack passes the resolved host explicitly.
def resolve_host(DynamicRequest req) -> str:
    if len(req.host) > 0:
        return req.host
    return endpoints.regional_host(req.service, req.region)

# The signed header set for a dynamic request: the caller's headers plus the
# three SigV4 transport headers the codecs set — host and x-amz-date (always,
# from the resolved endpoint and the signing timestamp) and x-amz-content-sha256
# (the SHA-256 of the body, unless the caller already supplied one, e.g.
# UNSIGNED-PAYLOAD). This is exactly the header set `awsjson_headers` /
# `query_build_request` / `binding_headers` produce for the same inputs, so the
# canonical header block the signer derives is identical.
def signing_headers(DynamicRequest req, str host, str amz_date) -> dict[str, str]:
    auto h = req.headers.copy()
    h["host"] = host
    h["x-amz-date"] = amz_date
    if not "x-amz-content-sha256" in h:
        h["x-amz-content-sha256"] = core.payload_hash(req.body)
    return h

# Assemble the unsigned `core.Request` for a dynamic request at the resolved host
# and signing timestamp. The result is shaped exactly like a codec-built request
# (same method/service/region/host/path/query/headers/body), so signing it with
# the matching signer below yields byte-identical output to the generated path.
def build_request(DynamicRequest req, str host, str amz_date) -> core.Request:
    auto headers = signing_headers(req, host, amz_date)
    return core.Request(
        method=req.method,
        service=req.service,
        region=req.region,
        host=host,
        path=req.path,
        query=req.query.copy(),
        headers=headers,
        body=req.body,
    )

# ---------------------------------------------------------------------------
# Signing (reuses the generated clients' own signers)
# ---------------------------------------------------------------------------

# Sign a dynamic request at explicit SigV4 timestamps and return ready-to-send
# HTTP/1.1 request text. Dispatches on `path_mode` to the SAME signer the matching
# generated client uses — `core.sign_request` for Decoded (awsJson/query/decoded
# paths), `binding.binding_sign` for PreEncoded (REST/CBOR wire-encoded paths) —
# so the signed bytes match the generated/oracle path for identical inputs.
def sign_dynamic(
    core.Credentials creds,
    DynamicRequest req,
    str amz_date,
    str date_stamp,
) -> str:
    auto host = resolve_host(req)
    auto r = build_request(req, host, amz_date)
    auto out = ""
    match req.path_mode:
        case PathMode.Decoded:
            out = core.sign_request(creds, r, amz_date, date_stamp)
        case PathMode.PreEncoded:
            out = binding.binding_sign(creds, r, amz_date, date_stamp)
    return out

# Sign a dynamic request using the current UTC time — the usual live path (mirrors
# `core.sign_request_now` / `awsjson_request_now`).
def sign_dynamic_now(core.Credentials creds, DynamicRequest req) -> str:
    auto t = core.signing_time_now()
    return sign_dynamic(creds, req, t.amz_date, t.date_stamp)

# ---------------------------------------------------------------------------
# call() — resolve + sign + send
# ---------------------------------------------------------------------------

# The escape hatch: resolve the endpoint, SigV4-sign (current time), send over
# aws.core's HTTPS transport, and return the parsed `core.Response`. This is the
# dynamic analogue of a generated client's one-call operation, minus the typed
# input/output shapes — the caller serialized the body and reads the raw response.
# Classify failures with `call_error` / `call_checked` (aws.errors, #361). No
# retries (call `retry.retry_send` around this if wanted — the retry seam is
# protocol-agnostic and works on the signed-request thunk just as it does for the
# generated clients).
def call(core.Credentials creds, DynamicRequest req) -> core.Response:
    auto host = resolve_host(req)
    auto raw = sign_dynamic_now(creds, req)
    return core.send(host, raw)

# The typed service error a dynamic response carries, or none on a 2xx. A thin
# pass-through to `errors.service_error_from_response` (#361): the escape hatch
# gets the same normalized-code / request-id error carrier the generated clients
# surface, across every protocol (awsJson `__type`, rest-json `x-amzn-errortype`
# header, rest-xml `<Code>`).
def call_error(core.Response resp) -> Optional[errors.AwsServiceError]:
    return errors.service_error_from_response(resp)

# `call()` that raises (the aws.errors bridge) on a service fault and returns the
# response on success — the fail-fast ergonomic for an escape-hatch caller that
# wants a thrown error rather than an Optional to inspect.
def call_checked(core.Credentials creds, DynamicRequest req) -> core.Response:
    auto resp = call(creds, req)
    errors.check_response(resp)
    return resp
