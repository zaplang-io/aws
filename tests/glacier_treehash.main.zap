# Offline Glacier tree-hash test — exercises aws.glacier (the SHA-256 tree hash
# Glacier requires on archive uploads) deterministically and pins the output in
# tests/expected/glacier_treehash.expected. Pure computation, no AWS: the hashes
# are cross-checked by an independent hashlib mirror in tools/verify_vectors.py
# (`glacier`), the same oracle posture as tests/cloudfront_signing.main.zap.
#
# Covers: the empty archive (one empty-chunk leaf = SHA-256 of ""), a sub-1-MiB
# archive (single leaf = plain SHA-256), an exactly-1-MiB archive (single leaf),
# a 4-MiB-plus-100-byte archive (5 leaves, so the first tree reduction is odd,
# 5 -> 3, exercising node promotion), the linear SHA-256, and the multipart
# accumulator (two 2-MiB parts + a 100-byte final part reproducing the
# whole-archive tree hash and size).
#
# Run: tools/run-tests.sh (via `zap run`) with the aws_core zenv active.

import aws_core.glacier

# A byte string of `n` copies of byte `b`, built by doubling (a handful of
# `bytes + bytes` concats, not an n-step loop), then sliced to length. Both the
# Zap test and the Python oracle use a single repeated byte, so the archive
# content agrees trivially.
def repeat_byte(int64 b, int64 n) -> bytes:
    if n == 0:
        return bytes()
    auto data = bytes([b])
    while len(data) < n:
        data = data + data
    return data[0:n]

def main():
    auto mib = 1048576
    auto target = 4 * mib + 100
    auto data = repeat_byte(97, target)
    auto one_mib = repeat_byte(97, mib)

    print("== empty ==")
    print(glacier.tree_hash_hex(bytes()))
    print("== small (hello) ==")
    print(glacier.tree_hash_hex(bytes("hello")))
    print("== one mib ==")
    print(glacier.tree_hash_hex(one_mib))

    print("== multi (5 leaves) ==")
    print("tree " + glacier.tree_hash_hex(data))
    print("linear " + glacier.linear_hash_hex(data))

    # Multipart: two 2-MiB parts + a 100-byte final part, 1-MiB-aligned so the
    # accumulated leaves reproduce the whole-archive tree hash.
    print("== multipart ==")
    auto p1 = data[0:2 * mib]
    auto p2 = data[2 * mib:4 * mib]
    auto p3 = data[4 * mib:target]
    auto th = glacier.new_tree_hasher()
    print("part1 " + th.add_part(p1))
    print("part2 " + th.add_part(p2))
    print("part3 " + th.add_part(p3))
    print("archive " + th.archive_tree_hash())
    print("size " + str(th.total_size()))
