# Offline test for the S3 managed-transfer helper (#438, epic #432): aws.transfer's
# TransferManager (upload_file/upload_fileobj, download_file/download_fileobj,
# copy) plus the pure part-planning (plan_parts / adjusted_chunksize / plan_waves /
# range_header / complete_mpu_body). NO live AWS — the generated S3 client is
# injected as a canned S3TransferClient seam (the "run these operations, hand back
# the results" shape, mirroring batch_writer's submit seam), so the threshold
# decision, the part math, the bounded waves, the Complete body, and the
# abort-on-failure path are all asserted deterministically. The expected output is
# pinned in tests/expected/transfer.expected and diffed by tools/run-tests.sh.
#
# What each block proves:
#   upload.single    : a body below multipart_threshold is a lone PutObject.
#   upload.multipart : above the threshold, Create → UploadPart×N → Complete, with
#                      the parts sliced by multipart_chunksize (8,8,4 for 20 bytes).
#   waves            : plan_waves groups parts into bounded max_concurrency waves.
#   upload.abort     : a failing UploadPart triggers AbortMultipartUpload + raise.
#   download         : a ranged/streamed GET per planned window (Range headers).
#   copy.single      : size <= copy_threshold is a single server-side CopyObject.
#   copy.multipart   : above it, Create → UploadPartCopy×N (ranged) → Complete.
#   plan             : plan_parts edge cases — empty object, the max_parts grow.

import aws_core.transfer

# --- a canned S3 client (the injected seam) ----------------------------------

# Records every operation it is handed, as a line log. `lines` is shared so the
# captured lambdas append in place (the shared-reference shape batch_writer uses).
struct Log:
    list[str] lines

def _create(Log lg, str b, str k) -> str:
    lg.lines.append("create b=" + b + " key=" + k)
    return "mpu-1"

def _part(Log lg, str b, str k, str u, int64 n, str body, bool fail) -> str:
    if fail and n == 2:
        raise "boom"
    lg.lines.append("part " + str(n) + " len=" + str(len(body)))
    return "etag-" + str(n)

def _complete(Log lg, str b, str k, str u, list[transfer.CompletedPart] parts) -> str:
    lg.lines.append(
        "complete parts=" + str(len(parts)) + " " + transfer.complete_mpu_body(parts),
    )
    return "done-etag"

def _abort(Log lg, str b, str k, str u):
    lg.lines.append("abort " + u)

def _put(Log lg, str b, str k, str body) -> str:
    lg.lines.append("put b=" + b + " key=" + k + " len=" + str(len(body)))
    return "put-etag"

def _head(Log lg, str b, str k, int64 size) -> int64:
    lg.lines.append("head b=" + b + " key=" + k)
    return size

def _range(Log lg, str b, str k, int64 off, int64 length) -> str:
    lg.lines.append("range " + transfer.range_header(off, length))
    return "<" + str(off) + ">"

def _copy(Log lg, str db, str dk, str sb, str sk) -> str:
    lg.lines.append("copy dst=" + db + "/" + dk + " src=" + sb + "/" + sk)
    return "copy-etag"

def _partcopy(
    Log lg,
    str db,
    str dk,
    str u,
    int64 n,
    str sb,
    str sk,
    int64 off,
    int64 length,
) -> str:
    lg.lines.append("partcopy " + str(n) + " " + transfer.range_header(off, length))
    return "cetag-" + str(n)

# Build a client wired to the recording helpers. `head_size` is what HeadObject
# reports; `fail` swaps in the part uploader that raises on part 2.
def mk_client(Log lg, int64 head_size, bool fail) -> transfer.S3TransferClient:
    fn(str, str) -> str cmu = lambda b, k: _create(lg, b, k)
    fn(str, str, str, int64, str) -> str up = lambda b, k, u, n, body: _part(lg, b, k, u, n, body, fail)
    fn(str, str, str, list[transfer.CompletedPart]) -> str comp = lambda b, k, u, parts: _complete(lg, b, k, u, parts)
    fn(str, str, str) ab = lambda b, k, u: _abort(lg, b, k, u)
    fn(str, str, str) -> str po = lambda b, k, body: _put(lg, b, k, body)
    fn(str, str) -> int64 hd = lambda b, k: _head(lg, b, k, head_size)
    fn(str, str, int64, int64) -> str gr = lambda b, k, off, length: _range(lg, b, k, off, length)
    fn(str, str, str, str) -> str cp = lambda db, dk, sb, sk: _copy(lg, db, dk, sb, sk)
    fn(str, str, str, int64, str, str, int64, int64) -> str upc = lambda db, dk, u, n, sb, sk, off, length: _partcopy(lg, db, dk, u, n, sb, sk, off, length)
    return transfer.S3TransferClient(
        create_multipart_upload=cmu,
        upload_part=up,
        complete_multipart_upload=comp,
        abort_multipart_upload=ab,
        put_object=po,
        head_size=hd,
        get_range=gr,
        copy_object=cp,
        upload_part_copy=upc,
    )

