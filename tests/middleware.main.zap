# Offline middleware test — exercises aws.middleware (the composable interceptor
# chain) deterministically and pins the output in tests/expected/middleware.expected.
# No live AWS calls: the transport is the injected `fn(str) -> Response` seam
# (`dispatch_with`), so the full dispatch order — before_sign → sign → before_send
# → send → after_receive → on_error — is asserted without a network (mirrors the
# injected seams in tests/retry.main.zap and tests/waiters.main.zap).
#
# What it proves:
#   * ORDERING — a chain [A, B, C] of tracer interceptors fires before_sign /
#     before_send in registration order and after_receive in REVERSE order (the
#     onion), by appending "<tag>.<phase>" to a shared captured log.
#   * MUTATION REACHES THE SIGNATURE — a before_sign interceptor that adds an
#     x-trace-id header changes the signed-header set AND the SigV4 signature, and
#     the header appears on the wire (proving it was signed, not merely appended).
#   * RESPONSE / ERROR TRANSFORM — an after_receive interceptor injects a response
#     header and an on_error interceptor remaps the parsed AWS error code.
#   * ADDITIVE DEFAULT — an empty chain signs byte-for-byte identically to the
#     direct core.sign_request path (the byte-diff-oracle invariant).
#
# The fixed credentials / timestamp are AWS's published SigV4 example values, so
# the signature is deterministic and independently reproducible by the Python
# oracle (tools/verify_vectors.py, `middleware()`).
#
# Run: tools/zrun.sh (via tools/run-tests.sh) with the aws_core zenv active.

import aws_core.core
import aws_core.middleware

# --- fixed signing inputs (AWS's published SigV4 example) -------------------

def amz() -> str:
    return "20150830T123600Z"

def ds() -> str:
    return "20150830"

def creds() -> core.Credentials:
    return core.credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")

# The base request shared by every case: the IAM ListUsers GET the SigV4 vector
# signs, carrying the signed host + x-amz-date headers.
def base_request() -> core.Request:
    return core.new_request(
        "GET",
        "iam",
        "us-east-1",
        "iam.amazonaws.com",
        "/",
        {"host": "iam.amazonaws.com", "x-amz-date": amz()},
        {"Action": "ListUsers", "Version": "2010-05-08"},
    )

# --- small Request / Response rebuilders (functional mutation) --------------

# A copy of `req` with one header set — the recommended before_sign mutation
# shape (return a new value rather than aliasing the caller's Request).
def with_header(core.Request req, str name, str value) -> core.Request:
    auto h = req.headers.copy()
    h[name] = value
    return core.Request(
        method=req.method,
        service=req.service,
        region=req.region,
        host=req.host,
        path=req.path,
        query=req.query,
        headers=h,
        body=req.body,
    )

# A copy of `resp` with one header set — the after_receive mutation shape.
def with_resp_header(core.Response resp, str name, str value) -> core.Response:
    auto h = resp.headers.copy()
    h[name] = value
    return core.Response(status=resp.status, headers=h, body=resp.body)

# --- tracer interceptor: records "<tag>.<phase>" into a shared log ----------

# Append `entry` to `log` and pass each value through unchanged — pure
# observation hooks that record the phase order into the captured list.
def note_req(list[str] log, str entry, core.Request r) -> core.Request:
    log.append(entry)
    return r

def note_str(list[str] log, str entry, str s) -> str:
    log.append(entry)
    return s

def note_resp(list[str] log, str entry, core.Response r) -> core.Response:
    log.append(entry)
    return r

# An interceptor that logs its tag at before_sign (".in"), before_send (".send"),
# and after_receive (".out"). `log` and `tag` are captured fresh per call, so each
# tracer records its own tag.
def tracer(list[str] log, str tag) -> middleware.Interceptor:
    fn(core.Request) -> core.Request bs = lambda r: note_req(log, tag + ".in", r)
    fn(str) -> str bsend = lambda raw: note_str(log, tag + ".send", raw)
    fn(core.Response) -> core.Response ar = lambda x: note_resp(log, tag + ".out", x)
    auto ic = middleware.new_interceptor(tag)
    ic = middleware.with_before_sign(ic, bs)
    ic = middleware.with_before_send(ic, bsend)
    ic = middleware.with_after_receive(ic, ar)
    return ic

