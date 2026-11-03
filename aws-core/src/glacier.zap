# aws.glacier — SHA-256 tree-hash for Amazon S3 Glacier archive uploads.
#
# A hand-written ERGONOMICS module (epic #432, D-0001): the SHA-256 TREE HASH
# Glacier requires on every archive upload (`x-amz-sha256-tree-hash`), which the
# low-level client cannot compute for the caller and which callers otherwise
# hand-roll. It is pure computation over the archive bytes — no signing, no wire
# codec, no client — so unlike the resource-layer modules it needs no seam; it
# rides on `aws.core` only for packaging (the import contract every sibling
# ergonomics module uses).
#
# ## The tree-hash algorithm (what Glacier specifies)
#   1. Split the archive into 1 MiB (1048576-byte) chunks; the last chunk is the
#      remainder. A zero-length archive is one empty chunk.
#   2. SHA-256 each chunk -> a 32-byte LEAF hash.
#   3. Build a binary tree bottom-up: concatenate each adjacent pair of child
#      hashes (64 raw bytes) and SHA-256 that -> the parent hash. At a level with
#      an odd count, the last hash is promoted UNCHANGED to the next level.
#   4. Repeat until one hash remains — the tree hash. Emit it lowercase hex.
#
# Hashing is over RAW digest bytes (the 32-byte leaves are concatenated and
# re-hashed, NOT their hex text), so this uses the incremental hash API
# (`crypto.sha256_new` / `update` / `digest`) to get each digest as `bytes`, and
# assembles the 1 MiB chunks with byte slicing — both exercised by the toolchain
# goldens (`crypto_streaming`, `bytes_sha256`, `bytes_basics`). The plain
# (linear) SHA-256 of the whole archive — Glacier's `x-amz-content-sha256` — is
# `linear_hash_hex`.
#
# ## Multipart uploads
# For a multipart archive, each part must be a whole number of 1 MiB chunks
# (except the final part), so the part boundaries fall on leaf boundaries and the
# concatenation of every part's leaves reproduces the whole-archive leaf
# sequence. `TreeHasher` accumulates leaves across parts: `add_part(part)` returns
# that part's own tree hash (for the UploadMultipartPart
# `x-amz-sha256-tree-hash` header) while remembering its leaves, and
# `archive_tree_hash()` is the final whole-archive tree hash for
# CompleteMultipartUpload. This mirrors boto3's Glacier tree-hash utility.
#
# Depends on aws.core (bundled ahead of this file).

import core
import crypto
import hex

# The Glacier chunk size: 1 MiB. A function, not a module-level constant —
# top-level assignments are not v1 surface (ZAP3016, zaplang-io/zap#459).
def chunk_size() -> int64:
    return 1048576

# ---------------------------------------------------------------------------
# Raw SHA-256 and the 1 MiB leaf hashes
# ---------------------------------------------------------------------------

# The raw 32-byte SHA-256 digest of `data` (via the incremental hash API, which
# finalizes to digest bytes; `crypto.sha256` only yields hex).
def sha256_raw(bytes data) -> bytes:
    auto h = crypto.sha256_new()
    crypto.update(h, data)
    return crypto.digest(h)

# The 1 MiB leaf hashes of `data`: SHA-256 of each 1 MiB chunk (the last is the
# remainder). A zero-length archive hashes as a single empty chunk, so the leaf
# list is never empty — matching Glacier's tree hash of an empty archive
# (SHA-256 of "").
def leaf_hashes(bytes data) -> list[bytes]:
    list[bytes] leaves = []
    auto n = len(data)
    auto cs = chunk_size()
    if n == 0:
        leaves.append(sha256_raw(data))
        return leaves
    auto offset = 0
    while offset < n:
        auto end = offset + cs
        if end > n:
            end = n
        leaves.append(sha256_raw(data[offset:end]))
        offset = end
    return leaves

# ---------------------------------------------------------------------------
# The tree reduction
# ---------------------------------------------------------------------------

# Reduce one level: SHA-256 each adjacent pair of concatenated hashes; an odd
# trailing hash is promoted unchanged. Halves the count (rounding up) each call.
def reduce_level(list[bytes] level) -> list[bytes]:
    list[bytes] parent = []
    auto i = 0
    auto n = len(level)
    while i < n:
        if i + 1 < n:
            parent.append(sha256_raw(level[i] + level[i + 1]))
            i = i + 2
        else:
            parent.append(level[i])
            i = i + 1
    return parent

# The raw 32-byte tree-hash ROOT over a non-empty list of leaf hashes. Reduces
# level by level until one hash remains.
def tree_root(list[bytes] leaves) -> bytes:
    list[bytes] level = leaves
    while len(level) > 1:
        level = reduce_level(level)
    return level[0]

# ---------------------------------------------------------------------------
# Public one-shot helpers
# ---------------------------------------------------------------------------

# The Glacier SHA-256 tree hash of `data`, lowercase hex — the
# `x-amz-sha256-tree-hash` value for a single-request archive upload.
def tree_hash_hex(bytes data) -> str:
    return hex.encode(tree_root(leaf_hashes(data)))

# The plain (linear) SHA-256 of `data`, lowercase hex — Glacier's
# `x-amz-content-sha256`.
def linear_hash_hex(bytes data) -> str:
    return crypto.sha256(data)

# The tree hash of one already-computed leaf list, lowercase hex (for callers
# that have accumulated leaves themselves).
def tree_hash_of_leaves(list[bytes] leaves) -> str:
    return hex.encode(tree_root(leaves))

# ---------------------------------------------------------------------------
# Multipart accumulator (boto3's Glacier tree-hash utility)
# ---------------------------------------------------------------------------

# Accumulates the 1 MiB leaf hashes across the parts of a multipart upload and
# tracks the running archive size. Each part must be a whole number of 1 MiB
# chunks except the last, so leaf boundaries line up with part boundaries.
struct TreeHasher:
    list[bytes] leaves
    int64 size

    # Record `part` and return ITS OWN tree hash (lowercase hex) — the
    # `x-amz-sha256-tree-hash` header for that UploadMultipartPart request. The
    # method delegates to the mutating free function, as aws.batch_writer's
    # `put_item` delegates to `_add` (the proven self-mutation shape).
    def add_part(self, bytes part) -> str:
        return _add_part(self, part)

    # The whole-archive tree hash (lowercase hex) over every accumulated leaf —
    # the `x-amz-sha256-tree-hash` for CompleteMultipartUpload.
    def archive_tree_hash(self) -> str:
        return hex.encode(tree_root(self.leaves))

    # The total archive size accumulated so far (CompleteMultipartUpload's
    # `archiveSize`).
    def total_size(self) -> int64:
        return self.size

# A fresh accumulator.
def new_tree_hasher() -> TreeHasher:
    list[bytes] empty = []
    return TreeHasher(leaves=empty, size=0)

# Append `part`'s leaves to `th`, advance the size, and return the part's own
# tree hash hex. The free mutator the `add_part` method delegates to.
def _add_part(TreeHasher th, bytes part) -> str:
    auto part_leaves = leaf_hashes(part)
    for leaf in part_leaves:
        th.leaves.append(leaf)
    th.size = th.size + len(part)
    return hex.encode(tree_root(part_leaves))
