# aws.transfer — S3 managed transfer (ergonomics epic #432, ticket #438).
#
# The Zap counterpart of boto3's `boto3.s3.transfer` / `S3Transfer` / the
# `TransferManager`: the high-level `upload_file` / `upload_fileobj` /
# `download_file` / `copy` helpers that hide S3's multipart machinery behind a
# single call, so a caller streams a large object without hand-rolling
# CreateMultipartUpload → UploadPart → CompleteMultipartUpload, the per-part byte
# math, the bounded concurrency, or the abort-on-failure cleanup:
#
#     auto tm = transfer.manager(client)              # boto3 TransferConfig defaults
#     tm.upload_file("my-bucket", "big.bin", "/path/big.bin")
#     tm.download_file("my-bucket", "big.bin", "/tmp/out.bin")
#     tm.copy("dst-bucket", "dst/key", "src-bucket", "src/key", src_size)
#
# WHY HAND-WRITTEN (D-0001, generated-is-product): the generated per-service S3
# client is the shipping SDK and already exposes the raw multipart operations
# (CreateMultipartUpload, UploadPart, …) plus the aws-core streaming/aws-chunked
# signer (#358). The managed-transfer orchestration boto3 layers on top of them is
# a resource-layer convenience, not derivable from the botocore model — so it is
# hand-written here, the S3 sibling of the DynamoDB `batch_writer` (#435). It
# drives the generated client; it does not re-sign or re-send anything itself.
#
# ## How it hooks the generated client (the transfer seam)
# Like `batch_writer`'s single `submit` seam and the `fn() -> Response` seams in
# `retry` / `middleware` / `waiters`, the manager is parameterised over the S3
# operations it orchestrates as a struct of typed function fields
# (`S3TransferClient`). The live adapter binds each field to the matching
# generated-client call — UploadPart over the aws-core streaming path
# (`core.sign_streaming_request`, #358), so a part is signed and sent as an
# aws-chunked stream rather than buffered-then-hashed — and the offline test
# injects canned responders through the same seam, so the part math, the bounded
# waves, the Complete body, and the abort-on-failure path are all proven without
# a network (mirroring `batch_writer`'s `Fake` submit responder).
#
# ## Single-shot vs multipart (the threshold)
# `upload_fileobj` sends a lone `PutObject` when the body is below
# `multipart_threshold` (boto3's default 8 MiB) and switches to multipart at or
# above it, exactly as boto3's `TransferManager` does. `copy` likewise sends a
# single server-side `CopyObject` at or below `copy_threshold` (S3's 5 GiB
# single-copy limit) and a multipart `UploadPartCopy` sequence above it.
#
# ## Part math (boto3's ChunksizeAdjuster)
# Parts are `multipart_chunksize` bytes (the last is the remainder). If that would
# need more than `max_parts` (S3's hard 10 000-part cap) the part size is grown to
# `ceil(total / max_parts)`, then floored at `min_chunksize` (S3's 5 MiB minimum
# part size, the last part excepted) and capped at the 5 GiB per-part limit — the
# same clamps boto3's `ChunksizeAdjuster` applies. `plan_parts` is pure and
# exposed, so the byte boundaries are asserted directly.
#
# ## Bounded concurrency (the wave model)
# boto3 uploads up to `max_concurrency` parts at once. aws-core's engines are all
# synchronous seam-drivers (concurrency is the adapter's/caller's concern, as in
# `retry` / `middleware`), so the bound is modelled structurally: parts are
# dispatched in WAVES of `max_concurrency`, and a live adapter may run one wave's
# seam calls concurrently (the parts in a wave are independent). This reference
# dispatch is deterministic (ascending part order) so the orchestration is
# testable; the Complete call always lists parts in ascending `PartNumber` order
# regardless, as S3 requires.
#
# ## Abort on failure
# If any UploadPart / UploadPartCopy raises, the manager calls
# AbortMultipartUpload for the in-flight upload id before re-raising, so a failed
# transfer never leaks a dangling multipart upload (boto3's behaviour). A plain
# `raise <str>` is used (the aws.errors / batch_writer / waiters convention),
# recovered by a single `except ... as e:`.

import fs

# ---------------------------------------------------------------------------
# Size constants (boto3 s3transfer defaults / S3 hard limits)
# ---------------------------------------------------------------------------

# One mebibyte, the unit boto3's transfer defaults are expressed in.
def mib() -> int64:
    return 1048576

# S3's hard cap on the number of parts in a multipart upload.
def max_upload_parts() -> int64:
    return 10000

# S3's minimum part size (5 MiB); every part but the last must be at least this.
def min_part_size() -> int64:
    return 5 * mib()