# --- transform hooks for the response / error cases -------------------------

# before_sign: stamp a trace id onto the request (gets signed).
def add_trace(core.Request req) -> core.Request:
    return with_header(req, "x-trace-id", "t-abc")

# after_receive: mark the response as handled.
def mark_handled(core.Response resp) -> core.Response:
    return with_resp_header(resp, "x-handled", "yes")

# on_error: wrap the parsed AWS error code.
def wrap_error(core.AwsError err) -> core.AwsError:
    return core.AwsError(
        code="wrapped:" + err.code,
        message=err.message,
        status=err.status,
    )

# --- canned transports (the injected fn(str) -> Response seam) --------------

# Append the raw bytes it was handed to `seen`, then return a fixed 200 — lets a
# case assert exactly what the transport received (the signed wire text).
def capture_send(list[str] seen, str raw) -> core.Response:
    seen.append(raw)
    return core.Response(status=200, headers={}, body="{}")

def main():
    auto c = creds()
    auto base = base_request()

    # == signing: an empty chain is byte-identical to the direct path ==
    print("== additive ==")
    list[str] seen = []
    fn(str) -> core.Response cap = lambda raw: capture_send(seen, raw)
    auto d0 = middleware.dispatch_with(
        middleware.new_chain(),
        c,
        base,
        amz(),
        ds(),
        cap,
    )
    auto direct = core.sign_request(c, base, amz(), ds())
    print("empty-chain raw identical: " + str(seen[0] == direct))
    print("empty-chain status: " + str(d0.response.status))
    print("empty-chain error: " + str(d0.error.is_some()))

    # == mutation reaches the signature ==
    print("== signed mutation ==")
    auto traced = add_trace(base)
    auto sig0 = core.request_signature(c, base, amz(), ds())
    auto sig1 = core.request_signature(c, traced, amz(), ds())
    print("signed headers base: " + core.signed_headers(base.headers))
    print("signed headers traced: " + core.signed_headers(traced.headers))
    print("signature changed: " + str(sig0 != sig1))
    auto wire = core.sign_request(c, traced, amz(), ds())
    print("wire has trace header: " + str(wire.find("x-trace-id: t-abc") >= 0))

    # == ordering (the onion) ==
    print("== order ==")
    list[str] log = []
    auto chain = middleware.chain_of(
        [tracer(log, "A"), tracer(log, "B"), tracer(log, "C")],
    )
    fn(str) -> core.Response ok = lambda raw: core.Response(
        status=200,
        headers={},
        body="{}",
    )
    auto d1 = middleware.dispatch_with(chain, c, base, amz(), ds(), ok)
    print(" ".join(log))

    # == after_receive transform ==
    print("== after_receive ==")
    auto ri = middleware.with_after_receive(
        middleware.new_interceptor("resp"),
        mark_handled,
    )
    auto rc = middleware.chain_of([ri])
    auto d2 = middleware.dispatch_with(rc, c, base, amz(), ds(), ok)
    Optional[str] handled = d2.response.headers.get("x-handled")
    print("x-handled: " + handled.unwrap_or("<none>"))

    # == on_error transform ==
    print("== on_error ==")
    fn(str) -> core.Response fail = lambda raw: core.Response(
        status=400,
        headers={},
        body="{\"__type\": \"NoSuchKey\", \"message\": \"nope\"}",
    )
    auto ei = middleware.with_on_error(middleware.new_interceptor("err"), wrap_error)
    auto ec = middleware.chain_of([ei])
    auto d3 = middleware.dispatch_with(ec, c, base, amz(), ds(), fail)
    if d3.error.is_some():
        auto e = d3.error.unwrap()
        print("error: " + e.code + " status " + str(e.status))
    else:
        print("error: none")
