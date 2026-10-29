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

### New friction found during this rewrite

- **`and` / `or` do NOT short-circuit.** Both operands are always evaluated, so
  a bounds check cannot guard an index in the same expression
  (`while j >= 0 and key < out[j]` faults with `index -1` when `j < 0`). The
  insertion sort in `aws.core.sorted_strings` is written around this. This is a
  surprising, easy-to-miss correctness trap; worth a language decision.
- **No keyword-only marker.** A bare `*` separator in a parameter list
  (`def f(a, *, b=1)`) does not parse; optional params are just trailing
  defaulted positionals. Put all optional/keyword params last.
- **`list` has no `.sort()`** (only `append` + index + `len` + iterate), hence
  the hand-rolled sort for canonical ordering.
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

## 2. Strings are opaque at run time  — RESOLVED (zaplang-io/zap#284/#285)

*Historical.* This was the single biggest v1 constraint; it is now fixed and
this rewrite relies on the full string surface (see "Resolved since v1" above).
The original write-up is kept for the record.

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

## 4. `datetime` cannot produce a SigV4 timestamp  — blocks "sign now"

`datetime.format(now())` returns ISO-8601 only (`2026-10-28T05:46:21`, no `Z`,
no millis). SigV4 needs the **basic** format `YYYYMMDDTHHMMSSZ` and the scope
date `YYYYMMDD`. There is no `strftime`/custom format, and (per #2) the ISO
string cannot be reshaped (no removing `-`/`:`, no slicing).

**Impact:** the SDK cannot stamp the current time into a request, so it cannot
sign a live request on its own.

**Workaround:** `X-Amz-Date` and the scope date are read from env vars the caller
sets with `date -u +%Y%m%dT%H%M%SZ` / `+%Y%m%d`.

**Issue:** zaplang-io/zap#286

## 5. HTTP client cannot set request headers  — forces raw HTTP over TLS

`http.get(url)` / `http.post(url, body)` / `http.request(method, url, body)` take
no headers argument, and the response accessors only fetch a named header after
the fact. A signed AWS request needs `Authorization`, `X-Amz-Date`,
`X-Amz-Content-Sha256`, `X-Amz-Target`, `Content-Type`, `X-Amz-Security-Token`,
etc. on the way out.

**Impact:** the stdlib `http` client is unusable for any authenticated API.

**Workaround:** build the full HTTP/1.1 request text by hand (request line +
headers + body) and send it over `tls.connect` / `tls.send` / `tls.recv`
(`core.send_https`). Response parsing (splitting status/headers/body) then also
needs the string ops from #2, so v1 returns the raw response text.

**Issue:** zaplang-io/zap#280 (already open)

## Minor papercuts

- **`scope` is a reserved keyword** (structured concurrency), so it can't name a
  SigV4 `credential_scope` variable — a surprising collision for AWS code.
  Renamed to `cred_scope`. (No issue filed; noting for awareness.)
- **No `bytes → hex` builtin** (already noted in the `crypto_hmac_raw` golden).
  Not blocking here — SigV4's hex outputs come from the hex-returning `crypto`
  functions — but a `bytes`-handling SDK (e.g. binary DynamoDB `B` attributes)
  will want it.

## Net

The cryptographic core (the hard part people worry about) was easy and correct
in Zap. The friction is entirely in **string/number ergonomics and the HTTP
client**: percent-encoding, case/sort, `int→str`, date formatting, and outbound
headers. Those five are the gate between this thin vertical and a usable SDK, and
they also block the botocore-model code generator (which emits exactly this kind
of string/number/ header manipulation per operation). Prioritizing the string
stdlib (#2/#3) would unblock the most.