def new_log() -> Log:
    list[str] empty = []
    return Log(lines=empty)

def dump(Log lg):
    for line in lg.lines:
        print(line)

def main():
    # A small config so multipart is exercised without 8 MiB bodies: 10-byte
    # threshold, 8-byte parts, 1-byte part floor, 10-way concurrency, 10-byte
    # single-copy threshold.
    auto cfg = transfer.transfer_config_with(10, 8, 1, 10, 10000, 10)
    auto body20 = "0123456789abcdefghij"

    # --- upload.single -------------------------------------------------
    auto lg1 = new_log()
    auto tm1 = transfer.manager_with(mk_client(lg1, 0, False), cfg)
    auto r1 = tm1.upload_fileobj("bkt", "k.txt", "hello")
    print("### upload.single ###")
    dump(lg1)
    print("-> " + r1)

    # --- upload.multipart ----------------------------------------------
    auto lg2 = new_log()
    auto tm2 = transfer.manager_with(mk_client(lg2, 0, False), cfg)
    auto r2 = tm2.upload_fileobj("bkt", "big.bin", body20)
    print("### upload.multipart ###")
    dump(lg2)
    print("-> " + r2)

    # --- waves (bounded concurrency) -----------------------------------
    auto cfgw = transfer.transfer_config_with(10, 4, 1, 2, 10000, 10)
    auto wparts = transfer.plan_parts(20, cfgw)
    print("### waves ###")
    auto widx = 0
    for wsize in transfer.plan_waves(len(wparts), 2):
        auto s = ""
        auto wj = 0
        while wj < wsize:
            if wj > 0:
                s = s + ","
            s = s + str(wparts[widx].number)
            widx = widx + 1
            wj = wj + 1
        print("wave " + s)

    # --- upload.abort --------------------------------------------------
    auto lg3 = new_log()
    auto tm3 = transfer.manager_with(mk_client(lg3, 0, True), cfg)
    print("### upload.abort ###")
    try:
        auto r3 = tm3.upload_fileobj("bkt", "big.bin", body20)
        print("-> " + r3)
    except Exception as e:
        dump(lg3)
        print("caught: " + e)

    # --- download ------------------------------------------------------
    auto lg4 = new_log()
    auto tm4 = transfer.manager_with(mk_client(lg4, 20, False), cfg)
    auto body = tm4.download_fileobj("bkt", "obj")
    print("### download ###")
    dump(lg4)
    print("-> " + body)

    # --- copy.single ---------------------------------------------------
    auto lg5 = new_log()
    auto tm5 = transfer.manager_with(mk_client(lg5, 0, False), cfg)
    auto c1 = tm5.copy("db", "dk", "sb", "sk", 5)
    print("### copy.single ###")
    dump(lg5)
    print("-> " + c1)

    # --- copy.multipart ------------------------------------------------
    auto lg6 = new_log()
    auto tm6 = transfer.manager_with(mk_client(lg6, 0, False), cfg)
    auto c2 = tm6.copy("db", "dk", "sb", "sk", 20)
    print("### copy.multipart ###")
    dump(lg6)
    print("-> " + c2)

    # --- plan (pure part math) -----------------------------------------
    print("### plan ###")
    auto empty = transfer.plan_parts(0, cfg)
    auto ep = empty[0]
    print(
        "empty n=" + str(ep.number) + " off=" + str(ep.offset) + " len=" + str(ep.length),
    )
    auto cfgmp = transfer.transfer_config_with(10, 8, 1, 10, 2, 10)
    print(
        "maxparts chunk=" + str(transfer.adjusted_chunksize(20, cfgmp)) + " parts=" + str(len(transfer.plan_parts(20, cfgmp))),
    )
