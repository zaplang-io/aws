# Offline presigned-URL (query-parameter SigV4) conformance test (#359) — proves
# aws.core's presigner byte-for-byte against AWS's published known-answer vector
# (no live AWS calls).
#
# Vector: AWS S3 docs, "Authenticating Requests: Using Query Parameters (AWS
# Signature Version 4)" — a presigned GET of /test.txt on
# examplebucket.s3.amazonaws.com at 2013-05-24T00:00:00Z, us-east-1, service
# "s3", valid for 86400 seconds, signing only the `host` header with the payload
# hash set to the literal UNSIGNED-PAYLOAD. AWS documents the resulting
# X-Amz-Signature (aeeed9bb…604d404); we reproduce it from scratch through
# aws.core and print the signature and the full presigned URL.
# tests/expected/presign_url.expected pins the exact bytes, and
# tools/verify_vectors.py re-derives them independently.
#
# The second case exercises the temporary-credential path: a session token is
# carried as the X-Amz-Security-Token query param and an extra
# response-content-type param is merged in, so the parameter merge, percent-
# encoding and sort order are covered. It is self-consistent (re-derived by the
# oracle), not an AWS-published value.

import aws_core.core

def main():
    auto secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    auto region = "us-east-1"
    auto service = "s3"
    auto host = "examplebucket.s3.amazonaws.com"
    auto amz = "20130524T000000Z"
    auto ds = "20130524"

    # --- case 1: AWS published KAT (static credentials) -----------------
    auto creds = core.credentials("AKIAIOSFODNN7EXAMPLE", secret)
    dict[str, str] headers = {}
    headers["host"] = host
    auto req = core.Request(
        method="GET",
        service=service,
        region=region,
        host=host,
        path="/test.txt",
        query={},
        headers=headers,
        body="",
    )
    auto signed = core.presign_url(creds, req, 86400, amz, ds)
    print("### presign.s3.GetObject ###")
    # expect: aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404
    print(signed.signature)
    print(signed.url)

    # --- case 2: temporary credentials + extra query param --------------
    auto token = "FwoGZXIvYXdzEXAMPLE/token+value=="
    auto tcreds = core.credentials("ASIAIOSFODNN7EXAMPLE", secret, token)
    dict[str, str] theaders = {}
    theaders["host"] = host
    dict[str, str] extra = {}
    extra["response-content-type"] = "text/plain"
    auto treq = core.Request(
        method="GET",
        service=service,
        region=region,
        host=host,
        path="/test.txt",
        query=extra,
        headers=theaders,
        body="",
    )
    auto tsigned = core.presign_url(tcreds, treq, 900, amz, ds)
    print("### presign.s3.GetObject+token ###")
    print(tsigned.signature)
    print(tsigned.url)
