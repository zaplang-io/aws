# Decisions

Durable architectural decisions for `zaplang-io/aws`. Each entry is append-only:
once recorded it stays, superseded rather than edited, so the history of why the
repo looks the way it does is legible from here alone. Numbering is local to this
repo (as in `aws-codegen/DECISIONS.md`); cross-repo decisions are cited by their
home id (`D-00NN` from `zaplang-io/zap`, or `aws-codegen` D-0001).

## D-0001 — aws-core ships as a zenv package, imported via #283 (2026-10-30)

**Status:** accepted (ticket #339, step 1).

**Governing decisions.** D-0011 §8 (the AWS SDK shape: one `aws-core` package +
per-service packages); D-0052 (logical dependency names resolved through `zenv`);
D-0081 / zaplang-io/zap#283 (Zap-to-Zap module & package imports); and
`aws-codegen` D-0001 (**generated-is-product**: the generated per-service clients
are the shipping SDK, and the hand-written `aws.core` runtime + protocol codecs
remain only as (1) the runtime those clients ride on and (2) the byte-diff
oracle).

**Context.** Until module imports landed, the compiler linked exactly one entry
file, so a runnable program was the library modules + one `main()` concatenated
by `tools/bundle.py` (FRICTION.md #1). zaplang-io/zap#283 shipped real module
imports (Stage A intra-project, Stage B cross-package via `zenv`), so the
bundler can retire and aws-core can take the package shape D-0011 §8 always
specified — the shape the generator (aws-codegen, step 2 of #339) emits clients
on top of.

**Decision.** The hand-written aws-core runtime + protocol codecs ship as a
single **zenv package** named `aws_core`, consumed through real Zap module
imports. The repository is laid out as **package + consumer**:

```
aws/                      # repo root = the aws-core ORACLE HARNESS (a consumer)
  zap.toml                #   [package] name = "aws"; dep aws_core = { path = "aws-core" }
  zap.lock                #   committed (D-0052)
  aws-core/               # THE PACKAGE
    zap.toml              #   [package] name = "aws_core"
    src/
      aws_core.zap        #   root module (bare `import aws_core`)
      core.zap            #   SigV4 signer, Request/Response, transport, errors, pagination
      endpoints.zap       #   partition/region/endpoint resolution, Endpoint + S3 addressing
      credentials.zap     #   boto3-style credential provider chain
      retry.zap           #   standard retry mode (backoff + quota)
      binding.zap         #   protocol-agnostic HTTP binding layer
      awsjson.zap         #   awsJson 1.0/1.1 codec
      restjson.zap        #   rest-json codec
      restxml.zap         #   rest-xml codec
      s3.zap, dynamodb.zap#   PARKED hand-written service oracles (see below)
  tests/*.main.zap        # conformance entries: `import aws_core.<module>`
  examples/*.main.zap     # live examples: `import aws_core.<module>`
  tools/                  # verify_vectors.py (Python oracle), run-tests.sh
```

### Manifest and logical name

`aws-core/zap.toml` declares `[package] name = "aws_core"` (underscore — a Zap
module identifier). The package has **no dependencies**: its modules use only
stdlib and import each other with bare intra-package imports.

### Import paths (the contract step 2 builds on)

Resolution is D-0081 §2 (verified against the merged `modlink` loader):

| import (from a consumer) | resolves to |
|---|---|
| `import aws_core` | `$ZAP_ZENV/pkg/aws_core/src/aws_core.zap` (root module) |
| `import aws_core.core` | `$ZAP_ZENV/pkg/aws_core/src/core.zap` |
| `import aws_core.binding` | `$ZAP_ZENV/pkg/aws_core/src/binding.zap` |
| `import aws_core.restxml` | `$ZAP_ZENV/pkg/aws_core/src/restxml.zap` |

A dotted dependency import **binds the leaf name**, so members are accessed by
that leaf: `import aws_core.core` → `core.sign_request(...)`, `core.Request`,
`core.Credentials`. The form is identical whether a module is imported
intra-package (`import core`) or cross-package (`import aws_core.core`) — so the
generated clients write `core.<fn>` / `binding.<fn>` exactly as the codecs do
internally. Zap v1 has **no re-export form** (D-0081 §3), so consumers import the
specific submodule they need; the `aws_core` root module exposes only a package
`version()`.

A generated per-service client (aws-codegen, step 2) is its own package that
declares `aws_core` as a dependency (`path` for local dev; git/registry
otherwise) and does, e.g.:

```zap
import aws_core.core
import aws_core.binding       # or .awsjson / .restjson / .restxml / .query
import aws_core.endpoints
```

This needs **no** new package-manager or registry surface (D-0081 §5): it is
`zapc_pkg::zenv::module_search_paths_from_env()` selecting the search root.

### Module graph (and the one cycle broken)

Dependency edges within the package form a DAG (v1 rejects import cycles,
D-0081 §4):

```
core        -> (stdlib only)          # signer, Request/Response, transport, errors
endpoints   -> (stdlib only)          # owns Endpoint + resolvers + host shims
credentials -> core
retry       -> core
binding     -> core
awsjson     -> core, endpoints
restjson    -> binding, core
restxml     -> binding, core
s3          -> core, endpoints        # parked oracle
dynamodb    -> awsjson, core, endpoints   # parked oracle
```

The one real cycle was **core ↔ endpoints**: `core` held thin host shims
(`regional_host` / `s3_virtual_host` / `resolve_endpoint` / `resolve_s3_endpoint`)
that call `endpoints`' resolvers, while `endpoints` used `core`'s `Endpoint`
struct. It is broken by moving the `Endpoint` type **and** those four shims into
`endpoints`, where the resolver they delegate to already lives. `core` is now a
pure signing/transport base that imports no sibling; `endpoints` is a leaf. The
only consumer-visible change is that host resolution is now `endpoints.*`
(`endpoints.regional_host`, …) rather than `core.*` — the intuitive home, and the
contract generated clients will target. **No serialization behavior changes**
(this is purely packaging), so the byte-diff oracle is intact.

### Replacing bundle.py

`tools/bundle.py` and `tools/zrun.sh` (concatenate modules + one `main()`, hoist
imports) are **removed**. Each test/example is now a real program whose own
`import aws_core.<module>` lines drive resolution; `tools/run-tests.sh`
materializes the dependency (`zap zenv create`), activates the zenv, and runs
each entry with `zap run`, diffing stdout against the pinned
`tests/expected/*.expected`. `tools/verify_vectors.py` — the toolchain-free,
pure-Python SigV4 oracle — is unchanged; it reads the fixtures directly and never
used the bundler.

### Repo root is the first consumer (dogfooding)

The root project depends on the local `aws-core` package and drives the offline
conformance suite + live examples. It is therefore the **first consumer of the
import contract**, exercising exactly the path the generated service packages
use (path dep → `zenv` → `import aws_core.<module>`).

### The s3.zap / dynamodb.zap parking (flagged, NOT resolved here)

Under generated-is-product (aws-codegen D-0001) the hand-written **service**
clients retire. `s3.zap` and `dynamodb.zap` are **kept** because they double as
byte-diff **oracle** fixtures for this repo's own `service_signing` /
`awsjson_codec` conformance tests. They live inside the `aws_core` package as
clearly-marked parked modules; they are **not** part of the shipping aws-core
surface and generated clients never import them. Retiring `s3.zap` specifically
stays **PARKED** (it is the S3 byte-diff oracle); this packaging change does not
resolve the oracle story and should be settled separately — likely by moving the
service oracle fixtures out of the package once aws-codegen's byte-diff harness
no longer needs an in-repo hand-written reference.

**Consequences.**

- Step 2 (#339 in aws-codegen) emits each service client as a package that
  imports `aws_core.<module>` per the table above; no bundling.
- The broad rollout (#364) builds on this layout.
- CI materializes the zenv and is the authoritative build/run gate. The
  front-end (module resolution, cycle check, type-check) and `zap fmt` are
  host-safe and can be validated without LLVM/Docker (`zap ir`, `zap fmt`); only
  codegen/execution needs the toolchain image.

## D-0002 — streaming bodies + aws-chunked SigV4 are additive aws-core surface (2026-10-30)

**Status:** accepted (ticket #358, AWS Phase 4).

**Governing decisions.** D-0011 §5 (the hand-written SigV4 signer is aws-core's
job); aws-codegen D-0001 (generated-is-product; aws-core is runtime + oracle).

**Context.** S3 large objects and multipart uploads need the payload sent as a
stream of length-prefixed, individually-signed chunks
(`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`, content-encoding `aws-chunked`) rather
than one buffered, up-front-hashed body. Per-chunk signatures form a rolling
chain seeded by the request's own SigV4 signature, so the stream cannot be
reordered or truncated undetected.

**Decision.** The capability is added to `aws_core.core` as a **purely additive**
layer — the non-streaming `Request`/`sign_request` path and its pinned byte-diff
fixtures are untouched. New public surface:

- `struct StreamingBody { list[str] chunks }` + `streaming_body(chunks)` — a
  request payload carried as ordered chunks (the terminating zero-length chunk is
  appended by the encoder, not stored here).
- `streaming_content_sha() -> str` — the `STREAMING-AWS4-HMAC-SHA256-PAYLOAD`
  x-amz-content-sha256 sentinel.
- `decoded_content_length(chunks) -> str` — the `x-amz-decoded-content-length`
  value (decimal sum of chunk lengths).
- `hex_lower(int64) -> str` — lowercase hex for the per-chunk length prefix.
- `chunk_string_to_sign(amz_date, cred_scope, prev_sig, chunk_data) -> str` and
  `chunk_signature(key, amz_date, cred_scope, prev_sig, chunk_data) -> str` — the
  `AWS4-HMAC-SHA256-PAYLOAD` per-chunk string-to-sign and its HMAC signature.
- `encode_chunk(data, signature) -> str` — one aws-chunked wire frame
  (`<hex-len>;chunk-signature=<sig>\r\n<data>\r\n`).
- `struct ChunkedBody { str body; str final_sig }` +
  `aws_chunked_body(key, amz_date, cred_scope, seed_sig, chunks) -> ChunkedBody`
  — the full framed body with the rolling chain and terminating chunk.
- `request_signature(creds, req, amz_date, date_stamp) -> str` — the request's
  SigV4 signature alone (the chunk-chain seed); same derivation as
  `sign_request`, factored out so streaming callers and tests get the seed
  without assembling a full HTTP request.
- `sign_streaming_request(creds, req, sbody, amz_date, date_stamp) -> str` — the
  one-call path: injects the aws-chunked markers into the signed header set,
  computes the seed + chunk chain, and returns ready-to-send HTTP/1.1 text whose
  body is the signed chunk stream. `req.body` is ignored (payload is `sbody`).
  Content-length (the encoded length) is sent unsigned, matching `sign_request`.
- Receive side: `struct StreamingResponse { int64 status; dict[str,str] headers;
  list[str] chunks }`, `parse_hex(str) -> int64`, and `decode_chunked(raw_body)
  -> list[str]` — decode a `Transfer-Encoding: chunked` response body into its
  data chunks, filling the chunked-decode gap `parse_response` left open.

**Verification.** Correctness of the rolling signature is proven host-side,
without the Zap toolchain/Docker, against **AWS's own published known-answer
vector** (S3 docs, "Transferring Payload in Multiple Chunks"): a 66560-byte PUT
split 65536 + 1024 + terminating-0. `tools/verify_vectors.py` re-derives the seed
and every per-chunk signature from scratch and asserts them equal to AWS's
documented values (seed `4f232c43…a0a9`, chunk1 `ad80c730…8648`, chunk2
`0055627c…5497`, final `b6c6ea8a…49df9`); the framed body length comes out to
66824, matching AWS's documented `Content-Length`. The pinned fixture
`tests/expected/streaming_sigv4.expected` and the Zap entry
`tests/streaming_sigv4.main.zap` (run by `tools/run-tests.sh` under the toolchain
in CI) reproduce the same bytes. Docker was not run (it kernel-panics the dev
host); CI is the authoritative toolchain gate, with the Python oracle as the
toolchain-free second implementation.

## D-0003 — presigned URLs (query-parameter SigV4) are additive aws-core surface (2026-10-30)

**Status:** accepted (ticket #359, AWS Phase 4).

**Governing decisions.** D-0011 §5 (the hand-written SigV4 signer is aws-core's
job); aws-codegen D-0001 (generated-is-product; aws-core is runtime + oracle);
builds on D-0002 (the streaming/aws-chunked signing primitives).

**Context.** A presigned URL encodes the SigV4 signature in the query string
instead of the `Authorization` header, so the URL alone grants time-boxed access
(the canonical S3 GET/PUT link a browser or curl can use directly until
`X-Amz-Expires` elapses). It reuses the exact same canonicalization machinery as
header signing (canonical URI/query/headers, signing-key derivation,
string-to-sign) with four differences: the auth-carrying params live in the
canonical query string rather than a header; the signed-header set is usually
just `host`; the payload hash is the literal `UNSIGNED-PAYLOAD` (the body is not
known when the link is minted); and the computed `X-Amz-Signature` is appended as
the final query param and is NOT part of the canonical request.

**Decision.** The capability is added to `aws_core.core` as a **purely additive**
layer — the header-signing `sign_request` path, the streaming path, and all their
pinned byte-diff fixtures are untouched. New public surface:

- `presign_algorithm() -> str` — the `AWS4-HMAC-SHA256` algorithm label (shared
  with header signing).
- `struct PresignedUrl { str url; str query; str signature }` — a minted link:
  the full https URL (all query params incl. the trailing `X-Amz-Signature`), the
  canonical query string with the signature appended, and the hex signature
  alone.
- `presign_params(creds, cred_scope, amz_date, expires, signed_hdrs, extra) ->
  dict[str,str]` — the SigV4 presigning query params merged over any caller
  `extra`: `X-Amz-Algorithm`, `X-Amz-Credential`, `X-Amz-Date`, `X-Amz-Expires`,
  `X-Amz-SignedHeaders`, and (temporary creds only) `X-Amz-Security-Token`.
- `presign_url(creds, req, expires, amz_date, date_stamp, payload_sha =
  "UNSIGNED-PAYLOAD") -> PresignedUrl` — the one-call entry point: `req.headers`
  is the signed-header set (usually `{"host": ...}`), `req.query` any extra params
  to carry on the link; `expires` is in seconds. Reuses `credential_scope` /
  `signed_headers` / `canonical_uri` / `canonical_headers` / `canonical_request` /
  `string_to_sign` / `signing_key` / `sign` and `url.canonical_query` unchanged.
- `presign_signature(creds, req, expires, amz_date, date_stamp, payload_sha =
  "UNSIGNED-PAYLOAD") -> str` — the `X-Amz-Signature` alone (mirrors
  `request_signature` for the header path), for known-answer assertions.
- `presign_url_now(creds, req, expires, payload_sha = "UNSIGNED-PAYLOAD") ->
  PresignedUrl` — the live path, using `signing_time_now()`.

**Verification.** Correctness is proven host-side, without the Zap
toolchain/Docker, against **AWS's own published presigned-URL known-answer
vector** (S3 docs, "Authenticating Requests: Using Query Parameters"): a
presigned GET of `/test.txt` on `examplebucket.s3.amazonaws.com` at
2013-05-24T00:00:00Z, us-east-1, service `s3`, `X-Amz-Expires=86400`, signing only
`host` with `UNSIGNED-PAYLOAD`. `tools/verify_vectors.py` re-derives the
signature from scratch and asserts it equals AWS's documented
`aeeed9bb…604d404`. A second self-consistent case exercises the temporary-
credential path (`X-Amz-Security-Token`) plus an extra `response-content-type`
param, covering the param merge / percent-encoding / sort order. The pinned
fixture `tests/expected/presign_url.expected` and the Zap entry
`tests/presign_url.main.zap` (run by `tools/run-tests.sh` under the toolchain in
CI) reproduce the same bytes. Docker was not run (it kernel-panics the dev host);
CI is the authoritative toolchain gate, with the Python oracle as the
toolchain-free second implementation.

## D-0004 — waiters are a generic poll-until-state engine in aws-core (2026-10-30)

**Status:** accepted (ticket #360, AWS Phase 4).

**Governing decisions.** D-0011 §7 (aws-core owns the request-lifecycle seams —
retry, pagination, and now waiting); aws-codegen D-0001 (generated-is-product;
aws-core is the runtime those clients ride on). Follows D-0002/D-0003 as another
purely additive aws-core runtime layer.

**Context.** A waiter repeatedly calls one operation until the resource it
describes reaches a desired state ("wait until this bucket exists", "wait until
this instance is running"). botocore models each waiter in `waiters-2.json` as
`{delay, maxAttempts, operation, acceptors[]}`, where each acceptor is
`{state, matcher, argument, expected}`: the engine polls the operation, evaluates
the acceptors in order against each response, and transitions to the first
match's `state` (success | failure | retry). The matchers are `status` (HTTP
status), `error` (AWS error code), and `path`/`pathAll`/`pathAny` (a JMESPath into
the parsed response compared to `expected`).

**Decision.** The capability is added as a new **generic** module
`aws_core.waiters` — the ENGINE only. Per-service waiter TABLES (one config per
`waiters-2.json` entry) are emitted by **aws-codegen** and are a follow-up
(below); the engine here is service-agnostic. New public surface:

- `struct Acceptor { int64 state; int64 matcher; str argument; str expected }`
  and `struct WaiterConfig { str name; int64 delay; int64 max_attempts;
  list[Acceptor] acceptors }` — the `waiters-2.json` shape. `operation` is
  deliberately NOT modeled: which operation to call and how to sign it is the
  caller's poll closure, keeping the engine independent of any service's request
  builders. State constants `state_retry/success/failure`, matcher constants
  `matcher_status/error/path/path_all/path_any`, and acceptor constructors
  (`acceptor_status/error/path/path_all/path_any`) — what a generated table emits.
- `evaluate(acceptors, resp, parsed) -> int64` — the first matching acceptor's
  state, or `state_retry` when none matched (botocore's "keep polling" default).
- `struct Poll { Response response; JsonValue parsed }` and
  `wait(cfg, fn() -> Poll) -> WaiterOutcome` — the loop: poll, evaluate, sleep
  `delay` between polls, stop on a success/failure acceptor or at `max_attempts`
  (timeout). `WaiterOutcome { int64 result; int64 attempts; Response response }`
  with results `result_success/failure/timeout`. The `fn() -> Poll` seam mirrors
  aws.retry's `fn() -> Response` — tests inject canned polls, the live path uses
  `send_poll`.
- `send_poll(host, creds, req) -> Poll` — the live convenience: re-sign with a
  fresh SigV4 timestamp, send, and parse the JSON body into the matcher DOM
  (`parse_body`), the waiter analogue of `send_request_with_retry`.

**Parsed-response seam.** `path`/`pathAll`/`pathAny` evaluate over a `JsonValue`
DOM (the compiler-known prelude enum), exactly as botocore runs JMESPath over the
deserialized output — independent of the JSON vs XML wire format. The engine
implements the JMESPath subset waiter arguments use: dotted field access with
`[]` flatten projections (e.g. `Table.TableStatus`,
`Reservations[].Instances[].State.Name`). JSON protocols parse the body with
`json.loads` (`parse_body` / `send_poll`); an XML protocol supplies its own
body→`JsonValue` adapter. This is additive — no signing, codec, or byte-diff
oracle behavior changes.

**Verification.** Correctness is proven host-side, without the Zap
toolchain/Docker, by extending `tools/verify_vectors.py` with an independent
Python reimplementation of the engine (`waiters()`: the same matchers, JMESPath
subset, and poll loop) that asserts the pinned transitions in
`tests/expected/waiters.expected`. The fixtures are REAL `waiters-2.json` entries
— S3 `BucketExists`/`BucketNotExists` (status matchers), DynamoDB `TableExists`
(path + error matchers), and EC2 `InstanceRunning` (pathAll/pathAny over a
flattening JMESPath) — so every matcher kind is exercised against genuine acceptor
specs, including a loop that transitions retry→retry→success and a terminal
failure. `tests/waiters.main.zap` reproduces the same transitions through
`aws_core.waiters` and is run by `tools/run-tests.sh` under the real toolchain in
CI. Docker was not run (it kernel-panics the dev host); the local `zap` debug
build predates the qualified-type-parameter syntax aws-core already uses, so the
`.zap` files were gated host-side via a stub-typed probe (`zap fmt`/`zap ir`
front-end) plus the Python oracle, and CI (the `ghcr.io/zaplang-io/zap:latest`
image) is the authoritative compile+run gate.

**Follow-up (aws-codegen).** The per-service waiter tables are generated from each
service's `waiters-2.json`: emit one `WaiterConfig` (with its `Acceptor` list)
per waiter and a typed `wait_<name>(client, input)` that builds the poll closure
(re-sign + send + parse) and calls `aws_core.waiters.wait`. Tracked as an
aws-codegen follow-up; the real fixtures in `tests/waiters.main.zap` are the shape
that generator must reproduce.

## D-0005 — request/response middleware is a composable interceptor chain in aws-core (2026-10-30)

**Status:** accepted (ticket #362, AWS Phase 4).

**Governing decisions.** D-0011 §7 (aws-core owns the request-lifecycle seams —
retry, pagination, waiting, and now the interceptor chain); zap D-0067/I#163
(first-class function values + closures). Follows D-0002/D-0003/D-0004 as another
purely additive aws-core runtime layer and the LAST Phase 4 runtime item.

**Context.** Cross-cutting behavior — logging, custom/signed headers, request-id
/ tracing, metrics, mutating a request or transforming a response/error — needs a
place to live that is NOT the signer or the transport. botocore has its event
system and the modern AWS SDKs the smithy interceptor model: typed hook points
around the request lifecycle. aws-core already decomposes that lifecycle into
`sign_request` → `send` → `parse_error`, and Zap now has first-class function
values (D-0067), so the hooks can be plain `fn(T) -> T` values composed into an
ordered chain.

**Decision.** The capability is a new generic module `aws_core.middleware`: a
record of per-phase function-value hooks and a thin dispatcher that runs them
around the existing pipeline. New public surface:

- `struct Interceptor { str name; fn(Request)->Request before_sign;
  fn(str)->str before_send; fn(Response)->Response after_receive;
  fn(AwsError)->AwsError on_error }` — the four phases, each `fn(T) -> T`. The
  identity hooks `identity_request/str/response/error` are the no-op defaults.
- `new_interceptor(name)` (all phases identity) plus copy-updaters
  `with_before_sign/with_before_send/with_after_receive/with_on_error` — a caller
  sets only the phases it needs. (A defaulted-fn-argument constructor was avoided
  deliberately: a default VALUE that is a function value is not exercised by any
  zap golden test, whereas struct construction with function-value fields and
  passing a function value to a `fn(...)` parameter both are — so the builder uses
  only proven ground.)
- `struct Chain { list[Interceptor] interceptors }` with `new_chain` /
  `chain_of` / `chain_add` (copy-on-add). The list order IS the onion order:
  index 0 is the outermost layer.
- `dispatch_with(chain, creds, req, amz_date, date_stamp, fn(str)->Response)
  -> Dispatched` — the dispatcher: `before_sign → core.sign_request →
  before_send → send_fn → after_receive → (on non-2xx) parse_error → on_error`.
  The transport is a `fn(str) -> Response` seam (mirroring aws.retry's
  `fn() -> Response` and aws.waiters' `fn() -> Poll`): the live wrappers
  `dispatch` / `dispatch_now` fill it with a `core.send` closure, and the offline
  test injects a canned responder. `Dispatched { Response response;
  Optional[AwsError] error }` carries the (post-after_receive) Response and, for a
  non-2xx response, the parsed-and-transformed error.

**Ordering (the onion).** Request-direction phases (before_sign, before_send)
run in REGISTRATION order; response-direction phases (after_receive, on_error)
run in REVERSE registration order. For a chain `[A, B, C]` the before_sign order
is `A, B, C` and the after_receive order is `C, B, A` — predictable, like layered
HTTP middleware.

**Mutation vs. observation.** Every hook is `fn(T) -> T` and returns the
(possibly new) value threaded to the next phase, so an interceptor may MUTATE
(return a changed value — e.g. a before_sign that adds a header, which is then
part of the signed canonical request) or merely OBSERVE (return its input after a
side effect). Mutation is functional (return a new value), never in-place aliasing
of the caller's Request. Short-circuiting a request before transport is
intentionally out of scope for v1 (a documented follow-up); the four
observe/mutate phases cover the enumerated cross-cutting cases.

**Additive by construction (byte-diff oracle unchanged).** The dispatcher is a
thin wrapper: with an EMPTY chain every `apply_*` is the identity, so `dispatch`
reduces to exactly `core.send(host, core.sign_request(creds, req, ...))` — the
same signed bytes and the same behavior as before. No existing request
serialization changes; the module is only on the path of callers that build a
`Chain` and route through it. The `Dispatched.error` field is additive — callers
that want only the Response ignore it.

**Verification.** Correctness is proven host-side, without the Zap
toolchain/Docker, by extending `tools/verify_vectors.py` with an independent
Python reimplementation of the engine (`middleware()`: the same onion ordering,
the same before_sign→sign→before_send→send→after_receive→on_error dispatch, and
the same SigV4 signer that proves the other vectors). It asserts the pinned facts
in `tests/expected/middleware.expected`: the onion order over a 3-interceptor
chain, that a before_sign-added `x-trace-id` changes the signed-header set AND the
SigV4 signature AND appears on the wire (proving it was signed, not merely
appended), the response-header and error-code transforms, and that an empty chain
signs byte-for-byte identically to the direct `core.sign_request` path.
`tests/middleware.main.zap` reproduces the same facts through `aws_core.middleware`
and is run by `tools/run-tests.sh` under the real toolchain in CI. Docker was not
run (it kernel-panics the dev host); the local `zap` debug build predates the
`fn(...)->...` and qualified-type-parameter syntax aws-core uses, so the `.zap`
files were gated host-side via a length-faithful stub-typed probe (`zap fmt` over
the fn-free/dequalified skeleton, which validated indentation, bracket balance and
the 88-column canonical form) plus the Python oracle, and CI (the
`ghcr.io/zaplang-io/zap:latest` image) is the authoritative compile+run gate.

**Follow-ups.** (1) A short-circuit / handler-wrap variant (`fn(Handler)->Handler`)
for interceptors that answer a request without transport. (2) Wiring the chain
into the generated per-service clients (aws-codegen) so a client carries a default
Chain. Both tracked as follow-ups; the engine here is the service-agnostic base.

## D-0006 — typed service errors: an open error enum + a base carrier, dispatched by `match` (2026-10-30)

**Status:** accepted (ticket #361, AWS typed errors). aws-core foundation half;
the aws-codegen emission half is a deliberate follow-up gated on #364.

**Governing decisions.** D-0011 §7 (aws-core owns the request-lifecycle seams,
error dispatch among them); aws-codegen D-0001 (generated-is-product; aws-core is
the runtime those clients ride on and the byte-diff oracle). zap I#51/D-0046
(enums with payload variants + exhaustive `match`) and zap I#22/D-0007/D-0029 +
I#383/I#401 (exceptions: `raise`/`try`/`except`/`finally`, with built-in faults
made catchable). Purely additive — like D-0002/D-0003/D-0004/D-0005 it adds
surface and touches no signing/codec/oracle path.

**Context.** `core.parse_error` surfaces a flat `AwsError { code, message, status }`
from any non-2xx `Response`. That is the string-matching baseline: a caller tells
`NoSuchKey` from `NoSuchBucket` by comparing `err.code` to a string literal. #361
asks for typed errors so a caller branches on the *kind* of error instead of
string-matching a code.

**What the language actually supports today (this shaped the model).** Probed
against the compiler, not assumed:
- Enums with payload variants + exhaustive `match` are fully shipped. A mixed
  enum (bare variants + an `Unknown(str code)` payload variant) compiles, and the
  `match` is exhaustiveness-checked.
- Exceptions `raise`/`try`/`except`/`finally` are shipped, but with two limits
  that are deferred in the compiler (`crates/ir/src/lower.rs`): (a) `raise` lowers
  only a **str** message (`raise` of a typed payload is rejected), and (b) `except`
  matching is **catch-all** — the clause's type is parsed but ignored, the first
  clause wins, and `as e` binds the message *string*. So type-directed
  `except NoSuchKey:` dispatch does not exist yet.
- Enum variant patterns resolve on a **two-segment** `Enum.Variant` path only
  (sema `check_qualified_pattern`, lowering `variant_cond` key on the first path
  segment). A caller's own `match` with a module-qualified `s3.S3ErrorKind.NoSuchKey`
  pattern is three segments and is NOT resolved — only a `match` written *inside*
  the module that defines the enum is portable today. (Cross-module enum *value*
  construction and value-passing DO work, as the existing `binding.PayloadKind`
  usages show.)

So typed *dispatch* is delivered the way the language supports now — an open enum
+ an exhaustive `match` that lives in the service module — not multiple `except`
clauses. The exception path is provided as a thin bridge (below) for the
single-handler ergonomic.

**Decision.** A new `aws_core.errors` module holds the service-agnostic base, and
each service owns its typed-error enum + classifier (generated; hand-wired for S3
here as the proof). New public surface:

- `struct AwsServiceError { str code; str message; str request_id; int64
  http_status }` — the base carrier: `core.AwsError` plus the request id. A plain
  value a caller inspects (the unwinder cannot carry a struct yet).
- `error_code(raw) -> str` — normalize a raw code to the bare shape name
  (`split(':',1)[0]` then `rsplit('#',1)[-1]`, via a local `last_index` since
  there is no `str.rfind`), so `com.amazonaws.s3#AccessDenied` and `NoSuchKey:`
  both match `AccessDenied` / `NoSuchKey`. Mirrors `awsjson.awsjson_strip_error_code`.
- `request_id_of(resp)`, `service_error(e, resp)`, and
  `service_error_from_response(resp) -> Optional[AwsServiceError]` — the last
  wraps `core.parse_error` and, when the body carried no code (the rest-json case),
  falls back to the `x-amzn-errortype` header. Request id read from
  `x-amzn-requestid` then `x-amz-request-id`.
- The exception bridge: `format_error(e) -> str` (the one-line
  `"<code>: <message> (request-id=<id>, http-status=<n>)"`), `raise_error(e)`
  (raises that message), and `check_response(resp)` (raise on a fault, return on a
  2xx) — so `try: errors.check_response(resp) except ... as e:` works today.
- The **per-service pattern** (documented in `errors.zap`, implemented for S3 in
  `s3.zap`): an open enum `S3ErrorKind { <modeled...>, Unknown(str code) }`, a
  classifier `s3_error_kind(code) -> S3ErrorKind` (normalizes then matches by name,
  unmodeled → `Unknown(code)`), and a module-local exhaustive dispatcher
  `s3_error_name(S3ErrorKind) -> str`. The `Unknown(code)` arm is forward
  compatibility: a new service error lands there, never breaking a caller built
  against an older model.

**Caller usage today.** Classify a response, then dispatch through the typed value
via the service's module-local helpers:
`s3.s3_error_name(s3.s3_error_kind(errors.service_error_from_response(resp).unwrap().code))`,
or catch via the raise bridge. The enum IS the substrate the two deferred compiler
features will light up (inline caller `match` once module-qualified variant
patterns resolve; `except S3ErrorKind.NoSuchKey:` once `except` is type-directed)
with no change to the generated classifier.

**Proof.** `tests/typed_errors.main.zap` (pinned in
`tests/expected/typed_errors.expected`, run by `tools/run-tests.sh`) feeds canned
responses — rest-xml `<Code>`, awsJson namespaced `__type`, a rest-json
`x-amzn-errortype` header, and an unmodeled code — through the pipeline and
asserts the right `S3ErrorKind` (including the `Unknown(code)` fallback), the
carrier fields + `format_error`, that `check_response` does NOT raise on a 2xx,
and that it raises a catchable formatted message on a fault.

**Docker was not run** (it kernel-panics the dev host, standing rule) and the
local `zap` debug build is ~80 commits behind main — it predates the
qualified-type-parameter and `dict.get`→Optional syntax aws-core uses, so it
cannot parse the import-based `.zap` files directly. Host validation followed the
D-0005 precedent: a dequalified, inlined probe of the full pipeline
(core.parse_error → errors → s3 classifier/`match` → raise/try/except, the two
header `dict.get` reads stubbed) passed `zap ir` (type-check) and `zap fmt`, and
every touched `.zap` is 88-column canonical by construction. CI
(`ghcr.io/zaplang-io/zap:latest`) is the authoritative compile+run gate.

**The generator contract (the #361 follow-up, GATED ON #364).** On top of this
aws-core base, aws-codegen emits per service, into the service module, from the
service's modeled error shapes:
1. `enum <Service>ErrorKind:` — one bare variant per modeled error shape (variant
   name = the shape name), plus a final `Unknown(str code)` catch-all.
2. `def <service>_error_kind(str code) -> <Service>ErrorKind:` — `auto name =
   errors.error_code(code)`, an `if name == "<Shape>": return
   <Service>ErrorKind.<Shape>` per modeled shape, else `return
   <Service>ErrorKind.Unknown(name)`.
3. `def <service>_error_name(<Service>ErrorKind) -> str:` — an exhaustive,
   module-local `match` rendering each variant's name (`Unknown` as
   `"Unknown(" + c + ")"`). Module-local so the `match` is two-segment and
   portable.
Everything else (the `AwsServiceError` carrier, normalization, the header
fallback, the raise/check bridge) is inherited from `aws_core.errors` and is NOT
re-emitted. The byte-diff oracle is unaffected (errors are additive surface). The
follow-up is gated on #364 (the broad codegen rollout) landing first, so the
generator change does not collide with the in-flight regeneration. Two compiler
follow-ups, when they land, remove the module-local-`match` constraint and unlock
the fuller ergonomics, reusing the SAME generated enums: (a) module-qualified
enum variant patterns in a caller's `match`; (b) type-directed `except` dispatch
(and `raise` of a typed payload) so `except <Service>ErrorKind.<Shape>:` works.

## D-0007 — smithy-rpc-v2-cbor codec: aws-core foundation, emitter deferred (2026-10-30)

**Status:** accepted (ticket #428, part 1). aws-core foundation half; the
aws-codegen emitter + `models/manifest.json` entries for the 25 cbor-only
services are a deliberate follow-up queued behind the aws-codegen lane.

**Governing decisions.** D-0011 §2 (aws-core owns the protocol codecs); aws-codegen
D-0001 (generated-is-product; aws-core is the runtime those clients ride on AND
the byte-diff oracle). Follows the aws.query / aws.awsjson / aws.restxml codec
shape and D-0002..D-0006 as additive aws-core surface — no signing, endpoint, or
existing-codec path changes.

**Context.** smithy-rpc-v2-cbor is AWS's newest RPC protocol: a POST to
`/service/{ServiceName}/operation/{OperationName}` whose body is the operation
input serialized as a CBOR (RFC 8949) data item, with `smithy-protocol:
rpc-v2-cbor`, `Accept: application/cbor`, and (body-present) `Content-Type:
application/cbor`. It is the sixth protocol; 25 services currently excluded from
the manifest speak only it (CloudWatch moved query→cbor upstream, Translate, and
others). #365's `aws_core.dynamic` escape hatch reaches them today by hand-framing
CBOR; this is the real codec that replaces the hand-framing, flagged by #365 as
the proper fix.

**Decision.** A new `aws_core.cbor` module is the protocol-agnostic codec, driven
by the CALLER's value model exactly as aws.query is driven by caller-supplied
parameters (this layer never guesses a member name). New public surface:

- `enum CborValue { Int, Bool, Null, Text, Blob, Double, Single, Timestamp, List,
  Map }` — the rpc-v2-cbor value model (`Map` carries parallel key/value lists:
  structures ARE maps keyed by member name). Constructor helpers `cbor_int` /
  `cbor_text` / `cbor_bool` / `cbor_null` / `cbor_blob` / `cbor_double` /
  `cbor_single` / `cbor_timestamp` / `cbor_list` / `cbor_map` are the builder.
- `cbor_encode(CborValue) -> bytes` — canonical CBOR, mirroring botocore's
  RpcV2CBORSerializer: definite-length strings/blobs/lists/maps; struct members as
  a map keyed by the text-string member name in MODEL order (botocore does NOT
  sort keys; absent/null members are omitted by the caller, matching botocore's
  `{k: v for ... if v is not None}`); integers in the shortest 1/2/3/5/9-byte
  form; timestamps as CBOR tag 1 over integer epoch-seconds (`unixtimestamp`);
  floats as IEEE-754 (major 7, ai 27 double / ai 26 float), with inf/-inf/NaN as
  the half-float forms botocore emits. Because the language has no float↔bits
  primitive, the IEEE-754 packing is done by hand from integer/float arithmetic;
  it is byte-identical to `struct.pack` for exactly-representable values (what the
  vectors use) and follows IEEE round-to-nearest otherwise.
- `cbor_uri` / `cbor_content_type` / `cbor_headers` / `cbor_build_request` — the
  rpc-v2-cbor framing (path, the smithy-protocol / Accept / Content-Type headers,
  the x-amz-content-sha256 over the CBOR body).
- `cbor_sign(creds, req, body, amz_date, date_stamp) -> bytes` and
  `cbor_signature(...) -> str` — SigV4 over the CBOR body, the pattern
  `binding.binding_sign` established for a bytes/pre-encoded body: it reuses every
  core SigV4 primitive (`canonical_headers` / `canonical_request` /
  `string_to_sign` / `signing_key` / `sign` / `authorization_header`) unchanged,
  so the signature is byte-identical to the generated/oracle path and the pinned
  SigV4 vectors are untouched.
- Response decode — `cbor_decode(bytes) -> CborValue`, the accessors
  `cbor_map_get` / `cbor_as_text` / `cbor_as_int` / `cbor_as_bool` /
  `cbor_as_timestamp` / `cbor_list_len` / `cbor_list_at`, and error dispatch
  `cbor_error(status, body) -> Optional[core.AwsError]` (plus `cbor_error_type` /
  `cbor_error_message`) surfacing the fault map's `__type` / `message` for the
  #361 typed-error map.

**A CBOR body is bytes, not a str.** Unlike JSON/XML/query, a CBOR body is genuine
binary. The encoder returns `bytes` (built via a `list[int64]` accumulator —
`bytes` has no `+`), and decode/error dispatch TAKE `bytes`, not
`core.Response.body` (a `str`): `bytes(str)` is a UTF-8 ENCODE, not a reinterpret,
and there is no str→bytes reinterpret in the language, so a CBOR body cannot
round-trip through a str. The deferred transport/emitter half hands the raw
response body here as bytes. This is the one shape difference from the str-bodied
codecs and the reason signing is a dedicated `cbor_sign` over bytes rather than a
call into `core.sign_request` (whose body parameter is a str).

**Scope — foundation only.** This ticket adds the codec, framing, decode and the
byte-diff oracle. It does NOT touch the aws-codegen generator/emitter or
`models/manifest.json`; wiring the 25 cbor services (an emitter that walks a
service model and calls `cbor_map`/`cbor_list`/… , plus the manifest entries) is
part 2, queued behind the aws-codegen lane so it does not collide with the
in-flight #425 HTTP-binding work. Event-stream framing (the
`application/vnd.amazon.eventstream` Accept variant) is out of scope.

**Verification.** The CBOR bytes are the byte-diff oracle. The pinned vectors — a
hand-rolled struct exercising every value kind (nested list/map/blob/timestamp)
plus two representative cbor-only ops, CloudWatch `PutMetricData` and Translate
`TranslateText` — were cross-checked against **botocore's own RpcV2CBORSerializer**
when authored (driving botocore's `CBORSerializer` over constructed shapes); the
pinned bytes ARE botocore's output. `tools/verify_vectors.py` gains a
`cbor_codec` entry: an independent, pure-stdlib canonical-CBOR encoder that
re-derives the whole `tests/expected/cbor_codec.expected` fixture (bytes +
framing + the SigV4 signature, via the file's existing signer) toolchain-free, so
the fixture stays honest on a runner with no botocore (ran green). The Zap entry
`tests/cbor_codec.main.zap` reproduces the same bytes through `aws_core.cbor` and
is run by `tools/run-tests.sh` under the real toolchain in CI.

**Docker was NOT run** (it kernel-panics the dev host, standing rule). Host
validation: a front-end-only `zap` built from a detached `origin/main` worktree
(`cargo build -p zapc --bin zap`, no LLVM) passed `zap fmt --check` on
`aws-core/src tests examples` and `zap ir tests/cbor_codec.main.zap` (cross-package
type-check of the module + its imports through the materialized zenv) with no
diagnostics; the Python oracle re-derivation ran green. CI
(`ghcr.io/zaplang-io/zap:latest`) is the authoritative compile+run gate.

**Follow-up (aws-codegen).** The emitter walks each cbor service's model and emits
per-operation serialize/deserialize that builds a `CborValue` tree and calls
`cbor_encode` / `cbor_decode`, plus the manifest entries for the 25 services. The
real vectors here (the CloudWatch / Translate shapes) are the shape that generator
must reproduce byte-for-byte against this oracle.
