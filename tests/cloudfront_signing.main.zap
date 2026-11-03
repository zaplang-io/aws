# Offline CloudFront signing test — exercises aws.cloudfront (signed URLs &
# signed cookies for private content) deterministically and pins the output in
# tests/expected/cloudfront_signing.expected. No live AWS calls and no real RSA.
#
# CloudFront signs RSA-SHA1(key-pair-private-key, policy_bytes), but the Zap
# crypto stdlib (zaplang-io/zap#105) has no RSA primitive (see the module header
# and the accompanying report — a `crypto.rsa_sha1_sign` is the language-first
# follow-up). So the signature is driven through the module's injected
# `fn(bytes) -> bytes` seam by a DETERMINISTIC stand-in: the raw SHA-1 digest of
# the policy bytes. The independent oracle (tools/verify_vectors.py) reproduces
# the identical stand-in (`hashlib.sha1(policy).digest()`), so the policy
# construction, the CloudFront base64 variant, and the URL/cookie param
# placement are all cross-checked byte-for-byte without AWS or an RSA library.
# Swapping the seam for a real RSA-SHA1 signer is the only change needed for live
# signatures; nothing else in the pinned output depends on the signer internals.
#
# Run: tools/run-tests.sh (via `zap run`) with the aws_core zenv active.

import aws_core.core
import aws_core.cloudfront
import crypto

# The RSA-SHA1 stand-in: raw SHA-1 digest bytes of the policy. Streaming handle
# so the digest is the raw bytes (crypto.sha1 returns hex); matches the oracle.
def stub_rsa_sha1(bytes policy) -> bytes:
    auto h = crypto.sha1_new()
    crypto.update(h, policy)
    return crypto.digest(h)

# Print one cookie by name so the order is fixed (dict iteration order is not
# part of the contract; the emitted param NAMES and VALUES are).
def show_cookie(dict[str, str] c, str key) -> str:
    Optional[str] v = c.get(key)
    return key + "=" + v.unwrap_or("")

def main():
    fn(bytes) -> bytes signer_fn = stub_rsa_sha1
    auto signer = cloudfront.cloudfront_signer("APKAEXAMPLE123456", signer_fn)
    auto url = "https://d111111abcdef8.cloudfront.net/private/content.jpg"
    auto wildcard = "https://d111111abcdef8.cloudfront.net/private/*"
    auto expires = 1700000000
    auto dgt = 1699990000
    auto ip = "203.0.113.0/24"

    # Policy documents — the exact bytes CloudFront verifies the signature over.
    print("== canned policy ==")
    print(cloudfront.canned_policy(url, expires))
    print("== custom policy ==")
    print(cloudfront.custom_policy(wildcard, expires, dgt, ip))

    # The CloudFront base64 variant: +/= remapped to -~_. The three inputs make
    # standard base64 produce a `+`, a `/`, and `=` padding respectively.
    print("== cloudfront-base64 ==")
    print("gt=" + cloudfront.cloudfront_b64(bytes(">>>")))
    print("qm=" + cloudfront.cloudfront_b64(bytes("???")))
    print("pad=" + cloudfront.cloudfront_b64(bytes("a")))

    # Signed URLs: canned (Expires/Signature/Key-Pair-Id) and custom
    # (Policy/Signature/Key-Pair-Id).
    print("== canned url ==")
    print(signer.signed_url_canned(url, expires))
    print("== custom url ==")
    print(signer.signed_url_custom(url, expires, dgt, ip))

    # Signed cookies: canned (CloudFront-Expires/-Signature/-Key-Pair-Id) and
    # custom (CloudFront-Policy/-Signature/-Key-Pair-Id), printed by fixed key.
    print("== canned cookies ==")
    auto cc = signer.signed_cookies_canned(wildcard, expires)
    print(show_cookie(cc, "CloudFront-Expires"))
    print(show_cookie(cc, "CloudFront-Signature"))
    print(show_cookie(cc, "CloudFront-Key-Pair-Id"))
    print("== custom cookies ==")
    auto xc = signer.signed_cookies_custom(wildcard, expires, dgt, ip)
    print(show_cookie(xc, "CloudFront-Policy"))
    print(show_cookie(xc, "CloudFront-Signature"))
    print(show_cookie(xc, "CloudFront-Key-Pair-Id"))
