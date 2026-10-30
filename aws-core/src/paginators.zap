# aws.paginators — generic lazy page iterator for the Zap AWS SDK.
#
# The Zap equivalent of boto3's `client.get_paginator('op').paginate(...)`: a lazy
# iterator that walks every page of a paginated operation with no manual
# `NextToken` threading at the call site. This module is the protocol-agnostic
# ENGINE: the config shape mirrors botocore's `paginators-1.json` model and the
# loop threads the continuation token across successive calls. Per-op config
# TABLES (one `PaginatorConfig` per `paginators-1.json` entry) are supplied by the
# CALLER, or emitted by aws-codegen — a FOLLOW-UP (see DECISIONS.md D-0011),
# exactly as the waiter tables are for aws.waiters (D-0004). The real AWS config
# wired into tests/paginators.main.zap stands in for that generated output.
#
# It is bundled AFTER aws.core (the same import contract aws.retry / aws.waiters
# use), so every type it leans on — `Response`, `next_page_json` — is already in
# scope. The engine is exposed as a GENERATOR METHOD (`yield`), which is why
# generators-as-methods (zaplang-io/zap#429) is the prerequisite: `pages(self)` and
# `items(self)` lower to the iterator state machine with `self` captured into the
# frame, the exact shape the generated clients' per-op paginators emit.
#
# ## The botocore paginator model (what `paginators-1.json` encodes)
# Each paginated op is `{input_token, output_token, result_key, limit_key?,
# more_results?}`:
#   * `input_token`  — the INPUT field the continuation token is written to for
#                      the next request (e.g. "ExclusiveStartTableName",
#                      "NextToken"). Applied by the fetch closure, not the engine.
#   * `output_token` — the RESPONSE field the next token is read from (e.g.
#                      "LastEvaluatedTableName", "NextToken"). Read by the engine.
#   * `result_key`   — the RESPONSE field holding the page's result list (e.g.
#                      "TableNames", "Contents"), for item-level iteration.
#   * `limit_key`    — the INPUT field for page size (e.g. "Limit", "MaxResults").
#                      Applied by the fetch closure (boto3's PaginationConfig
#                      PageSize), not threaded by the engine.
#   * `more_results` — an optional RESPONSE boolean that gates continuation (e.g.
#                      S3 "IsTruncated"). "" means unused: the token alone decides.
# botocore stops when `output_token` is absent/empty; `more_results`, when modeled,
# is an additional gate (continue only while it is also true).
#
# ## The fetch seam (mirrors aws.retry / aws.waiters)
# The loop is driven by a caller-supplied `fn(str) -> core.Response`: given the
# continuation token ("" for the first page), the closure writes it into the
# `input_token` field (and applies `limit_key`), calls the generated operation,
# and returns its `Response`. This keeps the engine independent of any one
# service's request builders — which operation to call and how to sign it is the
# closure's job, just as `operation` is deliberately unmodeled in aws.waiters.
# Callers that do not paginate never touch this module.

import core
import json

# ---------------------------------------------------------------------------
# Config data shape (mirrors paginators-1.json)
# ---------------------------------------------------------------------------

# One operation's pagination config. `output_token` / `result_key` / `more_results`
# are what the ENGINE reads from each response; `input_token` / `limit_key` are
# what the fetch CLOSURE applies to each request (carried here so a generated per-op
# shim can construct the whole model from `paginators-1.json` in one place).
struct PaginatorConfig:
    str input_token
    str output_token
    str result_key
    str limit_key
    str more_results

# Config constructor for the common case (string token, no page-size / more-results
# gate) — the qualification gate the aws-codegen paginators already use: a single
# string `input_token`/`output_token` and a `result_key`. `limit_key` /
# `more_results` default to "" (unused).
def paginator_config(
    str input_token,
    str output_token,
    str result_key,
) -> PaginatorConfig:
    return PaginatorConfig(
        input_token=input_token,
        output_token=output_token,
        result_key=result_key,
        limit_key="",
        more_results="",
    )

# ---------------------------------------------------------------------------
# JSON reads over a page body
# ---------------------------------------------------------------------------
#
# `output_token` is read with aws.core's `next_page_json` (the awsJson token hook).
# `result_key` and `more_results` are read here over a `json.loads` DOM — the same
# `JsonValue` prelude enum aws.waiters walks — so item iteration and the
# more-results gate stay independent of the wire codec.

# The named child of `v` as an Optional (None if `v` is not an object or lacks the
# field).
def field_of(JsonValue v, str name) -> Optional[JsonValue]:
    match v:
        case JsonValue.Object(fields):
            return fields.get(name)
        case _:
            return Optional.None

# Follow a dotted `path` ("Contents", "Foo.Bar") from `root`, returning the node it
# lands on (or None if any segment is missing). Paginator `result_key`s are simple
# dotted field access; no projections (unlike waiter JMESPath).
def dig(JsonValue root, str path) -> Optional[JsonValue]:
    auto cur = root
    for seg in path.split("."):
        Optional[JsonValue] nxt = field_of(cur, seg)
        if not nxt.is_some():
            return Optional.None
        cur = nxt.unwrap()
    return Optional.Some(cur)

