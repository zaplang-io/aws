# aws.batch_writer — a buffered DynamoDB BatchWriteItem writer (ergonomics epic
# #432, ticket #435).
#
# The Zap counterpart of boto3's `Table.batch_writer()`: a context-manager-style
# helper that buffers `put_item` / `delete_item` requests and flushes them to the
# generated DynamoDB client's `BatchWriteItem` operation in batches, so a caller
# can stream thousands of writes without hand-rolling the 25-item batching, the
# `RequestItems` body, or the UnprocessedItems retry loop:
#
#     with batch_writer("Users", submit) as w:
#         w.put_item(marshal.m(["id", "name"], [marshal.s("a"), marshal.s("Al")]))
#         w.delete_item(marshal.m(["id"], [marshal.s("b")]))
#     # context exit flushes whatever is left in the buffer
#
# WHY HAND-WRITTEN (D-0001, generated-is-product): the generated per-service
# clients are the shipping SDK, but boto3's resource-layer conveniences are not
# derivable from botocore models. This is the third hand-written ergonomics
# module, after `conditions` (#433) and `marshal` (#434); it composes both — it
# drives the generated `BatchWriteItem` and uses #434 `marshal` to turn native
# item maps into the AttributeValue wire shape.
#
# ## How it hooks the generated client (the submit seam)
# `BatchWriteItem` for a single table takes `RequestItems[table] = [writeRequest,
# ...]` and returns `UnprocessedItems[table] = [...]` — the subset the service
# did not accept (throttling / capacity), which the caller must resubmit. The
# writer is parameterised over that operation as a typed seam:
#
#     fn(list[WriteRequest]) -> list[WriteRequest]
#
# i.e. "submit these write requests for my table, hand back the ones still
# unprocessed." The live adapter builds the wire body with `batch_write_item_body`
# (which serialises each item through #434 `marshal.serialize`), calls the
# generated DynamoDB client's `BatchWriteItem`, and parses `UnprocessedItems` back
# into `WriteRequest`s; the offline test injects a canned responder through the
# same seam (mirroring the `fn() -> Response` seam in `retry` / `middleware`), so
# batching, the UnprocessedItems retry, and context-exit flushing are all proven
# without a network.
#
# ## Retrying UnprocessedItems (exponential backoff, bounded)
# A 200 response can still report UnprocessedItems. On a non-empty unprocessed
# set the writer resubmits EXACTLY those requests, waiting the `retry` module's
# full-jitter backoff (`retry.backoff_delay`, so the formula and its deterministic
# `retry.seed_jitter` seeding are shared with the HTTP retry path) between tries,
# up to `max_retries` times. boto3's writer loops unbounded; #435 asks for a
# bound, so exhaustion raises rather than silently dropping writes.
#
# ## Dedup by primary key (boto3 `overwrite_by_pkeys`)
# When constructed with a non-empty `pkeys` list, adding a request first drops any
# already-buffered request with the same primary-key values, so only the latest
# write for a key is sent within a buffer — exactly boto3's `overwrite_by_pkeys`.
# With no `pkeys` (the default) every request is buffered as-is.

import marshal
import retry
import time

# The BatchWriteItem hard limit: at most 25 write requests per call.
def batch_limit() -> int64:
    return 25

# --- WriteRequest: one buffered put or delete --------------------------------

# One buffered write. `kind` 0 = PutRequest(Item=item), 1 = DeleteRequest(Key=
# item). `item` is a `marshal.Value.M` — the DynamoDB item (put) or primary key
# (delete) as a NATIVE map, carried as a `marshal.Value` rather than pre-rendered
# wire JSON so the dedup logic can read its key attributes and #434 serialises it
# at flush time.
struct WriteRequest:
    int64 kind
    marshal.Value item

# A PutRequest for a native item map (`marshal.m([...], [...])`).
def put_request(marshal.Value item) -> WriteRequest:
    return WriteRequest(kind=0, item=item)

# A DeleteRequest for a native primary-key map (`marshal.m([...], [...])`).
def delete_request(marshal.Value key) -> WriteRequest:
    return WriteRequest(kind=1, item=key)

# --- wire glue: WriteRequests -> BatchWriteItem body (the #434 integration) --

