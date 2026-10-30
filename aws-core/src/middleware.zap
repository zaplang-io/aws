# aws.middleware — a composable request/response interceptor chain for the Zap
# AWS SDK.
#
# This module adds a thin, ORDERED interceptor chain around the existing
# core.sign → transport → core.parse_error pipeline, so cross-cutting behavior
# (logging, custom headers, request-id / tracing, metrics, mutating a request or
# transforming a response/error) can be layered on WITHOUT editing the signer or
# transport. It is the aws-core analogue of botocore's event system / the smithy
# interceptor model, expressed with Zap's first-class function values (I#163,
# D-0067): each phase hook is a `fn(T) -> T` value stored in an `Interceptor`
# record, and a `Chain` is an ordered `list[Interceptor]`.
#
# It is bundled AFTER aws.core (the same import contract aws.retry / aws.waiters
# use), so every type it leans on — `Request`, `Response`, `AwsError`,
# `Credentials`, `sign_request`, `send`, `parse_error`, `signing_time_now` — is
# already in scope.
#
# ## The four phases (around the current pipeline)
#   * before_sign  : `fn(Request) -> Request`   — observe/modify the Request
#                    BEFORE SigV4 signing. A header added here is part of the
#                    signed canonical request (the signer sees the returned
#                    Request), so this is where request-id / tracing / custom
#                    signed headers go.
#   * before_send  : `fn(str) -> str`           — the signed HTTP/1.1 wire text,
#                    AFTER signing and BEFORE transport. For observation
#                    (logging/timing the exact bytes) or a transport-only
#                    (unsigned) tweak. Changing signed material here is the
#                    caller's responsibility — the signature is already fixed.
#   * after_receive: `fn(Response) -> Response` — observe/transform the parsed
#                    Response after transport (logging, header injection,
#                    response-id capture).
#   * on_error     : `fn(AwsError) -> AwsError` — observe/transform the AWS error
#                    parsed from a non-2xx response (error enrichment / remapping).
#
# ## Ordering — an onion (outermost-first in, reverse out)
# Request-direction phases (before_sign, before_send) run in REGISTRATION order:
# the first interceptor added is the outermost and runs first on the way in.
# Response-direction phases (after_receive, on_error) run in REVERSE registration
# order: the outermost interceptor runs last on the way out. So for a chain
# [A, B, C] the before_sign order is A, B, C and the after_receive order is
# C, B, A — a predictable onion, exactly like layered HTTP middleware.
#
# ## Mutation vs. observation
# Every hook is `fn(T) -> T` and returns the (possibly new) value threaded to the
# next phase, so an interceptor may MUTATE (return a changed value) or merely
# OBSERVE (return its input unchanged, e.g. after a `print`). The default hooks
# are the identities below, so an unset phase is a true no-op.
#
# ## Additive by construction (byte-diff oracle unchanged)
# The dispatcher is a thin wrapper: with an EMPTY chain every `apply_*` is the
# identity, so `dispatch` reduces to exactly
# `core.send(host, core.sign_request(creds, req, ...))` — the same signed bytes
# and the same behavior as today. No existing request serialization changes; this
# module is only on the path of callers that build a `Chain` and route through it.
# The transport is a `fn(str) -> Response` seam (mirroring aws.retry's
# `fn() -> Response` and aws.waiters' `fn() -> Poll`): the live path supplies
# `core.send`, and the offline test injects a canned responder, so the full
# dispatch order is proven without a network. Short-circuiting a request before
# transport is intentionally out of scope for v1 (a documented follow-up); the
# four observe/mutate phases cover the enumerated cross-cutting cases.

import core

# ---------------------------------------------------------------------------
# Phase hook types + identity (no-op) defaults
# ---------------------------------------------------------------------------

# The identity before_sign hook: pass the Request through unchanged. The default
# for an interceptor that does not touch the pre-sign Request.
def identity_request(core.Request req) -> core.Request:
    return req

