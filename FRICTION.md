# Language & stdlib friction — building the AWS SDK thin vertical

Dogfooding report from writing real AWS code in Zap (the point of the v1 thin
vertical, per D-0011 and I#89). Each item has a minimal repro, the impact on the
SDK, the workaround taken, and the filed issue. Ordered by how much it blocked a
real SDK.

Everything here was found with the toolchain built from `zaplang-io/zap@main`
(LLVM 18 dev container). "front-end OK" vs "codegen error" matters: several
constructs **type-check** but do not **codegen** yet, so they bite only at run
time.

## What worked well (worth stating)

- `crypto.hmac_sha256_raw` (I#153) chains exactly as SigV4 needs: a `bytes`
  digest feeds straight back as the next key, and the hex-returning
  `crypto.hmac_sha256` / `crypto.sha256` cover every SigV4 hex output. The whole
  signing core is pure `+` and `crypto` and reproduced AWS's published vectors
  byte-for-byte on the first run.
- `os.getenv` / `os.hasenv`, `tls.connect` (verify-on), structs with
  keyword-arg construction, `@derive(Json)` + `Optional[T]`, and `list.append` /
  indexing / `for x in list` all behaved as expected.

## Resolved since v1 (this rewrite)

The language moved fast; several of the biggest v1 blockers are now fixed, and
this rewrite adopts them. Kept as a record of what the dogfooding surfaced and
what unblocked it.

- **Opaque strings (was #2) — RESOLVED** by zaplang-io/zap#284/#285. `str`
  indexing/slicing/`==`/`<`, `for c in s`, methods (`lower`/`strip`/`split`/…),
  `ord`/`chr`, `str(int)`, f-strings and `format()` all work now. SigV4
  canonicalization is therefore **generic**: `aws.core.canonical_headers` takes a
  `dict[str,str]`, lowercases names, trims values and sorts — no hand-sorted
  literal header runs. `credentials()` derives `has_session` from the token
  (string `==` works), though the `Credentials.has_session` field stays as the
  public shape.
- **No `int→str` / f-strings (was #3) — RESOLVED** by zaplang-io/zap#285.
  `Content-Length` is now `str(len(body))` inside the SDK; the
  `content_length: str` parameter that used to be threaded through every
  operation (and hard-coded in examples) is gone.
- **Default + keyword arguments — LANDED** (zaplang-io/zap#298). Operations take
  keyword args with defaults, so S3 `put_object(..., content_type=...,
  metadata={...})` and `list_objects_v2(..., prefix=..., max_keys=...)` read like
  boto3.
- **Dict iteration / membership / `get` — LANDED** (zaplang-io/zap#299, #281).
  Headers, query params, metadata and DynamoDB keys/items are ordinary dicts,
  iterated to build canonical requests; `dict.get(k) -> Optional[V]` is used for
  safe probing.
- **Module imports (#1) — LANDED but not yet adopted here**, see below.

## Resolved in Phase 1 (aws-core runtime)

Phase 0 landed the last of the string/number/time surface the signer needed, so
the aws-core rewrite (zaplang-io/zap#340) is the *real* SigV4 algorithm — the
pre-normalized workarounds documented below are gone. What unblocked what:

- **Percent-encoding (was the last piece of #2) — RESOLVED** by the `url` module
  (zaplang-io/zap#335). `aws.core.canonical_uri` is `url.quote_path(path)`,
  double-encoded for every non-S3 service (AWS's rule); `aws.core.canonical_query`
  is `url.canonical_query(dict)` (each key/value RFC-3986-encoded, pairs sorted).
  Reserved characters in a path segment or query value — e.g. a `/` in an S3
  `prefix` — are now encoded (`%2F`) exactly as botocore does. This removed the
  v1 "URIs/query keys must already be URI-safe" caveat.
- **`datetime` SigV4 timestamp (was #4) — RESOLVED** by zaplang-io/zap#286/#338.
  `datetime.strftime(now(), "%Y%m%dT%H%M%SZ")` / `"%Y%m%d"` build the `x-amz-date`
  and scope date, so `aws.core.sign_request_now` can stamp a live request itself.
  The caller-supplied `ZAP_AWS_AMZ_DATE` / `ZAP_AWS_DATE_STAMP` env vars are gone.
- **`and` / `or` short-circuit — RESOLVED** by zaplang-io/zap#367. The v1
  insertion sort was written around the old eager evaluation; with real
  short-circuiting (and `list.sort`, below) it is deleted.
- **`list.sort` / `sorted` — RESOLVED** by zaplang-io/zap#336. `aws.core`'s
  hand-rolled `sorted_strings` insertion sort is replaced by the `sorted`
  builtin for canonical header/attribute ordering.
- **`bytes` / `base64` / `hex` — LANDED** (zaplang-io/zap#337). Not needed by the
  SigV4 core (its hex outputs come from the hex-returning `crypto` functions),
  but available for binary payloads (DynamoDB `B` attributes, etc.).

## Credential provider chain (zaplang-io/aws#341)

`src/aws/credentials.zap` is the full boto3-style chain on top of the Phase 0
stdlib. Everything it needs was expressible with no new language friction:

- **What worked.** `os.getenv/hasenv/setenv` + `fs.exists/read_file` cover the
  env and shared-INI providers; `http.request(method,url,body,headers)` /
  `http.get(url,headers)` (zaplang-io/zap#280) drive the IMDSv2 PUT-token /
  GET-creds handshake and the ECS/EKS container endpoint; `process.run(argv) ->
  (code,out,err)` (tuple-destructured) runs a `credential_process`; and
  `datetime.strptime(exp, "%Y-%m-%dT%H:%M:%SZ")` + `to_timestamp` (#338) give the
  expiry math the cache needs. Nested structs (a cache holding a record), lists
  of structs (`first_ok`), and recursion (`source_profile`) all codegen cleanly.
  The metadata/container/process JSON is read with the same best-effort
  `aws.core.json_string_field` the error path uses — a full JSON parser (D-0011
  §4) is not required for these flat, server-produced objects.
- **`chr(n)` returns `char`, not `str`.** `ini_sep()` had to wrap it as
  `str(chr(31))` to satisfy a `-> str` return; a bare `chr(31)` is a `char`
  return-type mismatch. Minor, consistent with the codepoint/char model (#284).

### Two design decisions flagged for review

- **source_profile without STS.** A profile with `role_arn` + `source_profile`
  resolves the *source* profile's base credentials, but the STS `AssumeRole`
  call that would exchange them for the role's temporary creds is **deferred** —
  the SDK has no STS client yet. Documented at the call site; the chain still
  yields usable base credentials rather than failing.
- **Container provider BEFORE IMDS.** The ticket lists IMDS (3) ahead of the
  container endpoint (4); the implementation keeps botocore's order (container
  first) on purpose. An ECS task runs *on* an EC2 instance whose IMDS is
  reachable, so trying IMDS first would hand back the instance role instead of
  the task role. `credential_process` and `source_profile` (ticket items 5 and
  part of 2) are profile-driven, so they resolve inside the shared-config
  provider rather than as standalone chain steps.

### Still-open friction found during this work

- **No keyword-only marker.** A bare `*` separator in a parameter list
  (`def f(a, *, b=1)`) does not parse; optional params are just trailing
  defaulted positionals. Put all optional/keyword params last.
- **`dict.get` needs an annotated sink.** `Optional[str] v = d.get(k)` works;
  the inline `d.get(k).unwrap_or(...)` fails to resolve `Optional[V]` in mono
  (documented in zaplang-io/zap#281).
- **f-string fields can't nest the field quote.** `f"{d.get(\"k\")}"` fails to
  lex; bind to a local first. (Already noted upstream in #285.)

## 1. No Zap-to-Zap package / module imports  — now LANDED (#283), not yet adopted

`import` resolves only stdlib modules and `import python`; project mode compiles
exactly one entry file (`src/main.zap`). There is no way for one `.zap` file to
use defs from another, so a multi-module package cannot be built or imported.

```
# a.zap: def helper() -> int64: return 1
# b.zap: import a   -> type error / no such module; and `zap run b.zap` can't see a.zap
```

**Impact:** D-0011 §8's shape (an `aws-core` package + per-service
`aws-s3`/`aws-dynamodb` packages depending on it) is not expressible. The whole
SDK has to compile as one file.

**Status:** zaplang-io/zap#283 landed (Stage A intra-project + Stage B package
imports). `import aws.core` and qualified `core.foo(...)` (with keyword args)
work. **Not yet adopted here:** local-module resolution is rooted at the *entry
file's own directory*, so `zap run tests/x.zap` looks for `tests/aws/core.zap`,
not `src/aws/core.zap`. Adopting `import` therefore means either relocating every
runnable entry (tests, examples) beside the `aws/` package, or shipping the core
as a materialized zenv dependency — a repo re-layout that is out of scope for an
ergonomic rewrite of the clients. `zap test` also does not yet resolve local
module imports in discovered test files (it compiles each standalone).

**Workaround:** keep the modules split under `src/aws/` for structure and stitch
them with `tools/bundle.py` (concatenate + de-dup imports) into one file per
runnable program, as before.

**Issue:** zaplang-io/zap#283 (follow-up: adopt `import` + the entry-dir-rooting
/ `zap test` resolution notes above)

## 2. Strings are opaque at run time  — RESOLVED (zaplang-io/zap#284/#285/#335)

*Historical.* This was the single biggest v1 constraint; it is now fully fixed.
The ergonomic rewrite relied on indexing/slicing/case/compare (#284/#285), and
Phase 1 added the last missing piece — per-character **percent-encoding** — via
the `url` module (#335), so SigV4 canonicalization of the URI and query is now
generic (see "Resolved in Phase 1" above). The original write-up is kept for the
record.

At run time a `str` supports only `+`, `len`, and being passed to builtins
(`print`, `crypto`). Everything else is unavailable:

```
s[i]            # codegen: "indexing is only supported on list, dict, and array values"
s[0:3]          # codegen: "this expression is not supported by codegen yet (Phase 1 slice)"
"a" == "b"      # codegen: "unsupported operation on a reference type (only str + str)"
"a" < "b"       # same
for c in s:     # codegen: only range/list/set/user-iterable iteration is supported
char(n) / ord(c) / chr(n) / s + c   # no char<->int, no char literal, no str+char
```

There are also no string methods (`upper`/`lower`/`split`/`strip`/`find`/
`replace`/`join`/`startswith`/…).

**Impact:** generic SigV4 canonicalization is impossible — it requires
per-character **percent-encoding** of the URI/query, **lowercasing** header
names, **trimming/collapsing** header-value whitespace, and **sorting** header
and query lists. None can be implemented.

**Workaround:** the signer operates on pre-normalized inputs only — header names
are written as lowercase string literals in a fixed, hand-sorted order; URIs and
keys must already be URI-safe; values must not need JSON/whitespace
normalization. This is the single biggest constraint on the SDK being "real".
String `==` being unavailable also forced a `has_session: bool` field on
`Credentials` (cannot test `session_token == ""`).

**Issue:** zaplang-io/zap#284 (superset of zaplang-io/zap#278 `str==`, zaplang-io/zap#282 string<->int, zaplang-io/zap#281 dict get)

## 3. No `int → str` (and f-strings don't codegen)  — RESOLVED (zaplang-io/zap#285)

*Historical.* `str(int)`, `float(s)`, `bool(x)`, `format()` and f-string codegen
all landed; `Content-Length` is now computed in-SDK. Original write-up kept.

```
str(42)             # error[ZAP3003]: call to unknown function 'str'
f"len={n}"          # codegen: "f-strings are not supported by codegen yet"
```

There is no way to turn an integer into its decimal string. `http.url(host,
port, path)` exists in the stdlib specifically because of this.

**Impact:** `Content-Length`, numeric query parameters, retry/backoff display,
and DynamoDB `N` attribute values cannot be rendered from computed integers.

**Workaround:** numeric wire values are threaded through the API as
caller-supplied strings (e.g. `content_length: str`), with the body length
hard-coded in examples. Ugly and error-prone, but honest.

**Issue:** zaplang-io/zap#285 (and zaplang-io/zap#282 for the string<->int API)

## 4. `datetime` cannot produce a SigV4 timestamp  — RESOLVED (zaplang-io/zap#286/#338)

*Historical.* v1's `datetime.format(now())` returned ISO-8601 only
(`2026-10-28T05:46:21`, no `Z`), and (per #2) the string could not be reshaped,
so the SDK could not stamp the current time into a request and read `X-Amz-Date`
/ the scope date from env vars the caller set with `date -u`.

**Resolved:** `datetime.strftime` (#286) + `strptime` (#338) land the full
directive set. `aws.core.signing_time_now()` is
`strftime(now(), "%Y%m%dT%H%M%SZ")` / `"%Y%m%d"`, and `sign_request_now` signs a
live request with no caller-supplied timestamp. The `ZAP_AWS_*` date env vars
are gone from the examples.

**Issue:** zaplang-io/zap#286, zaplang-io/zap#338

## 5. HTTP client request/response headers  — PARTIALLY RESOLVED (zaplang-io/zap#280/#279)

v1's `http.get/post/request` took no headers argument, so the signed AWS headers
(`Authorization`, `X-Amz-*`, `Content-Type`, ...) could not be set on the way
out, forcing a hand-built HTTP/1.1 request over raw `tls`.

**Resolved (the blocker):** outbound request headers (#280) and response-header
access (#279) have landed, so the stdlib `http` client is no longer a hard
blocker for authenticated APIs.

**Still hand-built, by choice:** `aws.core` keeps its own `tls`-based transport
(`send_https` + `parse_response`). SigV4 signs an exact byte sequence, and the
transport controls connection framing (`Connection: close`, read-to-EOF) and
returns a parsed `Response { status, headers, body }` that error dispatch and
retry classification ride on. Migrating to the `http` client is a candidate
follow-up once it exposes equivalent control; the `tls` path is not a workaround
for a missing feature any more.

**Issue:** zaplang-io/zap#280, zaplang-io/zap#279 (both landed)

## Minor papercuts

- **`scope` is a reserved keyword** (structured concurrency), so it can't name a
  SigV4 `credential_scope` variable — a surprising collision for AWS code.
  Renamed to `cred_scope`. (No issue filed; noting for awareness.)
- **No `bytes → hex` builtin — RESOLVED** (zaplang-io/zap#337 adds a `bytes` type
  plus `hex`/`base64` modules). Not needed by the SigV4 core (its hex outputs
  come from the hex-returning `crypto` functions), but now available for binary
  payloads (DynamoDB `B` attributes, etc.).

## Net

The cryptographic core (the hard part people worry about) was easy and correct
in Zap from day one. The friction was entirely in **string/number/time
ergonomics and the HTTP surface**: percent-encoding, case/sort, `int→str`, date
formatting, short-circuit evaluation, and outbound headers. Phase 0 landed all
of them (#284/#285/#335/#336/#337/#286/#338/#367/#280/#279), and Phase 1
(aws-core, #340) rebuilt the signer as the genuine SigV4 algorithm on top — no
pre-normalized inputs, no caller-supplied timestamps. The remaining gate to a
*generated* SDK is module imports (#1 / #339, the repo still stitches with
`tools/bundle.py`) and the botocore-model code generator (D-0011 §1), not the
runtime.
