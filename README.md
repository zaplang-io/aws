# aws — the official Zap AWS SDK

AWS clients for the [Zap](https://github.com/zaplang-io/zap) language, in the
official-packages tier (D-0056): developed under `zaplang-io`, installed and
managed by the Zap package manager — **not** a bundled stdlib module. The design
is [D-0011](https://github.com/zaplang-io/zap/blob/main/design/0011-aws-sdk.md).

> **Status: hand-written S3 + DynamoDB + SigV4 core.** A deliberately small,
> hand-written slice — a shared SigV4/credentials/transport **core** plus
> hand-written **S3** and **DynamoDB** clients — built to make Zap runnable
> against real AWS and to surface the language/stdlib gaps that a real SDK hits.
> The production SDK is build-time code generation from the botocore service
> models (D-0011 §1); that generator is a later phase.
>
> Several of the gaps the first cut hit have since landed in the language
> (real strings, f-strings, default/keyword arguments, dict iteration + `get`),
> and this slice has been **reworked to the ergonomic, boto3-faithful API** they
> enable: keyword arguments with defaults, `dict` headers/metadata/keys, generic
> dict-driven SigV4 canonicalization, and `Content-Length` computed for you. The
> remaining friction is written up in [FRICTION.md](FRICTION.md) and is a primary
> deliverable.

## What works today

- **Real SigV4 signing**, proven byte-for-byte against AWS's published Signature
  Version 4 worked example and reproduced independently by a Python oracle:
  the `kDate→kRegion→kService→kSigning` key chain (via `crypto.hmac_sha256_raw`,
  I#153), canonical request, string-to-sign, signature, and `Authorization`
  header. Canonicalization is the genuine algorithm: the canonical URI is
  percent-encoded (double-encoded for non-S3 services) and the query is
  RFC-3986-encoded + sorted via the `url` module; header names are
  lowercased/trimmed/sorted from a `dict[str,str]`. The `x-amz-date` and scope
  date are stamped from the current time with `datetime` (`sign_request_now`).
- **Request/Response model**: per-service code builds a `Request`
  (method/service/region/host/path/query/headers/body) and hands it to the
  runtime; `send`/`parse_response` return a parsed `Response`.
- **Endpoint / region resolution** (`aws.endpoints`, #342): a structured
  resolver — partition awareness (`aws` / `aws-cn` / `aws-us-gov`), the
  `{service}[-fips].{region}.{dnsSuffix|api.aws}` service template, and S3
  addressing (virtual-hosted vs path style by bucket DNS-compatibility or a
  flag, the `s3.dualstack` / `-fips` labels, and the us-east-1 global quirk).
  The v1 core template names stay as thin shims over it. The full AWS
  endpoint-ruleset JSON engine (access points, custom endpoints) can replace the
  bodies without reshaping callers (#342 follow-up).
- **Seams for the later phases**: a credentials seam (env + static now; full
  provider chain #341), endpoint/region resolution (`aws.endpoints`, #342),
  retry (standard mode — see `aws.retry`), error dispatch (`parse_error` →
  typed `AwsError`), and pagination hooks.
- **Credentials** from the environment (`AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`) — the provider that also covers
  Lambda — or from static keys.
- **DynamoDB** (awsJson 1.0): `get_item`, `put_item`. Keys and items are
  `dict[str,str]` maps (string + numeric attributes), read like boto3's
  `Key=...` / `Item=...`.
- **S3** (virtual-hosted-style): `get_object`, `put_object`, `list_objects_v2`,
  including the `x-amz-content-sha256` / `UNSIGNED-PAYLOAD` quirk. `put_object`
  takes `content_type=` and a `metadata={...}` dict (signed `x-amz-meta-*`);
  `list_objects_v2` takes `prefix=` / `max_keys=`.
- **HTTPS transport** over the stdlib `tls` sockets: the signed HTTP/1.1 request
  is sent over a verified TLS connection and the reply is parsed into a
  `Response { status, headers, body }` (see FRICTION.md #5 on why the transport
  stays hand-built).

Every signed request this SDK builds is reproduced bit-for-bit by an independent
SigV4 implementation in `tools/verify_vectors.py`.

## Layout

```
zap.toml                       root consumer manifest (dep aws_core = path aws-core)
zap.lock                       committed lockfile (D-0052)
aws-core/zap.toml              the aws_core PACKAGE manifest ([package] name = "aws_core")
aws-core/src/aws_core.zap      package root module (bare `import aws_core`)
aws-core/src/core.zap          shared core: credentials seam, SigV4, transport, seams
aws-core/src/endpoints.zap     partition/region/endpoint resolver + Endpoint (#342)
aws-core/src/credentials.zap   boto3-style credential provider chain (env/INI/IMDS/container/process)
aws-core/src/retry.zap         standard-mode retry: backoff + retry-quota token bucket (#343)
aws-core/src/binding.zap       protocol-agnostic HTTP binding layer
aws-core/src/awsjson.zap       awsJson 1.0/1.1 codec
aws-core/src/restjson.zap      rest-json codec
aws-core/src/restxml.zap       rest-xml codec
aws-core/src/dynamodb.zap      PARKED hand-written DynamoDB oracle (byte-diff fixture)
aws-core/src/s3.zap            PARKED hand-written S3 oracle (byte-diff fixture)
tests/sigv4_vectors.main.zap   offline SigV4 conformance vs AWS's published vectors
tests/service_signing.main.zap offline: full signed DynamoDB/S3 requests, pinned
tests/endpoints_resolution.main.zap offline: endpoint resolution matrix, pinned
tests/retry.main.zap           offline: retry classification + backoff, pinned
tests/credentials_chain.main.zap offline: provider chain ordering + INI/JSON/process parsers
tests/expected/*.expected      pinned expected output
examples/*.main.zap            runnable live-AWS examples (get-item, list, put-object)
tools/run-tests.sh             materialize the zenv, run the offline suite, diff vs expected
tools/verify_vectors.py        independent SigV4 oracle (toolchain-free CI cross-check)
```

aws-core ships as a **zenv package** named `aws_core` (D-0011 §8, D-0052),
consumed through real Zap module imports (zaplang-io/zap#283) — the
`tools/bundle.py` concatenation workaround is retired (#339). Each test/example
is a real program that does `import aws_core.<module>` (e.g.
`import aws_core.core`, `import aws_core.binding`), and the repo root is the
first consumer of that package. See [DECISIONS.md](DECISIONS.md) (D-0001) for the
package layout, the module graph, and the import contract the generated
per-service clients (aws-codegen) build on.

## Building the toolchain

The SDK is compiled and run by the `zap` toolchain from the sibling
`zaplang-io/zap` repo. `zap run file.zap` compiles via LLVM and executes.

- **With a local LLVM 18:** build `zap` from the `zap` checkout
  (`cargo build -p zapc --features llvm --bin zap`) and point `ZAP` at the
  resulting binary.
- **Without local LLVM (e.g. macOS):** use the repo's LLVM-18 dev container (or
  the prebuilt `ghcr.io/zaplang-io/zap:latest` image CI uses). The front-end
  (module resolution, type-check) and `zap fmt` are host-safe and need no LLVM;
  only `zap run` / `zap build` need the toolchain image.

aws-core is imported, not bundled, so programs resolve it through the project
zenv. Materialize it once per checkout and activate it:

```bash
zap zenv create --no-venv     # copies aws-core into zenv/pkg/aws_core
source zenv/activate          # sets ZAP_ZENV so `import aws_core.*` resolves
```

## Running the offline tests

No AWS account or network needed — deterministic SigV4 vectors.

```bash
# toolchain-free: verify the pinned fixtures with the independent oracle
python3 tools/verify_vectors.py

# through the real toolchain (needs zap on PATH, or $ZAP): materializes the zenv
# itself, compiles+runs each entry, diffs stdout against tests/expected/*
tools/run-tests.sh
```

## Running against real AWS

The examples make a real signed call. The SigV4 timestamp is now stamped by the
SDK from the current UTC time (`sign_request_now` / `datetime`), so only the
credentials and region are needed (the v1 `ZAP_AWS_AMZ_DATE` /
`ZAP_AWS_DATE_STAMP` vars are gone — FRICTION.md #4 resolved). Run each example
as an ordinary program with the zenv active (see above):

```bash
export AWS_ACCESS_KEY_ID=...        AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...        # only for temporary credentials
export AWS_REGION=us-east-1
source zenv/activate

# DynamoDB GetItem (edit table/key in the example):
zap run examples/dynamodb_get_item.main.zap

# S3 ListObjectsV2:
export ZAP_AWS_BUCKET=my-bucket
zap run examples/s3_list_objects.main.zap

# S3 PutObject with a content type + metadata (boto3-style keyword args):
export ZAP_AWS_BUCKET=my-bucket ZAP_AWS_KEY=hello.txt
zap run examples/s3_put_object.main.zap
```

SigV4 rejects a timestamp skewed more than ~5 minutes, so the host clock must be
roughly correct. The example prints the signed request, then the parsed response
status and body (via `aws.core.send` / `parse_response`), and surfaces a typed
error through `parse_error` on a non-2xx reply (a full `xml` body parser is still
future work — D-0011 §4).

## Known limitations

Driven by current language/stdlib gaps — full detail and minimal repros in
[FRICTION.md](FRICTION.md). Phase 0 + the Phase-1 aws-core rewrite resolved the
big v1 limits (real percent-encoded URI/query canonicalization, SDK-stamped SigV4
timestamps, generic header canonicalization, computed `Content-Length`,
dict-based items) — see FRICTION.md "Resolved in Phase 1". What remains:

- Credential chain is env + static only; the shared-config-file, IMDSv2,
  container, and process providers are deferred to the credential seam (#341).
- Endpoint resolution (`aws.endpoints`, #342) covers partitions, the FIPS and
  dualstack knobs, and S3 virtual-vs-path addressing; the full data-driven AWS
  endpoint-ruleset engine (access points, custom/sdk endpoints, the iso
  partitions) is the #342 follow-up.
- Retry is AWS "standard" mode (`aws.retry`): throttling/transient error
  classification, exponential backoff with full jitter, and a per-client
  retry-quota token bucket, wrapped around the sign+send path by `retry_send`.
- Error dispatch and pagination are minimal baselines over the seams; a full
  per-service error-shape registry and generated paginators are follow-ups.
- Response parsing is status + headers + body; no chunked-transfer decode, and
  S3's rest-xml body is returned raw (no `xml` body parser yet, D-0011 §4).
- Protocols: awsJson + S3 rest SigV4. The modules are linked via real Zap module
  imports (aws-core is a zenv package; #339 step 1, zaplang-io/zap#283); the
  `tools/bundle.py` concatenation workaround has been retired.
- JSON/metadata string values must not need escaping (no JSON string-escape pass
  yet).

## License

Apache-2.0. See [LICENSE](LICENSE).