# The elements of the `result_key` array in `body`, or [] when the key is empty,
# absent, or not an array (e.g. a final page that omits the list). Empty-array
# pages yield no items, which is what a trailing empty page should do.
def result_items(str result_key, str body) -> list[JsonValue]:
    list[JsonValue] out = []
    if len(result_key) == 0:
        return out
    Optional[JsonValue] node = dig(json.loads(body), result_key)
    if not node.is_some():
        return out
    match node.unwrap():
        case JsonValue.Array(items):
            out = items
        case _:
            out = out
    return out

# Whether the `more_results` boolean in `body` is true. Absent / non-boolean reads
# as false (stop) — botocore treats a missing more-results key as "no more".
def more_results_true(str more_results, str body) -> bool:
    Optional[JsonValue] node = dig(json.loads(body), more_results)
    if not node.is_some():
        return False
    match node.unwrap():
        case JsonValue.Bool(b):
            return b
        case _:
            return False

# Whether to make another request after `body`: a non-empty `output_token`, AND —
# when a `more_results` key is modeled — that boolean is also true. Returns the
# next token (empty when the loop should stop).
def next_token(PaginatorConfig cfg, str body) -> str:
    auto np = core.next_page_json(body, cfg.output_token)
    if not np.has_more:
        return ""
    if len(cfg.more_results) > 0 and not more_results_true(cfg.more_results, body):
        return ""
    return np.token

# ---------------------------------------------------------------------------
# The paginator: a config + the fetch closure, iterated as a generator method
# ---------------------------------------------------------------------------

# One step of the walk: the page `Response` plus the continuation token for the
# next call ("" when the walk should stop). Returned by `step` so the generator
# methods carry only plain data across each `yield`, never the fetch closure.
struct PageStep:
    core.Response response
    str next_token

# A ready-to-iterate paginator. `fetch(token)` makes one call ("" token = first
# page) and returns its `Response`; the engine threads `output_token` ->
# `input_token` across calls. Mirrors aws.waiters' `WaiterConfig` + `fn() -> Poll`,
# but the loop is a `yield` iterator rather than a terminal poll.
struct Paginator:
    PaginatorConfig config
    fn(str) -> core.Response fetch

    # One page call + next-token computation. The function-typed field is called
    # here, in a PLAIN method — never from inside a generator frame: a generator
    # that yields across a stored-closure call is an untested lowering, so `pages`
    # / `items` reach the closure only through this sibling-method call (the shape
    # the generated clients' paginators use — call helpers, not frame closures).
    # The field is bound to a `fn(...)`-annotated local before the call, as
    # aws.middleware does (I#163/D-0067).
    def step(self, str token) -> PageStep:
        fn(str) -> core.Response fetch = self.fetch
        auto resp = fetch(token)
        return PageStep(response=resp, next_token=next_token(self.config, resp.body))

    # Yield each page's `Response` in order, threading the continuation token. The
    # first call uses an empty token; each subsequent call carries the previous
    # response's `output_token`. Stops when the token is absent/empty (or a modeled
    # `more_results` gate is false). boto3: `for page in paginator.paginate(...)`.
    def pages(self):
        # Next-token threading and the stop decision happen BEFORE the `yield`, so
        # only `self` and scalar locals (`token`, `more`) are live across the
        # suspend point — the shape the generator-method lowering is exercised with
        # (zaplang-io/zap#429). `st` is dead after the yield expression.
        auto token = ""
        auto more = True
        while more:
            auto st = self.step(token)
            auto nt = st.next_token
            if len(nt) > 0:
                token = nt
            else:
                more = False
            yield st.response

    # Yield each element of `result_key` across every page, lazily (boto3's
    # item-level iteration / `.search(result_key)`). The page loop is inlined
    # rather than iterating `self.pages()` so this is a single flat generator; the
    # stop decision is made before the inner yield loop (as in `pages`).
    def items(self):
        auto token = ""
        auto more = True
        while more:
            auto st = self.step(token)
            auto nt = st.next_token
            auto page_items = result_items(self.config.result_key, st.response.body)
            if len(nt) > 0:
                token = nt
            else:
                more = False
            for it in page_items:
                yield it

# Construct a `Paginator` from a config and a fetch closure. The boto3
# `client.get_paginator('op')` analogue: `paginator(cfg, fetch).pages()` is
# `.paginate(...)`.
def paginator(PaginatorConfig cfg, fn(str) -> core.Response fetch) -> Paginator:
    return Paginator(config=cfg, fetch=fetch)

# ---------------------------------------------------------------------------
# Eager accumulators (boto3 `build_full_result` territory)
# ---------------------------------------------------------------------------

# Collect every page `Response` into a list (drains the iterator). Convenient for
# callers that want all pages up front rather than streaming.
def all_pages(Paginator p) -> list[core.Response]:
    list[core.Response] out = []
    for page in p.pages():
        out.append(page)
    return out

# Collect every `result_key` item across all pages into one list — the merged
# result list boto3's `build_full_result` produces for the common single-result-key
# paginator. (Merging the other output fields into one synthetic response is a
# follow-up; see DECISIONS.md D-0011.)
def all_items(Paginator p) -> list[JsonValue]:
    list[JsonValue] out = []
    for it in p.items():
        out.append(it)
    return out
