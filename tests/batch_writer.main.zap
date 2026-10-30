# Offline test for the buffered BatchWriteItem writer (ticket #435, epic #432).
# Exercises aws.batch_writer end to end with NO live AWS: the generated-client
# `BatchWriteItem` operation is injected as a canned `fn(list[WriteRequest]) ->
# list[WriteRequest]` seam (the "submit these, hand back the unprocessed" shape,
# mirroring the `fn() -> Response` seam the retry/middleware tests use), so
# batching, the UnprocessedItems retry, dedup, and context-exit flushing are all
# asserted deterministically. The expected output is pinned in
# tests/expected/batch_writer.expected and diffed by tools/run-tests.sh.
#
# What each block proves:
#   flush-sizes   : a 60-item write flushes as 25 + 25 + 10 (auto-flush at the
#                   25-item limit twice, then the context exit flushes the
#                   remainder) — three BatchWriteItem calls.
#   unprocessed   : when a response reports UnprocessedItems, the writer
#                   resubmits EXACTLY those items (shown by the second call's
#                   body) and then succeeds — two calls for one logical batch.
#   exit-flush    : a sub-limit buffer is flushed once on context exit.
#   dedup         : overwrite_by_pkeys drops the earlier buffered write for a key,
#                   so only the latest survives (and its value wins).
#   wire-body     : a put+delete batch serialises to the BatchWriteItem body via
#                   #434 marshal — the integration seam, as plain text.

import aws_core.batch_writer
import aws_core.marshal
import aws_core.retry

# --- a canned BatchWriteItem client (the injected seam) ----------------------

# Records every batch it is handed (size + wire body) and, per call, leaves the
# LAST `leave[call]` requests "unprocessed" so the writer's resubmit path is
# driven deterministically. `cursor` is a single-element list so the call index
# persists across the captured-reference calls (the shared-ref shape the writer's
# own counters use).
struct Fake:
    str table
    list[int64] sizes
    list[str] bodies
    list[int64] leave
    list[int64] cursor

def new_fake(str table, list[int64] leave) -> Fake:
    list[int64] sizes = []
    list[str] bodies = []
    return Fake(table=table, sizes=sizes, bodies=bodies, leave=leave, cursor=[0])

# The BatchWriteItem seam: record the batch, then return the scripted
# unprocessed subset (the last `leave[call]` requests; empty once the script runs
# out, so a batch always eventually clears).
def fake_submit(
    Fake fc,
    list[batch_writer.WriteRequest] batch,
) -> list[batch_writer.WriteRequest]:
    fc.sizes.append(len(batch))
    fc.bodies.append(batch_writer.batch_write_item_body(fc.table, batch))
    auto i = fc.cursor[0]
    fc.cursor[0] = i + 1
    auto n = 0
    if i < len(fc.leave):
        n = fc.leave[i]
    list[batch_writer.WriteRequest] un = []
    auto start = len(batch) - n
    auto k = start
    while k < len(batch):
        un.append(batch[k])
        k = k + 1
    return un

# --- native item helpers -----------------------------------------------------

# A one-attribute key item `{"id": S(id)}`.
def item_id(str id) -> marshal.Value:
    list[str] ks = ["id"]
    list[marshal.Value] vs = [marshal.s(id)]
    return marshal.m(ks, vs)

# A two-attribute item `{"id": S(id), "name": S(name)}`.
def item_named(str id, str name) -> marshal.Value:
    list[str] ks = ["id", "name"]
    list[marshal.Value] vs = [marshal.s(id), marshal.s(name)]
    return marshal.m(ks, vs)

# An item with a numeric attribute `{"age": N(age), "id": S(id)}`.
def item_aged(str id, str age) -> marshal.Value:
    list[str] ks = ["age", "id"]
    list[marshal.Value] vs = [marshal.n_str(age), marshal.s(id)]
    return marshal.m(ks, vs)

def join_ints(list[int64] xs) -> str:
    auto out = ""
    auto first = True
    for x in xs:
        if first:
            out = out + str(x)
            first = False
        else:
            out = out + "," + str(x)
    return out

