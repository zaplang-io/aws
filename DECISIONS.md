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
