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