# S3's maximum size for a single PutObject / CopyObject and for one part (5 GiB).
def max_single_object() -> int64:
    return 5 * 1024 * mib()

# ---------------------------------------------------------------------------
# TransferConfig — the boto3 TransferConfig knobs
# ---------------------------------------------------------------------------

# Tunables for a managed transfer. Defaults match boto3's `TransferConfig`:
# 8 MiB multipart threshold and part size, 10-way concurrency, the 10 000-part
# cap, a 5 MiB part-size floor, and the 5 GiB single-copy threshold.
struct TransferConfig:
    int64 multipart_threshold
    int64 multipart_chunksize
    int64 min_chunksize
    int64 max_concurrency
    int64 max_parts
    int64 copy_threshold

# The boto3 default configuration.
def transfer_config() -> TransferConfig:
    return TransferConfig(
        multipart_threshold=8 * mib(),
        multipart_chunksize=8 * mib(),
        min_chunksize=min_part_size(),
        max_concurrency=10,
        max_parts=max_upload_parts(),
        copy_threshold=max_single_object(),
    )

# A configuration with explicit knobs (tests set small thresholds / part sizes
# and a small `min_chunksize` so multipart is exercised without 8 MiB bodies).
def transfer_config_with(
    int64 multipart_threshold,
    int64 multipart_chunksize,
    int64 min_chunksize,
    int64 max_concurrency,
    int64 max_parts,
    int64 copy_threshold,
) -> TransferConfig:
    return TransferConfig(
        multipart_threshold=multipart_threshold,
        multipart_chunksize=multipart_chunksize,
        min_chunksize=min_chunksize,
        max_concurrency=max_concurrency,
        max_parts=max_parts,
        copy_threshold=copy_threshold,
    )

# ---------------------------------------------------------------------------
# Part planning (pure; the ChunksizeAdjuster + slicing)
# ---------------------------------------------------------------------------

# One planned part: its 1-based `number`, byte `offset` into the object, and
# `length`. The last part's length is the remainder.
struct PartRange:
    int64 number
    int64 offset
    int64 length

# Ceiling division for positive operands (no float round-trip).
def _ceil_div(int64 n, int64 d) -> int64:
    if d <= 0:
        return 0
    auto q = n // d
    if n % d != 0:
        q = q + 1
    return q

# The effective part size for `total`, mirroring boto3's `ChunksizeAdjuster`:
# grow the configured `multipart_chunksize` to `ceil(total / max_parts)` when it
# would otherwise exceed the part cap, then floor at `min_chunksize` and cap at
# the 5 GiB per-part limit.
def adjusted_chunksize(int64 total, TransferConfig cfg) -> int64:
    auto chunk = cfg.multipart_chunksize
    if _ceil_div(total, chunk) > cfg.max_parts:
        chunk = _ceil_div(total, cfg.max_parts)
    if chunk < cfg.min_chunksize:
        chunk = cfg.min_chunksize
    if chunk > max_single_object():
        chunk = max_single_object()
    return chunk

# Slice `total` bytes into ascending parts of `adjusted_chunksize(total, cfg)`
# (the last part carries the remainder). An empty object yields a single
# zero-length part (S3 still needs one part), matching boto3.
def plan_parts(int64 total, TransferConfig cfg) -> list[PartRange]:
    auto chunk = adjusted_chunksize(total, cfg)
    list[PartRange] out = []
    if total <= 0:
        out.append(PartRange(number=1, offset=0, length=0))
        return out
    auto offset = 0
    auto number = 1
    while offset < total:
        auto length = chunk
        if offset + length > total:
            length = total - offset
        out.append(PartRange(number=number, offset=offset, length=length))
        offset = offset + length
        number = number + 1
    return out

# Group `parts` into dispatch WAVES of at most `max_concurrency` part NUMBERS,
# in ascending order — the structural model of boto3's bounded part concurrency
# (a live adapter may run one wave's UploadParts concurrently; the parts in a wave
# are independent). Pure and exposed so the bound is asserted directly. A
# `max_concurrency` of 0 or less is treated as 1 (sequential).
def plan_waves(list[PartRange] parts, int64 max_concurrency) -> list[list[int64]]:
    auto width = max_concurrency
    if width < 1:
        width = 1
    list[list[int64]] waves = []
    list[int64] cur = []
    for p in parts:
        cur.append(p.number)
        if len(cur) >= width:
            waves.append(cur)
            cur = []
    if len(cur) > 0:
        waves.append(cur)
    return waves