# The identity before_send hook: pass the signed wire text through unchanged.
def identity_str(str raw) -> str:
    return raw

# The identity after_receive hook: pass the Response through unchanged.
def identity_response(core.Response resp) -> core.Response:
    return resp

# The identity on_error hook: pass the AwsError through unchanged.
def identity_error(core.AwsError err) -> core.AwsError:
    return err

# ---------------------------------------------------------------------------
# The interceptor record + a Chain of them
# ---------------------------------------------------------------------------

# One interceptor: a `name` (for diagnostics) and the four phase hooks as
# function values. Each hook is `fn(T) -> T`; an unset phase is the matching
# identity above, so a partial interceptor (only `before_sign`, say) is a no-op
# in every other phase.
struct Interceptor:
    str name
    fn(core.Request) -> core.Request before_sign
    fn(str) -> str before_send
    fn(core.Response) -> core.Response after_receive
    fn(core.AwsError) -> core.AwsError on_error

# A no-op interceptor: every phase is the identity. Build the phases you want
# with the `with_*` helpers below, which return a copy with one phase replaced:
#   auto ic = with_before_sign(new_interceptor("trace"), add_trace_id)
def new_interceptor(str name) -> Interceptor:
    return Interceptor(
        name=name,
        before_sign=identity_request,
        before_send=identity_str,
        after_receive=identity_response,
        on_error=identity_error,
    )

# Return a copy of `ic` with its before_sign hook set to `f`.
def with_before_sign(Interceptor ic, fn(core.Request) -> core.Request f) -> Interceptor:
    return Interceptor(
        name=ic.name,
        before_sign=f,
        before_send=ic.before_send,
        after_receive=ic.after_receive,
        on_error=ic.on_error,
    )

# Return a copy of `ic` with its before_send hook set to `f`.
def with_before_send(Interceptor ic, fn(str) -> str f) -> Interceptor:
    return Interceptor(
        name=ic.name,
        before_sign=ic.before_sign,
        before_send=f,
        after_receive=ic.after_receive,
        on_error=ic.on_error,
    )

# Return a copy of `ic` with its after_receive hook set to `f`.
def with_after_receive(
    Interceptor ic,
    fn(core.Response) -> core.Response f,
) -> Interceptor:
    return Interceptor(
        name=ic.name,
        before_sign=ic.before_sign,
        before_send=ic.before_send,
        after_receive=f,
        on_error=ic.on_error,
    )

# Return a copy of `ic` with its on_error hook set to `f`.
def with_on_error(Interceptor ic, fn(core.AwsError) -> core.AwsError f) -> Interceptor:
    return Interceptor(
        name=ic.name,
        before_sign=ic.before_sign,
        before_send=ic.before_send,
        after_receive=ic.after_receive,
        on_error=f,
    )

# An ordered interceptor chain. The list order IS the onion order: index 0 is the
# outermost layer (first in, last out).
struct Chain:
    list[Interceptor] interceptors

# An empty chain — the additive default (routing through it is byte-identical to
# the direct sign+send path).
def new_chain() -> Chain:
    list[Interceptor] empty = []
    return Chain(interceptors=empty)

# A chain from an explicit ordered interceptor list.
def chain_of(list[Interceptor] interceptors) -> Chain:
    return Chain(interceptors=interceptors)

# Return a copy of `c` with `ic` appended as the new innermost layer. Copy-on-add
# so a chain value is never mutated under a caller that still holds it.
def chain_add(Chain c, Interceptor ic) -> Chain:
    auto next = c.interceptors.copy()
    next.append(ic)
    return Chain(interceptors=next)

# ---------------------------------------------------------------------------
# Phase application (the onion)
# ---------------------------------------------------------------------------
#
# A hook pulled from a struct field keeps its full function type, but it is bound
# to a `fn(...)`-annotated local before the call anyway — the always-valid form
# (I#163/D-0067: a value retrieved from a collection is re-attached to its
# signature by the annotation).

