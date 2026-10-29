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

- **SigV4 signing**, proven byte-for-byte against AWS's published Signature
  Version 4 worked example and reproduced independently by a Python oracle:
  the `kDate→kRegion→kService→kSigning` key chain (via `crypto.hmac_sha256_raw`,
  I#153), canonical request, string-to-sign, signature, and `Authorization`
  header. Canonicalization is **generic**: callers pass a `dict[str,str]` of
  headers and the core lowercases, trims and sorts them (no hand-sorted header
  literals), so signing arbitrary header sets — including object metadata — is
  correct.
- **Credentials** from the environment (`AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`) — the provider that also covers
  Lambda.
- **DynamoDB** (awsJson 1.0): `get_item`, `put_item`. Keys and items are
  `dict[str,str]` maps (string + numeric attributes), read like boto3's
  `Key=...` / `Item=...`.
- **S3** (virtual-hosted-style): `get_object`, `put_object`, `list_objects_v2`,
  including the `x-amz-content-sha256` / `UNSIGNED-PAYLOAD` quirk. `put_object`
  takes `content_type=` and a `metadata={...}` dict (signed `x-amz-meta-*`);
  `list_objects_v2` takes `prefix=` / `max_keys=`.
- **HTTPS transport** over the stdlib `tls` sockets (raw HTTP/1.1, because the
  stdlib `http` client cannot set custom headers — see FRICTION.md #5).

Every signed request this SDK builds is reproduced bit-for-bit by an independent
SigV4 implementation in `tools/verify_vectors.py`.

## Layout

```
zap.toml                       package manifest (official-tier metadata)
src/aws/core.zap               shared core: credentials, SigV4, endpoints, transport
src/aws/dynamodb.zap           DynamoDB client (get_item, put_item)
src/aws/s3.zap                 S3 client (get_object, put_object, list_objects_v2)
tests/sigv4_vectors.main.zap   offline SigV4 conformance vs AWS's published vectors
tests/service_signing.main.zap offline: full signed DynamoDB/S3 requests, pinned
tests/expected/*.expected      pinned expected output
examples/*.main.zap            runnable live-AWS examples (get-item, list, put-object)
tools/bundle.py                stitch modules + a main() into one compilable file
tools/zrun.sh                  bundle + run with the Zap toolchain
tools/run-tests.sh             run the offline suite, diff vs expected
tools/verify_vectors.py        independent SigV4 oracle (toolchain-free CI cross-check)
```

The core and per-service modules are kept cleanly separated so the codegen
generator can slot in later (D-0011 §2). They are still **bundled** rather than
`import`ed: Zap-to-Zap module imports have since landed (zaplang-io/zap#283), but
local-module resolution is rooted at the entry file's own directory, so adopting
`import` cleanly means relocating every runnable entry (tests, examples) beside
the library or shipping the core as a materialized package. That re-layout is a
follow-up (see [FRICTION.md](FRICTION.md) #1); it is deliberately out of scope
for this ergonomic rewrite of the clients.

## Building the toolchain

The SDK is compiled and run by the `zap` toolchain from the sibling
`zaplang-io/zap` repo. `zap run file.zap` compiles via LLVM and executes.

- **With a local LLVM 18:** build `zap` from the `zap` checkout
  (`cargo build -p zapc --features llvm --bin zap`) and point `ZAP` at the
  resulting binary.
- **Without local LLVM (e.g. macOS):** use the repo's LLVM-18 dev container.
  Build it once (`make docker-build` in the `zap` checkout), then set
  `ZAP_REPO=/path/to/zap` and the scripts here run inside it. This is how v1 was
  developed and tested; see `tools/zrun.sh`.

## Running the offline tests

No AWS account or network needed — deterministic SigV4 vectors.

```bash
# toolchain-free: verify the pinned fixtures with the independent oracle
python3 tools/verify_vectors.py

# through the real toolchain (needs zap; or ZAP_REPO for the container):
ZAP=/path/to/zap/target/debug/zap tools/run-tests.sh
#   or, via the dev container:
ZAP_REPO=/path/to/zap tools/run-tests.sh
```

## Running against real AWS

The examples make a real signed call. Because the runtime cannot yet format the
current time into SigV4's basic timestamp (FRICTION.md #4), you supply the
timestamp from the shell:

```bash
export AWS_ACCESS_KEY_ID=...        AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...        # only for temporary credentials
export AWS_REGION=us-east-1
export ZAP_AWS_AMZ_DATE=$(date -u +%Y%m%dT%H%M%SZ)
export ZAP_AWS_DATE_STAMP=$(date -u +%Y%m%d)

# DynamoDB GetItem (edit table/key in the example):
ZAP_REPO=/path/to/zap tools/zrun.sh \
    src/aws/core.zap src/aws/dynamodb.zap examples/dynamodb_get_item.main.zap

# S3 ListObjectsV2:
export ZAP_AWS_BUCKET=my-bucket
ZAP_REPO=/path/to/zap tools/zrun.sh \
    src/aws/core.zap src/aws/s3.zap examples/s3_list_objects.main.zap

# S3 PutObject with a content type + metadata (boto3-style keyword args):
export ZAP_AWS_BUCKET=my-bucket ZAP_AWS_KEY=hello.txt
ZAP_REPO=/path/to/zap tools/zrun.sh \
    src/aws/core.zap src/aws/s3.zap examples/s3_put_object.main.zap
```

SigV4 rejects a timestamp skewed more than ~5 minutes, so run promptly after
setting the date vars. The example prints the signed request and the raw
response (response parsing awaits richer strings / an `xml` module).

## Known limitations

Driven by current language/stdlib gaps — full detail and minimal repros in
[FRICTION.md](FRICTION.md). Several v1 limits are now **resolved** (generic
canonicalization, computed `Content-Length`, dict-based items) — see FRICTION.md
"Resolved since v1". What remains:

- URI path segments and query keys/values must already be URI-safe (no
  per-segment percent-encode helper yet).
- SigV4 timestamps are supplied by the caller (no `datetime`→SigV4 strftime yet).
- Responses are returned raw (no HTTP response parsing; S3 is rest-xml with no
  `xml` module yet, D-0011 §4).
- Credential chain is env-only (shared-file / IMDSv2 / container deferred).
- Protocols: awsJson + raw SigV4 only; `rest-xml`/`query` deferred to the `xml`
  work. Retries, pagination, presigning: follow-ups.
- JSON/metadata string values must not need escaping (no JSON string-escape pass
  yet).

## License

Apache-2.0. See [LICENSE](LICENSE).