# The AttributeValue map body of a native item: `{"name":<AV>,...}`, each value
# rendered through #434 `marshal.serialize`. This is the inner object the wire
# forms (`PutRequest.Item` / `DeleteRequest.Key`) carry — the item map WITHOUT the
# `{"M":...}` wrapper a bare `serialize` would add. A non-map value renders `{}`
# (callers pass maps). No JSON string escaping on this hand path, matching
# `marshal` / `dynamodb` / `conditions`.
def _item_body(marshal.Value item) -> str:
    match item:
        case marshal.Value.M(keys, vals):
            auto out = "{"
            auto i = 0
            while i < len(keys):
                if i > 0:
                    out = out + ","
                out = out + "\"" + keys[i] + "\":" + marshal.serialize(vals[i])
                i = i + 1
            return out + "}"
        case _:
            return "{}"

# One write request as its `RequestItems` element JSON:
#   put    -> {"PutRequest":{"Item":{<AV map>}}}
#   delete -> {"DeleteRequest":{"Key":{<AV map>}}}
def request_element(WriteRequest r) -> str:
    if r.kind == 0:
        return "{\"PutRequest\":{\"Item\":" + _item_body(r.item) + "}}"
    return "{\"DeleteRequest\":{\"Key\":" + _item_body(r.item) + "}}"

# The full BatchWriteItem request body for one table:
#   {"RequestItems":{"<table>":[<element>,<element>,...]}}
# This is exactly what the live adapter hands the generated DynamoDB client's
# BatchWriteItem (via the awsJson codec). Exposed so the integration is testable
# as plain text.
def batch_write_item_body(str table, list[WriteRequest] reqs) -> str:
    auto out = "{\"RequestItems\":{\"" + table + "\":["
    auto i = 0
    while i < len(reqs):
        if i > 0:
            out = out + ","
        out = out + request_element(reqs[i])
        i = i + 1
    return out + "]}}"

# --- dedup signature ---------------------------------------------------------

# The primary-key signature of an item: the serialised values of the `pkeys`
# attributes, in `pkeys` order (`pk=<AV>;...`). Two requests with the same
# signature target the same DynamoDB item, so the dedup drops the earlier one. A
# non-map item or a missing key attribute contributes nothing.
def _pkey_sig(list[str] pkeys, marshal.Value item) -> str:
    match item:
        case marshal.Value.M(keys, vals):
            auto sig = ""
            for pk in pkeys:
                auto k = 0
                while k < len(keys):
                    if keys[k] == pk:
                        sig = sig + pk + "=" + marshal.serialize(vals[k]) + ";"
                    k = k + 1
            return sig
        case _:
            return ""

# --- backoff config ----------------------------------------------------------

# The default UnprocessedItems backoff: full-jitter around a 50ms base capped at
# 1s. Reuses `retry.RetryConfig` purely for the backoff shape (`base_delay` /
# `max_backoff`); the bound on tries is the writer's own `max_retries`, so the
# config's `max_attempts` is unused here.
def _default_backoff() -> retry.RetryConfig:
    return retry.RetryConfig(
        max_attempts=1,
        base_delay=0.05,
        max_backoff=1.0,
        retry_cost=5,
        timeout_retry_cost=10,
        no_retry_refill=1,
    )

# --- BatchWriter: the buffered context manager -------------------------------

# A buffered writer bound to one `table`. `submit` is the BatchWriteItem seam;
# `cfg` shapes the UnprocessedItems backoff and `max_retries` bounds it; `pkeys`
# (possibly empty) selects the `overwrite_by_pkeys` dedup; `buf` is the pending
# buffer; `submit_calls` is a single-element list so the BatchWriteItem call count
# is mutable in place and observable (the same shared-reference shape
# `retry.RetryQuota.available` uses).
struct BatchWriter:
    str table
    fn(list[WriteRequest]) -> list[WriteRequest] submit
    retry.RetryConfig cfg
    int64 max_retries
    list[str] pkeys
    list[WriteRequest] buf
    list[int64] submit_calls

    # Context-manager entry: `with batch_writer(...) as w` binds `w` to the
    # writer itself.
    def __enter__(self) -> BatchWriter:
        return self

    # Context-manager exit: flush whatever remains in the buffer. v1 `__exit__`
    # is non-suppressing (D-0069), so a flush that exhausts its retries raises
    # out of the `with`.
    def __exit__(self):
        _flush(self)

    # Buffer a PutRequest for `item` (a native `marshal.m(...)` map); flushes a
    # full 25-item batch as soon as the buffer reaches the limit.
    def put_item(self, marshal.Value item):
        _add(self, put_request(item))

    # Buffer a DeleteRequest for `key` (a native `marshal.m(...)` map); flushes a
    # full 25-item batch as soon as the buffer reaches the limit.
    def delete_item(self, marshal.Value key):
        _add(self, delete_request(key))

