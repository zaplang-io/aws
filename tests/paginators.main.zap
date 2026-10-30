# Offline paginator test — exercises aws.paginators (the generic lazy page
# iterator) deterministically and pins the output in
# tests/expected/paginators.expected. No live AWS calls: the loop is driven by an
# injected fake client returning canned multi-page responses through the same
# `fn(str) -> Response` fetch seam the live client uses, so token threading and
# termination are asserted without a network (mirrors tests/waiters.main.zap and
# tests/retry.main.zap).
#
# The fixtures are REAL paginator configs: DynamoDB ListTables (string token
# ExclusiveStartTableName <- LastEvaluatedTableName, result_key TableNames — the
# concrete checked-in case the aws-codegen paginators already emit) and S3
# ListObjectsV2 (NextContinuationToken + an IsTruncated `more_results` gate). They
# stand in for the per-op config aws-codegen will emit from `paginators-1.json`
# (DECISIONS.md D-0011 follow-up).
#
# Run: tools/run-tests.sh (via `zap run`) with the aws_core zenv active.

import aws_core.core
import aws_core.paginators

# --- injected transport: a fake client over a scripted body sequence --------

# A canned response sequence with a mutable cursor and a record of the tokens the
# engine threaded in (single-element-list cursor so position persists across calls
# through the captured reference — the shape waiters.main.zap's Script uses).
# `seen` records each token the engine passed, so the test can assert threading.
struct Fake:
    list[str] bodies
    list[str] seen
    list[int64] cursor

def new_fake(list[str] bodies) -> Fake:
    return Fake(bodies=bodies, seen=[], cursor=[0])

# One operation call: record the incoming continuation token, return the next
# canned body as a 200 Response. Clamps to the last body if asked for more.
def fake_call(Fake f, str token) -> core.Response:
    f.seen.append(token)
    auto i = f.cursor[0]
    f.cursor[0] = i + 1
    auto b = f.bodies[len(f.bodies) - 1]
    if i < len(f.bodies):
        b = f.bodies[i]
    return core.Response(status=200, headers={}, body=b)

# Build a paginator over a fresh fake client for `bodies`. Returned with the fake
# so the test can read back the threaded tokens. A fresh fake per paginator keeps
# each iteration independent (the cursor is stateful).
def over(
    paginators.PaginatorConfig cfg,
    list[str] bodies,
) -> (paginators.Paginator, Fake):
    auto f = new_fake(bodies)
    fn(str) -> core.Response fetch = lambda tok: fake_call(f, tok)
    return (paginators.paginator(cfg, fetch), f)

# --- real paginator configs -------------------------------------------------

# dynamodb/.../paginators-1.json "ListTables": token ExclusiveStartTableName <-
# LastEvaluatedTableName, result_key TableNames. No more_results gate.
def ddb_list_tables() -> paginators.PaginatorConfig:
    return paginators.paginator_config(
        "ExclusiveStartTableName",
        "LastEvaluatedTableName",
        "TableNames",
    )

# s3/.../paginators-1.json "ListObjectsV2": token NextContinuationToken, result_key
# Contents, more_results IsTruncated — a page can carry a token yet set
# IsTruncated=false, which must stop the walk (the gate overrides the token).
def s3_list_objects() -> paginators.PaginatorConfig:
    return paginators.PaginatorConfig(
        input_token="ContinuationToken",
        output_token="NextContinuationToken",
        result_key="Contents",
        limit_key="MaxKeys",
        more_results="IsTruncated",
    )

# --- print helpers ----------------------------------------------------------

# Render a scalar JsonValue item as a string for the pinned output.
def show_item(JsonValue v) -> str:
    match v:
        case JsonValue.Str(s):
            return s
        case JsonValue.Int(i):
            return str(i)
        case _:
            return "?"

# The threaded tokens as a comma list, empty token shown as "-".
def show_tokens(Fake f) -> str:
    list[str] parts = []
    for t in f.seen:
        if len(t) == 0:
            parts.append("-")
        else:
            parts.append(t)
    return ",".join(parts)

# Join yielded items by space.
def show_items(list[JsonValue] items) -> str:
    list[str] parts = []
    for it in items:
        parts.append(show_item(it))
    return " ".join(parts)

def main():
    # --- multi-page: page 1 carries a token, page 2 does not ---------------
    print("== multi-page ==")
    auto mp = over(
        ddb_list_tables(),
        [
            "{\"TableNames\": [\"a\", \"b\"], \"LastEvaluatedTableName\": \"b\"}",
            "{\"TableNames\": [\"c\"]}",
        ],
    )
    auto mpp = mp[0]
    auto mpf = mp[1]
    auto npages = 0
    for page in mpp.pages():
        npages = npages + 1
    print("pages " + str(npages))
    print("tokens " + show_tokens(mpf))

    # Item-level iteration over the same config (fresh fake).
    auto mi = over(
        ddb_list_tables(),
        [
            "{\"TableNames\": [\"a\", \"b\"], \"LastEvaluatedTableName\": \"b\"}",
            "{\"TableNames\": [\"c\"]}",
        ],
    )
    list[JsonValue] mitems = []
    for it in mi[0].items():
        mitems.append(it)
    print("items " + show_items(mitems))

    # --- single-page: no token, one call -----------------------------------
    print("== single-page ==")
    auto sp = over(ddb_list_tables(), ["{\"TableNames\": [\"x\", \"y\"]}"])
    auto sppages = 0
    for page in sp[0].pages():
        sppages = sppages + 1
    print("pages " + str(sppages))
    print("tokens " + show_tokens(sp[1]))

    # --- more_results gate: token present but IsTruncated=false stops ------
    print("== more-results gate ==")
    auto mr = over(
        s3_list_objects(),
        [
            "{\"Contents\": [\"k1\"], \"IsTruncated\": true, \"NextContinuationToken\": \"t1\"}",
            "{\"Contents\": [\"k2\"], \"IsTruncated\": false, \"NextContinuationToken\": \"t2\"}",
        ],
    )
    auto mrpages = 0
    for page in mr[0].pages():
        mrpages = mrpages + 1
    print("pages " + str(mrpages))
    print("tokens " + show_tokens(mr[1]))

    # --- eager accumulators (build_full_result territory) -------------------
    print("== accumulators ==")
    auto ap = over(
        ddb_list_tables(),
        [
            "{\"TableNames\": [\"a\", \"b\"], \"LastEvaluatedTableName\": \"b\"}",
            "{\"TableNames\": [\"c\"]}",
        ],
    )
    print("all_pages " + str(len(paginators.all_pages(ap[0]))))
    auto ai = over(
        ddb_list_tables(),
        [
            "{\"TableNames\": [\"a\", \"b\"], \"LastEvaluatedTableName\": \"b\"}",
            "{\"TableNames\": [\"c\"]}",
        ],
    )
    print("all_items " + show_items(paginators.all_items(ai[0])))
