# Offline SigV4 conformance test — proves aws.core's signer byte-for-byte against
# AWS's published Signature Version 4 worked example (no live AWS calls).
#
# Vector: AWS General Reference, "Examples of signed AWS API requests" — a GET to
# https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08 at
# 2015-08-30T12:36:00Z, us-east-1, service "iam", with the published example
# credentials. AWS documents every intermediate value; we reproduce them from
# scratch through aws.core and print them. tests/expected/sigv4_vectors.expected
# pins the exact bytes AWS publishes, so any drift in the signer fails the diff.
#
# This drives the GENERIC, dict-driven canonicalization (canonical_headers /
# signed_headers): the caller supplies a header dict and aws.core lowercases,
# trims and sorts it. Matching AWS's published signature proves the canonical
# path is correct, not just a hand-sorted literal block.
#
# Run:  tools/zrun.sh src/aws/core.zap tests/sigv4_vectors.main.zap

def main():
    # --- published example inputs ---------------------------------------
    auto secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    auto access = "AKIDEXAMPLE"
    auto region = "us-east-1"
    auto service = "iam"
    auto amz_date = "20150830T123600Z"
    auto date_stamp = "20150830"
    auto host = "iam.amazonaws.com"
    auto query = "Action=ListUsers&Version=2010-05-08"
    auto ctype = "application/x-www-form-urlencoded; charset=utf-8"

    # --- canonical request (GET, empty body) ----------------------------
    auto body_hash = payload_hash("")
    # expect: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    print(body_hash)

    # The header dict the request signs; aws.core sorts/lowercases it.
    dict[str, str] headers = {}
    headers["content-type"] = ctype
    headers["host"] = host
    headers["x-amz-date"] = amz_date
    auto canon_headers = canonical_headers(headers)
    auto signed = signed_headers(headers)
    auto creq = canonical_request("GET", "/", query, canon_headers, signed, body_hash)
    # expect: f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59
    print(crypto.sha256(creq))

    # --- signing key fingerprint ----------------------------------------
    auto key = signing_key(secret, date_stamp, region, service)
    # AWS publishes sha256(kSigning). expect:
    # 30ded1dcf033502869c8051e7ccce37762f623ba1660a832b4f1221f07d07e27
    print(crypto.sha256(key))

    # --- string to sign + signature -------------------------------------
    auto cred_scope = credential_scope(date_stamp, region, service)
    auto sts = string_to_sign(amz_date, cred_scope, creq)
    auto signature = sign(key, sts)
    # expect: 5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7
    print(signature)

    # --- Authorization header -------------------------------------------
    print(authorization_header(access, cred_scope, signed, signature))
