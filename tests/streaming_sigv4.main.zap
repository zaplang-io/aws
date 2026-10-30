# Offline aws-chunked streaming-SigV4 conformance test (#358) — proves aws.core's
# rolling chunk-signature chain byte-for-byte against AWS's published
# known-answer vector (no live AWS calls).
#
# Vector: AWS S3 docs, "Signature Calculations for the Authorization Header:
# Transferring Payload in Multiple Chunks (Chunked Upload)" — a PUT of a
# 66560-byte object to /examplebucket/chunkObject.txt at 2013-05-24T00:00:00Z,
# us-east-1, service "s3", split into a 65536-byte chunk, a 1024-byte chunk, and
# the terminating zero-length chunk. AWS documents the seed signature and every
# per-chunk signature; we reproduce them from scratch through aws.core and print
# them. tests/expected/streaming_sigv4.expected pins the exact published bytes,
# and tools/verify_vectors.py re-derives the same values independently.
#
# The seed signature is the request's own SigV4 signature with the payload hash
# set to the STREAMING-AWS4-HMAC-SHA256-PAYLOAD sentinel; each chunk then signs
# over the previous chunk's signature (AWS4-HMAC-SHA256-PAYLOAD string-to-sign).
# The final encoded length (66824) matches AWS's documented Content-Length,
# cross-checking the aws-chunked frame format.

import aws_core.core

def main():
    # --- published example inputs ---------------------------------------
    auto secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    auto access = "AKIAIOSFODNN7EXAMPLE"
    auto region = "us-east-1"
    auto service = "s3"
    auto amz = "20130524T000000Z"
    auto ds = "20130524"
    auto creds = core.credentials(access, secret)

    # The 66560-byte payload: 65536 'a' (doubling 16×) then 1024 'a' (10×).
    auto chunk1 = "a"
    for i in range(0, 16):
        chunk1 = chunk1 + chunk1
    auto chunk2 = "a"
    for j in range(0, 10):
        chunk2 = chunk2 + chunk2

    # --- seed signature (SigV4 over the published signed-header set) -----
    # AWS signs content-length and x-amz-storage-class here too; the payload
    # hash is the streaming sentinel.
    dict[str, str] headers = {}
    headers["content-encoding"] = "aws-chunked"
    headers["content-length"] = "66824"
    headers["host"] = "s3.amazonaws.com"
    headers["x-amz-content-sha256"] = core.streaming_content_sha()
    headers["x-amz-date"] = amz
    headers["x-amz-decoded-content-length"] = "66560"
    headers["x-amz-storage-class"] = "REDUCED_REDUNDANCY"
    auto req = core.Request(
        method="PUT",
        service=service,
        region=region,
        host="s3.amazonaws.com",
        path="/examplebucket/chunkObject.txt",
        query={},
        headers=headers,
        body="",
    )
    auto seed = core.request_signature(creds, req, amz, ds)
    # expect: 4f232c4386841ef735655705268965c44a0e4690baa4adea153f7db9fa80a0a9
    print(seed)

    # --- rolling per-chunk signatures -----------------------------------
    auto key = core.signing_key(secret, ds, region, service)
    auto cred_scope = core.credential_scope(ds, region, service)
    auto s1 = core.chunk_signature(key, amz, cred_scope, seed, chunk1)
    auto s2 = core.chunk_signature(key, amz, cred_scope, s1, chunk2)
    auto sf = core.chunk_signature(key, amz, cred_scope, s2, "")
    # expect: 10000 ad80c730a21e5b8d04586a2213dd63b9a0e99e0e2307b0ade35a65485a288648
    print(core.hex_lower(len(chunk1)) + " " + s1)
    # expect: 400 0055627c9e194cb4542bae2aa5492e3c1575bbb81b612b7d234b86a503ef5497
    print(core.hex_lower(len(chunk2)) + " " + s2)
    # expect: 0 b6c6ea8a5354eaf15b3cb7646744f4275b71ea724fed81ceb9323e279d449df9
    print(core.hex_lower(0) + " " + sf)

    # --- framed body: decoded + encoded lengths -------------------------
    list[str] chunks = [chunk1, chunk2]
    auto cb = core.aws_chunked_body(key, amz, cred_scope, seed, chunks)
    # expect: 66560 (x-amz-decoded-content-length)
    print(core.decoded_content_length(chunks))
    # expect: 66824 (on-wire Content-Length of the aws-chunked body)
    print(str(len(cb.body)))