# The HTTP Range header value for a byte window: "bytes=<first>-<last>"
# (inclusive, as RFC 7233 / S3 expect). Exposed so the ranged-GET and
# UploadPartCopy range binding is testable as plain text.
def range_header(int64 offset, int64 length) -> str:
    auto last = offset + length - 1
    if last < offset:
        last = offset
    return "bytes=" + str(offset) + "-" + str(last)

# ---------------------------------------------------------------------------
# CompletedPart + the CompleteMultipartUpload body (the wire integration)
# ---------------------------------------------------------------------------

# A finished part: its `number` and the `etag` S3 returned for it. The Complete
# call lists these in ascending part order.
struct CompletedPart:
    int64 number
    str etag

# The CompleteMultipartUpload request body (rest-xml) for `parts`:
#   <CompleteMultipartUpload><Part><PartNumber>N</PartNumber><ETag>e</ETag>
#   </Part>...</CompleteMultipartUpload>
# This is exactly what the live adapter hands the generated client's
# CompleteMultipartUpload. No XML escaping on this hand path (ETags are quoted
# hex), matching the `restxml` / `batch_writer` hand serializers. Exposed so the
# integration is asserted as plain text.
def complete_mpu_body(list[CompletedPart] parts) -> str:
    auto out = "<CompleteMultipartUpload>"
    for p in parts:
        out = out + "<Part><PartNumber>" + str(p.number) + "</PartNumber><ETag>" + p.etag + "</ETag></Part>"
    return out + "</CompleteMultipartUpload>"

# ---------------------------------------------------------------------------
# The transfer seam (mirrors batch_writer's submit seam)
# ---------------------------------------------------------------------------

# The generated-client operations a managed transfer drives, as typed function
# fields. The live adapter binds each to the matching generated S3 call (UploadPart
# / UploadPartCopy over the aws-core streaming signer, #358); the offline test
# binds canned responders. Bodies are `str` (aws-core's payload type; the
# streaming path frames them as aws-chunked), so a part body is a slice of the
# object.
#
#   create_multipart_upload (bucket, key)                       -> upload_id
#   upload_part             (bucket, key, upload_id, n, body)    -> etag
#   complete_multipart_upload (bucket, key, upload_id, parts)    -> result/etag
#   abort_multipart_upload  (bucket, key, upload_id)             -> (void)
#   put_object              (bucket, key, body)                  -> etag
#   head_size               (bucket, key)                        -> content-length
#   get_range               (bucket, key, offset, length)        -> body slice
#   copy_object             (dst_bucket, dst_key, src_bucket, src_key) -> etag
#   upload_part_copy        (dst_bucket, dst_key, upload_id, n, src_bucket,
#                            src_key, offset, length)            -> etag
struct S3TransferClient:
    fn(str, str) -> str create_multipart_upload
    fn(str, str, str, int64, str) -> str upload_part
    fn(str, str, str, list[CompletedPart]) -> str complete_multipart_upload
    fn(str, str, str) abort_multipart_upload
    fn(str, str, str) -> str put_object
    fn(str, str) -> int64 head_size
    fn(str, str, int64, int64) -> str get_range
    fn(str, str, str, str) -> str copy_object
    fn(str, str, str, int64, str, str, int64, int64) -> str upload_part_copy

# ---------------------------------------------------------------------------
# TransferManager — the boto3 TransferManager surface
# ---------------------------------------------------------------------------