# Run every before_sign hook in REGISTRATION order, threading the Request. The
# returned Request is what the signer will sign — headers added here are signed.
def apply_before_sign(Chain c, core.Request req) -> core.Request:
    auto r = req
    for ic in c.interceptors:
        fn(core.Request) -> core.Request h = ic.before_sign
        r = h(r)
    return r

# Run every before_send hook in REGISTRATION order, threading the signed wire
# text on its way to the transport.
def apply_before_send(Chain c, str raw) -> str:
    auto s = raw
    for ic in c.interceptors:
        fn(str) -> str h = ic.before_send
        s = h(s)
    return s

# Run every after_receive hook in REVERSE registration order (onion unwind),
# threading the Response back out.
def apply_after_receive(Chain c, core.Response resp) -> core.Response:
    auto r = resp
    auto i = len(c.interceptors) - 1
    while i >= 0:
        auto ic = c.interceptors[i]
        fn(core.Response) -> core.Response h = ic.after_receive
        r = h(r)
        i = i - 1
    return r

# Run every on_error hook in REVERSE registration order, threading the AwsError
# back out (same unwind direction as after_receive).
def apply_on_error(Chain c, core.AwsError err) -> core.AwsError:
    auto e = err
    auto i = len(c.interceptors) - 1
    while i >= 0:
        auto ic = c.interceptors[i]
        fn(core.AwsError) -> core.AwsError h = ic.on_error
        e = h(e)
        i = i - 1
    return e

# ---------------------------------------------------------------------------
# The dispatcher
# ---------------------------------------------------------------------------

# The outcome of a dispatched request: the (post-after_receive) Response and, for
# a non-2xx response, the parsed-and-transformed AwsError (none on success). The
# error is additive — callers that only want the Response ignore it and get
# behavior identical to the pre-middleware path.
struct Dispatched:
    core.Response response
    Optional[core.AwsError] error

# Run `req` through `chain` around a caller-supplied transport `send_fn`:
#   before_sign → core.sign_request → before_send → send_fn → after_receive
#   → (on non-2xx) parse_error → on_error
# `send_fn` is the transport seam (`fn(str) -> Response`): the live path passes a
# `core.send` closure, tests pass a canned responder. With an empty chain the
# hooks are identities and `raw` is exactly `core.sign_request(creds, req, ...)`,
# so the signed bytes and the response are identical to the direct path.
def dispatch_with(
    Chain chain,
    core.Credentials creds,
    core.Request req,
    str amz_date,
    str date_stamp,
    fn(str) -> core.Response send_fn,
) -> Dispatched:
    auto signed_req = apply_before_sign(chain, req)
    auto raw = core.sign_request(creds, signed_req, amz_date, date_stamp)
    raw = apply_before_send(chain, raw)
    auto resp = send_fn(raw)
    resp = apply_after_receive(chain, resp)
    Optional[core.AwsError] err = core.parse_error(resp)
    if err.is_some():
        auto transformed = apply_on_error(chain, err.unwrap())
        err = Optional.Some(transformed)
    return Dispatched(response=resp, error=err)

# Live dispatch over the real HTTPS transport (`core.send` to `host`) at explicit
# SigV4 timestamps. The transport seam is filled with a `core.send` closure.
def dispatch(
    Chain chain,
    str host,
    core.Credentials creds,
    core.Request req,
    str amz_date,
    str date_stamp,
) -> Dispatched:
    fn(str) -> core.Response send_fn = lambda raw: core.send(host, raw)
    return dispatch_with(chain, creds, req, amz_date, date_stamp, send_fn)

# Live dispatch using the current UTC time (the usual path). Equivalent to
# `dispatch` with `core.signing_time_now()`. With an empty chain this is exactly
# `core.send(host, core.sign_request_now(creds, req))`.
def dispatch_now(
    Chain chain,
    str host,
    core.Credentials creds,
    core.Request req,
) -> Dispatched:
    auto t = core.signing_time_now()
    return dispatch(chain, host, creds, req, t.amz_date, t.date_stamp)