# A zero-backoff config: the UnprocessedItems retry neither sleeps nor touches
# the RNG, so the resubmit path is exercised deterministically.
def fast_cfg() -> retry.RetryConfig:
    return retry.RetryConfig(
        max_attempts=1,
        base_delay=0.0,
        max_backoff=0.0,
        retry_cost=5,
        timeout_retry_cost=10,
        no_retry_refill=1,
    )

def main():
    list[int64] noleave = []
    list[str] no_pkeys = []
    auto cfg = fast_cfg()

    # (a) 60 items -> 25 + 25 + 10 across three BatchWriteItem calls.
    print("== flush-sizes ==")
    auto fc1 = new_fake("T", noleave)
    fn(list[batch_writer.WriteRequest]) -> list[batch_writer.WriteRequest] s1 = lambda batch: fake_submit(fc1, batch)
    auto w1 = batch_writer.batch_writer_with("T", s1, cfg, 10, no_pkeys)
    with w1 as w:
        for i in range(0, 60):
            w.put_item(item_id("k" + str(i)))
    print("sizes " + join_ints(fc1.sizes))
    print("calls " + str(batch_writer.submit_count(w1)))
    print("buffered " + str(batch_writer.buffered(w1)))

    # (b) UnprocessedItems: first call leaves the last 2 of 3 unprocessed, the
    # resubmit clears them. The second body must carry EXACTLY those 2 (b, c).
    print("== unprocessed ==")
    list[int64] leave2 = [2, 0]
    auto fc2 = new_fake("T", leave2)
    fn(list[batch_writer.WriteRequest]) -> list[batch_writer.WriteRequest] s2 = lambda batch: fake_submit(fc2, batch)
    auto w2 = batch_writer.batch_writer_with("T", s2, cfg, 10, no_pkeys)
    with w2 as w:
        w.put_item(item_id("a"))
        w.put_item(item_id("b"))
        w.put_item(item_id("c"))
    print("sizes " + join_ints(fc2.sizes))
    print("calls " + str(batch_writer.submit_count(w2)))
    print("call0 " + fc2.bodies[0])
    print("call1 " + fc2.bodies[1])

    # (c) sub-limit buffer flushed once on context exit.
    print("== exit-flush ==")
    auto fc3 = new_fake("T", noleave)
    fn(list[batch_writer.WriteRequest]) -> list[batch_writer.WriteRequest] s3 = lambda batch: fake_submit(fc3, batch)
    auto w3 = batch_writer.batch_writer_with("T", s3, cfg, 10, no_pkeys)
    with w3 as w:
        w.put_item(item_id("x"))
        w.delete_item(item_id("y"))
        print("mid-buffered " + str(batch_writer.buffered(w3)))
    print("sizes " + join_ints(fc3.sizes))
    print("calls " + str(batch_writer.submit_count(w3)))

    # (d) dedup by primary key: the second write for id=dup overwrites the first,
    # so only [dup(latest), other] survive — and dup's name is the latest one.
    print("== dedup ==")
    list[str] pk = ["id"]
    auto fc4 = new_fake("Users", noleave)
    fn(list[batch_writer.WriteRequest]) -> list[batch_writer.WriteRequest] s4 = lambda batch: fake_submit(fc4, batch)
    auto w4 = batch_writer.batch_writer_with("Users", s4, cfg, 10, pk)
    with w4 as w:
        w.put_item(item_named("dup", "first"))
        w.put_item(item_named("other", "keep"))
        w.put_item(item_named("dup", "latest"))
        print("dedup-buffered " + str(batch_writer.buffered(w4)))
    print("body " + fc4.bodies[0])

    # (e) wire body: a put+delete batch -> BatchWriteItem body via #434 marshal.
    print("== wire-body ==")
    list[batch_writer.WriteRequest] mix = [
        batch_writer.put_request(item_aged("a", "30")),
        batch_writer.delete_request(item_id("b")),
    ]
    print("BODY " + batch_writer.batch_write_item_body("Users", mix))