# A managed-transfer manager bound to one S3 client seam and a config. `calls` is
# a single-element-per-op counter list, mutable in place and observable (the
# shared-reference shape batch_writer / retry use) so tests can assert the exact
# operation sequence without a network.
struct TransferManager:
    S3TransferClient client
    TransferConfig config

    # ---- upload --------------------------------------------------------

    # Upload `body` to `bucket`/`key`. Single PutObject below the multipart
    # threshold; otherwise CreateMultipartUpload → UploadPart (bounded waves) →
    # CompleteMultipartUpload, aborting the upload on any part failure. Returns
    # the final ETag/result the seam reports.
    def upload_fileobj(self, str bucket, str key, str body) -> str:
        if len(body) < self.config.multipart_threshold:
            fn(str, str, str) -> str put = self.client.put_object
            return put(bucket, key, body)
        return _multipart_upload(self, bucket, key, body)

    # Upload the file at `path`: read it (streamed by the fs layer) and hand the
    # bytes to `upload_fileobj`, so the threshold/multipart decision is identical
    # to a fileobj upload. boto3's `upload_file`.
    def upload_file(self, str bucket, str key, str path) -> str:
        return self.upload_fileobj(bucket, key, fs.read_file(path))

    # ---- download ------------------------------------------------------

    # Download `bucket`/`key` and return its bytes, fetched as ranged GETs
    # (`get_range`) sliced by the same part planner — a single range below the
    # chunk size, several above it — so a large object streams in bounded windows
    # instead of one buffered GET. boto3's download path.
    def download_fileobj(self, str bucket, str key) -> str:
        fn(str, str) -> int64 head = self.client.head_size
        auto total = head(bucket, key)
        fn(str, str, int64, int64) -> str get = self.client.get_range
        auto out = ""
        for p in plan_parts(total, self.config):
            out = out + get(bucket, key, p.offset, p.length)
        return out

    # Download `bucket`/`key` to `path` (ranged/streamed, then written out).
    def download_file(self, str bucket, str key, str path):
        fs.write_file(path, self.download_fileobj(bucket, key))

    # ---- copy ----------------------------------------------------------

    # Server-side copy src -> dst. A single CopyObject at or below `copy_threshold`
    # (5 GiB); otherwise CreateMultipartUpload → UploadPartCopy (ranged, per part)
    # → CompleteMultipartUpload, aborting on failure. `size` is the source object's
    # size (from a prior HeadObject), which selects the path and drives the part
    # ranges. Returns the final ETag/result.
    def copy(
        self,
        str dst_bucket,
        str dst_key,
        str src_bucket,
        str src_key,
        int64 size,
    ) -> str:
        if size <= self.config.copy_threshold:
            fn(str, str, str, str) -> str cp = self.client.copy_object
            return cp(dst_bucket, dst_key, src_bucket, src_key)
        return _multipart_copy(self, dst_bucket, dst_key, src_bucket, src_key, size)

# A manager with boto3's default TransferConfig.
def manager(S3TransferClient client) -> TransferManager:
    return TransferManager(client=client, config=transfer_config())

# A manager with an explicit TransferConfig.
def manager_with(S3TransferClient client, TransferConfig config) -> TransferManager:
    return TransferManager(client=client, config=config)

# ---------------------------------------------------------------------------
# Multipart orchestration (free functions; the methods delegate here)
# ---------------------------------------------------------------------------

# CreateMultipartUpload → UploadPart in bounded waves → CompleteMultipartUpload,
# aborting the upload on any part failure.
def _multipart_upload(TransferManager tm, str bucket, str key, str body) -> str:
    fn(str, str) -> str create = tm.client.create_multipart_upload
    auto upload_id = create(bucket, key)
    auto parts = plan_parts(len(body), tm.config)
    fn(str, str, str, int64, str) -> str up = tm.client.upload_part
    list[CompletedPart] done = []
    try:
        # Dispatch in bounded waves of max_concurrency (a live adapter may run a
        # wave's UploadParts concurrently; ordered here for a testable trace).
        for wave in plan_waves(parts, tm.config.max_concurrency):
            for number in wave:
                auto p = parts[number - 1]
                auto chunk = body[p.offset:p.offset + p.length]
                auto etag = up(bucket, key, upload_id, p.number, chunk)
                done.append(CompletedPart(number=p.number, etag=etag))
    except Exception as e:
        _abort(tm, bucket, key, upload_id)
        raise "upload aborted (multipart upload " + upload_id + "): " + e
    fn(str, str, str, list[CompletedPart]) -> str complete = tm.client.complete_multipart_upload
    return complete(bucket, key, upload_id, done)

# CreateMultipartUpload → UploadPartCopy (ranged per part) → Complete, aborting on
# failure. The source byte range for each part is the planned part window.
def _multipart_copy(
    TransferManager tm,
    str dst_bucket,
    str dst_key,
    str src_bucket,
    str src_key,
    int64 size,
) -> str:
    fn(str, str) -> str create = tm.client.create_multipart_upload
    auto upload_id = create(dst_bucket, dst_key)
    auto parts = plan_parts(size, tm.config)
    fn(str, str, str, int64, str, str, int64, int64) -> str upc = tm.client.upload_part_copy
    list[CompletedPart] done = []
    try:
        for p in parts:
            auto etag = upc(
                dst_bucket,
                dst_key,
                upload_id,
                p.number,
                src_bucket,
                src_key,
                p.offset,
                p.length,
            )
            done.append(CompletedPart(number=p.number, etag=etag))
    except Exception as e:
        _abort(tm, dst_bucket, dst_key, upload_id)
        raise "copy aborted (multipart upload " + upload_id + "): " + e
    fn(str, str, str, list[CompletedPart]) -> str complete = tm.client.complete_multipart_upload
    return complete(dst_bucket, dst_key, upload_id, done)

# Best-effort AbortMultipartUpload for an in-flight upload id.
def _abort(TransferManager tm, str bucket, str key, str upload_id):
    fn(str, str, str) abort = tm.client.abort_multipart_upload
    abort(bucket, key, upload_id)
