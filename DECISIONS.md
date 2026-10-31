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

## D-0007 — the dynamic `call()` escape hatch is a thin envelope over the primitives, not a model loader (2026-10-30)

**Status:** accepted (ticket #365). Purely additive aws-core surface — like
D-0002/D-0003/D-0004/D-0005/D-0006 it adds a module and reuses the signing/
transport/endpoint primitives, touching no signing/codec/oracle path.

**Governing decisions.** D-0011 §8 (aws-core is the bounded hand-written runtime
the generated clients ride on); aws-codegen D-0001 (**generated-is-product**: the
typed per-service clients are the shipping SDK). This escape hatch is explicitly
the *non*-product path: the fallback for operations the generated clients do not
cover.

**Context.** Generated-op coverage is ~97% after the #364 rollout + the #424/#426
gap fixes. The uncovered remainder is (1) a small residual of skipped ops and
(2) the 25 `smithy-rpc-v2-cbor` services, which have no codec yet (#428). #365
asks for an "opt-in dynamic `call(name, params)`" so those operations are
reachable without a user hand-rolling SigV4 + transport + endpoint resolution
every time.

**The one design question — HOW dynamic.** The ticket's `call(name, params)`
strawman reads like a botocore-style runtime model loader (load the Smithy model,
project an arbitrary operation by name). Rejected, for two reasons:
- **It fights AOT/LLVM.** Zap compiles ahead of time; the shapes a program
  touches must be known to the compiler. A runtime model loader that
  materializes arbitrary input/output shapes from JSON has no typed surface to
  compile against — it would be an interpreter bolted onto an AOT language.
- **It undercuts generated-is-product.** A general dynamic client becomes a
  second, parallel SDK surface competing with the typed one, exactly what D-0001
  rules out. The escape hatch must stay visibly *lesser* than the generated
  clients — a raw-bytes fallback, not an alternative front door.

**Decision.** `aws_core.dynamic` is a **thin envelope over aws.core's existing
primitives**. The CALLER supplies every wire detail — `service`, `region`, HTTP
`method`, `path`, `query`, `headers`, a **pre-serialized `body`**, an optional
`host`, and a `PathMode` — and `call()` does only the three tedious, mechanical
steps: endpoint resolution, SigV4 signing, and send/parse. It owns **no protocol
framing**: the caller serializes the body and sets the Content-Type, an awsJson
`X-Amz-Target`, a CBOR `smithy-protocol` header, etc. New public surface:

- `enum PathMode { Decoded, PreEncoded }` — which signer the request rides.
- `struct DynamicRequest { method, service, region, host, path, query, headers,
  body, path_mode }` and `dynamic_request(...)` (all but method/service/region
  defaulted).
- `resolve_host(req)` — the caller's `host`, else `endpoints.regional_host`.
- `signing_headers(req, host, amz_date)` / `build_request(req, host, amz_date)` —
  inject the three SigV4 transport headers (host, x-amz-date, x-amz-content-sha256,
  the last only when the caller did not set one) so the header set MATCHES what
  `awsjson_headers` / `query_build_request` / `binding_headers` produce.
- `sign_dynamic(creds, req, amz_date, date_stamp)` / `sign_dynamic_now(...)` —
  sign to ready-to-send HTTP/1.1 text.
- `call(creds, req) -> core.Response` — resolve + sign (now) + `core.send`.
- `call_error(resp) -> Optional[errors.AwsServiceError]` and
  `call_checked(creds, req)` — typed-error mapping via aws_core.errors (#361).

**Signs identically — the load-bearing property.** `sign_dynamic` does not
reimplement signing; it dispatches on `PathMode` to the SAME two signer entry
points the generated clients use:
- `Decoded` → `core.sign_request` (the POST-"/" protocols awsJson/query and any
  decoded-path op; the signer percent-encodes the path, double-encoding the
  canonical URI off S3).
- `PreEncoded` → `binding.binding_sign` (the REST protocols and the CBOR
  services, whose `path` is already wire-encoded, so the signer must not
  re-encode).
Because `build_request` produces a `core.Request` with the same field values a
codec produces, the canonical request — hence the signature and the on-wire bytes
— is byte-identical to the generated/oracle path for identical inputs.

**Proof.** `tests/dynamic_call.main.zap` (pinned in
`tests/expected/dynamic_call.expected`, run by `tools/run-tests.sh`) builds three
representative requests both ways and asserts byte equality: an awsJson op
(DynamoDB GetItem) vs `aws_core.dynamodb`/`core.sign_request`; a query op (STS
GetCallerIdentity) vs `aws_core.query`/`core.sign_request`; and a CBOR-style
PreEncoded op vs `binding.binding_sign`. The codec paths are themselves pinned
against botocore in `service_signing.expected` and re-derived by
`tools/verify_vectors.py`, so "identical to the codec path" transitively means
"identical to botocore".

**No retries baked in.** `call()` is a single sign+send. The retry seam
(`aws_core.retry`) is protocol-agnostic and wraps a signed-request thunk, so a
caller that wants standard retry mode composes it around `call()` exactly as the
generated clients do — kept out of the escape hatch to leave the composition
explicit.

**Docker was not run** (it kernel-panics the dev host, standing rule) and the
local `zap` debug build is behind main. Host validation used a front-end-only
`zap` built from a throwaway `origin/main` worktree (`cargo build -p zapc --bin
zap`, no LLVM): `zap fmt --check` is clean on the new module + test (and the whole
repo), and `zap ir tests/dynamic_call.main.zap` type-checks the full dynamic path
(module + imports + the cross-module `PathMode` value + the `match` dispatch)
clean. `tools/verify_vectors.py` is green on the vectors the test anchors on. CI
(`ghcr.io/zaplang-io/zap:latest`) is the authoritative compile+run gate.

## D-0008 — smithy-rpc-v2-cbor codec: aws-core foundation, emitter deferred (2026-10-30)

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

## D-0009 — DynamoDB Key/Attr condition builder: a hand-written ergonomics module, boto3-byte-matched (2026-10-30)

**Status:** accepted (ticket #433, the first piece of ergonomics epic #432).

**Governing decisions.** aws-codegen D-0001 (generated-is-product: the generated
per-service clients are the shipping SDK; the resource-layer conveniences boto3
hand-codes on top of them are not derivable from botocore models, so they are
hand-written). D-0047 (operator overloading, `zaplang-io/zap#52`) for the
`&`/`|`/`~` DSL.

**Context.** boto3's `boto3.dynamodb.conditions.Key` / `Attr` and its
`ConditionExpressionBuilder` turn a chained, operator-combined condition into the
expression string + `ExpressionAttributeNames` + `ExpressionAttributeValues` that
every DynamoDB operation takes. The maintainer uses it heavily. It is the first
hand-written ergonomics layer, the Zap equivalent of boto3's resource-layer
conveniences — not an oracle fixture like `s3.zap` / `dynamodb.zap`, but real
shipping aws-core surface that users of the generated DynamoDB client compose.

**Decision.** A new shipping module `aws_core.conditions`:

- `Key(name)` / `Attr(name)` return an `AttrRef`; its methods build leaf
  `Condition`s: `eq lt lte gt gte between begins_with` (the Key subset) plus
  `ne contains attribute_type exists not_exists is_in size` (Attr additions),
  matching boto3's method split. `size()` flags the subject so a following
  comparison wraps it in `size(...)`.
- `&` / `|` / `~` on `Condition` (via `__and__`/`__or__`/`__invert__`) are AND /
  OR / NOT with boto3's parenthesization.
- Value operands are an `AttrValue` built by `S` / `N` / `Bool` / `Null`.
- `build(cond) -> Built` is the stateful one-pass numbering, the counterpart of
  `ConditionExpressionBuilder.build_expression`.

**Oracle.** Output byte-matches boto3's `ConditionExpressionBuilder`:
`tools/gen_condition_vectors.py` drives the real boto3 `Key`/`Attr` DSL for 25
vectors, cross-checks a pure-Python mirror of the Zap algorithm against it, and
writes `tests/expected/conditions.expected`; `tests/conditions.main.zap` prints
the same `### / EXPR / NAME / VAL` blocks through the Zap module and
`tools/run-tests.sh` diffs them. Matching facts pinned by the oracle:

- **No dedup.** boto3 assigns a fresh `#nN` / `:vN` to every occurrence, even of
  the same attribute name or value; so does this module. (The task brief's
  mention of "dedup" does not match boto3's actual behaviour — the builder never
  dedups — and matching boto3 wins.)
- Placeholders are numbered in a left-to-right depth-first walk; within a leaf
  the name placeholder(s) precede the value(s). The tree is immutable (so the
  operators stay pure) and numbered in one pass, exactly as boto3 does.
- Nested document paths split on `.`; bracket indices stay literal
  (`a.b.c` -> `#n0.#n1.#n2`, `a[0].b` -> `#n0[0].#n1`). boto3 uses a regex
  (`ATTR_NAME_REGEX`); this module reproduces it for well-formed names with a
  split-on-`.` + first-`[` scan (string char-index-then-compare hits ZAP6001 on
  the current toolchain, so the regex is not transliterated char by char). A
  name with text after a bracket group in the same segment and no dot
  (`a[0]foo`, not a real DynamoDB path) is the one documented divergence.

**Values (#434 seam).** boto3's `ConditionExpressionBuilder` emits the RAW values
(a later `TypeSerializer` in the resource layer makes AttributeValues). Native
<->AttributeValue marshalling is ticket #434, queued separately. #433 mirrors the
builder: `ExpressionAttributeValues` carries the raw-value JSON the builder
produces (string -> `"x"`, number -> bare digits, bool -> `true`/`false`,
null -> `null`); numbers are passed as decimal text (`N("30")`) to avoid float
rounding. `AttrValue` is the single seam #434 slots into — it will add native
int/float/Decimal/bytes coercion and the AttributeValue wire form with no change
elsewhere. No JSON string escaping on this hand path (matches `dynamodb.zap`).

**Toolchain gap found (blocks the fluent inline form; NOT an aws-repo bug).**
`zaplang-io/zap` sema types every user-struct METHOD-call return as `Unknown`
(crates/sema/src/lib.rs, the `recv.method(args)` fallthrough returns `Ty::Unknown`
for a non-str/dict/Py receiver instead of resolving the method's declared return
from `struct_info`). So the headline `Key("pk").eq(x) & Attr("age").gt(y)` does
not yet compile: the method results are `Unknown`, and `Unknown & Unknown` falls
back to the built-in bitwise `&` (int64) rather than dispatching `__and__`.
Binding each leaf to its declared type first (`Condition c = Attr("x").eq(v)`)
makes the operator dispatch and the output correct — the conformance test does
this, so it is green on today's toolchain, and the builder logic/output are
unaffected. Operator codegen itself is fine (the dunders lower and run). The
clean fix is a small, host-verifiable sema change (resolve the return type via
`struct_info(recv_ty).methods.get(name)` in that fallthrough), after which the
fluent inline form works unchanged; recommended as a `zaplang-io/zap` follow-up.

**Verification.** Host front-end only (Docker crashes the maintainer's host, so
the local LLVM/Docker gate was skipped): a throwaway `origin/main` `cargo build -p
zapc` front-end ran `zap fmt --check` and `zap ir` (full type-check through the
materialized zenv) clean on the module and the test; the boto3 oracle generator
re-derived green and its Python mirror byte-matches boto3 on all 25 vectors. CI
(`ghcr.io/zaplang-io/zap:latest`) is the authoritative compile+run gate.

## D-0010 — DynamoDB native <-> AttributeValue marshalling: boto3-byte-matched (2026-10-30)

**Status:** accepted (ticket #434, the second piece of ergonomics epic #432).

**Governing decisions.** aws-codegen D-0001 (generated-is-product: the resource-
layer conveniences boto3 hand-codes are not derivable from botocore models, so
they are hand-written). Builds directly on D-0009 (#433, the condition builder),
whose `AttrValue` left the value-marshalling seam this ticket fills.

**Context.** boto3's `boto3.dynamodb.types.TypeSerializer` / `TypeDeserializer`
turn native Python values into the DynamoDB `AttributeValue` wire shape and back,
so callers pass/read native data instead of hand-building `{"S": ...}` maps. The
maintainer uses these heavily. This is the Zap counterpart, the second hand-
written ergonomics module after `conditions`.

**Decision.** A new shipping module `aws_core.marshal`:

- A `Value` sum type models a marshallable native value: `S N Bool Null B L M SS
  NS BS` (the same shape as `cbor.CborValue`, recursive for `L`/`M`). Numbers
  ride as decimal STRINGS under `N` (DynamoDB's wire form); blobs as raw `bytes`,
  base64-encoded only at the wire.
- Native constructors `s n_int n_str n_float boolean null b l m ss ns bs`.
- `serialize(Value) -> str` emits the AttributeValue wire JSON (boto3's
  `TypeSerializer`); `deserialize(str) -> Value` parses it back via `json.loads`
  (boto3's `TypeDeserializer`) — the exact inverse.
- `from_scalar(conditions.AttrValue) -> Value` bridges a #433 condition value, so
  a condition's `ExpressionAttributeValues` flow through this marshaller.
- N accessors `n_is_integral` / `n_as_int` give the "int when integral" read; the
  stored form stays the exact decimal string (consistent with `dynamodb.zap`),
  so no float rounding is forced on deserialize.

**Oracle.** Output byte-matches `boto3.dynamodb.types`:
`tools/gen_marshal_vectors.py` runs the real boto3 `TypeSerializer` /
`TypeDeserializer` for 20 vectors, cross-checks a pure-Python mirror of the Zap
algorithm against it, and writes `tests/expected/marshal.expected`;
`tests/marshal.main.zap` prints the same `### / SER / RT` blocks through the Zap
module (SER = serialize, RT = serialize∘deserialize, proving the inverse) and
`tools/run-tests.sh` diffs them. Canonicalization facts pinned by the oracle:

- **Blobs are base64 at the wire.** boto3's `TypeSerializer` leaves `B`/`BS` as
  RAW bytes (an intermediate consumed by botocore's awsJson serializer, which
  base64-encodes them on the wire). `marshal` emits the wire form directly, so
  the oracle base64-encodes blobs to match.
- **Sets (SS/NS/BS) are unordered.** boto3 iterates a Python `set`, whose order
  is arbitrary and non-reproducible. Both sides SORT the rendered element tokens
  (lexically; the vectors are ASCII, so Zap `sorted` and Python `sorted` agree),
  giving stable pinned bytes.
- **Map member order.** On SERIALIZE a map keeps caller/insertion order (boto3
  iterates the dict in order; `Value.M` keeps parallel key/value list order). On
  DESERIALIZE a map has no inherent order, so keys are canonicalized to sorted
  order; the vectors use sorted keys, so serialize∘deserialize round-trips.
- **No JSON string escaping** on this hand path (matches `dynamodb.zap` /
  `conditions.zap`): values avoid characters that need escaping. A shared
  escaping pass is a follow-up for all three hand paths.

**Divergence — float.** boto3's `TypeSerializer` REJECTS raw `float`
(`TypeError: Float types are not supported. Use Decimal types instead.`), because
binary floats round. Zap has native `float`, and Zap programs will pass it, so
`n_float(float64)` is accepted and formatted via the native `str(float)`. The
BYTE-MATCHED numeric paths are `n_int` (exact) and `n_str` (an exact decimal
string, the path `conditions.N` feeds); callers who need exact digits use
`n_str`. No `n_float` output string is pinned in the oracle: boto3 produces no
float vector to match, and the exact `str(float)` bytes are a runtime value the
host front-end gate (`zap ir`, type-check only) cannot confirm — pinning an
unverifiable golden would be a fake. `n_float` is covered by CI compilation, not
by a pinned byte assertion.

**Verification.** Host front-end only (Docker crashes the maintainer's host, so
the local LLVM/Docker gate was skipped): a throwaway detached `origin/main`
`cargo build -p zapc` front-end ran `zap fmt --check` clean on the module +
test, and `zap ir tests/marshal.main.zap` (full type-check of the module and its
`base64` / `conditions` / `json` imports through the materialized zenv) emitted
ZIR with no diagnostics; the boto3 oracle generator re-derived green and its
Python mirror byte-matches boto3 on all 20 vectors with the round-trip identity
holding. CI (`ghcr.io/zaplang-io/zap:latest`) is the authoritative compile+run
gate.

## D-0011 — paginators are a generic lazy page-iterator engine in aws-core (2026-10-30)

**Status:** accepted (ticket #436, ergonomics epic #432).

**Governing decisions.** zaplang-io/zap D-0011 §7 (aws-core owns the
request-lifecycle seams — retry, waiting, and now pagination; cited by its home id
to disambiguate from this local entry); zaplang-io/zap#429 (generators-as-methods:
`yield` in a `self`-bearing method lowers to the iterator state machine);
aws-codegen D-0001 (generated-is-product; aws-core is the runtime those clients
ride on). Follows D-0004 (waiters) as the paginator analogue of the waiter engine,
and is purely additive.

**Context.** A paginator walks every page of a paginated listing without the
caller threading continuation tokens by hand (boto3's
`client.get_paginator('op').paginate(...)`, which the maintainer uses heavily).
botocore models each paginated op in `paginators-1.json` as `{input_token,
output_token, result_key, limit_key?, more_results?}`: `output_token` is read from
each response and written to the next request's `input_token`; `result_key` is the
response field holding the page's result list; `limit_key` is the page-size input;
`more_results`, when present, is a response boolean that gates continuation. The
walk stops when `output_token` is absent/empty (and, when modeled, `more_results`
is false). The aws-codegen generator already emits per-op `paginate_<op>`
generator methods inline (aws-codegen I#349), each re-deriving this same loop from
`paginators-1.json` — the duplication D-0004's waiter decision anticipates folding
into a shared engine.

**Decision.** The capability is added as a new **generic** module
`aws_core.paginators` — the ENGINE only, mirroring `aws_core.waiters`. Per-op
config is supplied by the CALLER (or a generated per-op shim; see the follow-up);
the engine is service-agnostic. New public surface:

- `struct PaginatorConfig { str input_token; str output_token; str result_key;
  str limit_key; str more_results }` — the `paginators-1.json` shape. The engine
  reads `output_token` / `result_key` / `more_results`; `input_token` / `limit_key`
  are what the fetch CLOSURE applies to each request (carried here so a generated
  shim can construct the whole model in one place, exactly as `WaiterConfig`
  carries the full acceptor table). `paginator_config(input_token, output_token,
  result_key)` is the common-case constructor (no limit/more-results gate), which
  is the aws-codegen qualification gate: a single string token plus a result key.
- `struct Paginator { PaginatorConfig config; fn(str) -> Response fetch }` and the
  constructor `paginator(cfg, fetch) -> Paginator`. The `fn(str) -> Response`
  fetch seam mirrors aws.retry's `fn() -> Response` and aws.waiters' `fn() -> Poll`:
  given the continuation token ("" for the first page), the closure writes it into
  `input_token` (and applies `limit_key`), calls the generated operation, and
  returns its `Response`. Which operation to call and how to sign it is the
  closure's job — the engine stays independent of any service's request builders,
  the same way `operation` is deliberately unmodeled in aws.waiters.
- Generator methods `pages(self)` and `items(self)` — the boto3 `.paginate(...)`
  analogue and its item-level iteration. `pages` yields each page `Response`,
  threading `output_token` -> the next token; `items` yields each `result_key`
  element across all pages, lazily. Both lower to the iterator state machine via
  zaplang-io/zap#429 (the prerequisite), the exact shape the generated clients'
  per-op paginators emit. A function-typed field is called by binding it to a
  `fn(...)`-annotated local first (`fn(str) -> Response fetch = self.fetch`), the
  always-valid form aws.middleware uses (I#163/D-0067). `items` inlines the page
  loop rather than iterating `self.pages()`, so each is one flat generator.
- `all_pages(p) -> list[Response]` and `all_items(p) -> list[JsonValue]` — eager
  accumulators (boto3 `build_full_result` territory). `all_items` is the merged
  result list for the common single-result-key paginator.

**Config-sourcing seam.** The engine is generic and hand-written in aws-core; the
per-op config comes from `paginators-1.json`, which lives in the **aws-codegen**
repo, not here. This PR keeps that config at the CALLER: `PaginatorConfig` is
constructed by whoever drives the paginator (the test fixtures stand in for it,
as the real waiter fixtures do for waiter tables). No `paginators-1.json` is read
or emitted in this repo, so the PR stays single-repo (aws). Reading the token from
the response reuses aws.core's existing `next_page_json` awsJson hook; `result_key`
/ `more_results` are read over a `json.loads` `JsonValue` DOM (the same prelude
enum aws.waiters walks), so item iteration and the gate stay codec-independent.

**Parsed-response seam.** `result_key` is dotted field access over the DOM (no
projections — simpler than waiter JMESPath); `more_results` is a top-level boolean.
This is additive — no signing, codec, or byte-diff oracle behavior changes.

**Verification.** Behavioral, without the Zap toolchain/Docker (Docker crashes the
maintainer's host, so the local LLVM/Docker gate was skipped). `tests/paginators.main.zap`
drives the engine through its `fn(str) -> Response` fetch seam with an injected
fake client returning canned multi-page bodies (page 1 carries a token, page 2
does not), asserting both pages / all items are yielded, the threaded tokens, and
termination; plus the single-page (no-token) case and an S3 `IsTruncated`
`more_results` gate where a page carries a token yet stops the walk. The fixtures
are real paginator configs (DynamoDB `ListTables`, S3 `ListObjectsV2`). The pinned
`tests/expected/paginators.expected` was produced by an independent Python mirror
of the engine (the same `json_string_field` naive-scan + loop), not hand-guessed,
since the host build has no codegen. A throwaway detached `origin/main`
`cargo build -p zapc` front-end ran `zap fmt --check` clean on the module + test
and `zap ir tests/paginators.main.zap` (full type-check through the materialized
zenv, including the generator methods and the function-typed-field call) emitted
ZIR with no diagnostics. CI (`ghcr.io/zaplang-io/zap:latest`) is the authoritative
compile+run gate.

**Blocked on a toolchain codegen gap (zaplang-io/zap#453).** CI compiles cleanly
but runs the paginator test with EMPTY stdout — a whole-program lowering failure,
not a runtime crash (not even the first `print` runs). The front-end accepts it
(`zap ir` clean); only the LLVM backend path fails. First filed as zap#451
("generator method in an imported module yielding a struct"); zap#451's fix +
bisection goldens (zap PR #452) made the GENERIC case pass (a generator method in
a module yielding a simple all-scalar struct), but the aws paginator STILL emits
empty output. Narrowing against #452's now-passing golden isolates a distinct,
narrower trigger — tracked as **zap#453**: the generator's struct carries a
**function-typed field** (the caller-supplied fetch closure) and `self` (holding
it) is spilled across the `yield`. (The closure is reached only through a plain
sibling method, never called inside the generator frame, and the yielded
`Response` is not kept live across the suspend — so the fn-field-in-`self` is the
suspect, not a mid-frame closure call or a dict-bearing yield.) This shape is
intrinsic to a lazy paginator that calls a client closure, so it cannot be worked
around while keeping `yield`. The decision stands as written (the engine is
correct and the FE accepts it); the PR's CI is intentionally red pending the
zap#453 fix. The proven D-0048 `__iter__`/`__next__` + `raise StopIteration`
protocol (the `stop_iter` run-golden; closure in a plain `__next__`, never a
coroutine frame) is the validated drop-in fallback — identical
`for page in paginator.pages()` ergonomics, no API change — if we later choose not
to wait on zap#453.

**Follow-up (aws-codegen).** aws-codegen I#349 already emits per-op `paginate_<op>`
generator methods that inline this loop. The follow-up is to have the generator
emit, per paginated op, a `PaginatorConfig` (from `paginators-1.json`) plus a thin
`paginate_<op>(self, input)` that builds the fetch closure (set `input_token` /
`limit_key`, call the op) and returns `paginators.paginator(cfg, closure).pages()`
— collapsing the duplicated inline loops onto this shared engine, exactly as the
waiter-table follow-up (D-0004) collapses onto `aws_core.waiters.wait`. Tracked as
an aws-codegen follow-up; the fixtures in `tests/paginators.main.zap` are the shape
that generated config must reproduce. A richer token model (parallel-list or map
tokens, e.g. DynamoDB Query/Scan `ExclusiveStartKey`) and a full
`build_full_result` that merges every output field (not just the result list) are
later work.