# A writer with the default backoff, no retry bound surprises (10 tries), and no
# dedup. `submit` is the BatchWriteItem seam (see the module header).
def batch_writer(
    str table,
    fn(list[WriteRequest]) -> list[WriteRequest] submit,
) -> BatchWriter:
    list[str] no_pkeys = []
    list[WriteRequest] empty = []
    return BatchWriter(
        table=table,
        submit=submit,
        cfg=_default_backoff(),
        max_retries=10,
        pkeys=no_pkeys,
        buf=empty,
        submit_calls=[0],
    )

# A writer with explicit backoff config, retry bound, and dedup keys. Pass an
# empty `pkeys` to disable dedup. Tests use this with a zero-`base_delay` config
# so the backoff neither sleeps nor touches the RNG (deterministic).
def batch_writer_with(
    str table,
    fn(list[WriteRequest]) -> list[WriteRequest] submit,
    retry.RetryConfig cfg,
    int64 max_retries,
    list[str] pkeys,
) -> BatchWriter:
    list[WriteRequest] empty = []
    return BatchWriter(
        table=table,
        submit=submit,
        cfg=cfg,
        max_retries=max_retries,
        pkeys=pkeys,
        buf=empty,
        submit_calls=[0],
    )

# --- buffering + flushing ----------------------------------------------------

# Buffer one request. With dedup on (`pkeys` non-empty), drop any already-buffered
# request with the same primary-key signature first, so only the latest write for
# a key survives in the buffer. Then flush full 25-item batches while the buffer
# is at or over the limit (a single add can only cross it once, but the loop keeps
# the invariant regardless).
def _add(BatchWriter w, WriteRequest r):
    if len(w.pkeys) > 0:
        auto sig = _pkey_sig(w.pkeys, r.item)
        w.buf = [x for x in w.buf if _pkey_sig(w.pkeys, x.item) != sig]
    w.buf.append(r)
    while len(w.buf) >= batch_limit():
        _flush_front(w)

# Take up to `batch_limit()` requests off the front of the buffer and submit them
# (with the UnprocessedItems retry). Leaves the rest buffered.
def _flush_front(BatchWriter w):
    auto take = batch_limit()
    if len(w.buf) < take:
        take = len(w.buf)
    list[WriteRequest] batch = []
    auto i = 0
    while i < take:
        batch.append(w.buf[i])
        i = i + 1
    w.buf = [x for x in w.buf[take:len(w.buf)]]
    _submit_once(w, batch)

# Submit `batch` through the seam, retrying the UnprocessedItems subset with
# bounded full-jitter backoff until it clears. Each seam call bumps
# `submit_calls`. Exhausting `max_retries` with items still unprocessed raises
# (writes are never silently dropped).
def _submit_once(BatchWriter w, list[WriteRequest] batch):
    fn(list[WriteRequest]) -> list[WriteRequest] submit = w.submit
    auto pending = batch
    auto attempt = 0
    while True:
        w.submit_calls[0] = w.submit_calls[0] + 1
        auto unprocessed = submit(pending)
        if len(unprocessed) == 0:
            return
        if attempt >= w.max_retries:
            raise _exhausted_msg(w.table, len(unprocessed), attempt)
        auto delay = retry.backoff_delay(w.cfg, attempt)
        time.sleep(delay)
        pending = unprocessed
        attempt = attempt + 1

def _exhausted_msg(str table, int64 remaining, int64 attempts) -> str:
    return "BatchWriteItem: " + str(remaining) + " unprocessed item(s) for table '" + table + "' did not clear after " + str(attempts) + " retries"

# Flush every buffered request now, one <=25-item batch at a time. Called on
# context exit; also usable directly for a non-`with` caller.
def _flush(BatchWriter w):
    while len(w.buf) > 0:
        _flush_front(w)

# Public explicit flush (the non-`with` path): drain the buffer immediately.
def flush(BatchWriter w):
    _flush(w)

# --- observers (for tests / diagnostics) -------------------------------------

# The number of pending (unflushed) requests in the buffer.
def buffered(BatchWriter w) -> int64:
    return len(w.buf)

# The total number of BatchWriteItem seam calls made so far (initial submits plus
# UnprocessedItems retries).
def submit_count(BatchWriter w) -> int64:
    return w.submit_calls[0]
