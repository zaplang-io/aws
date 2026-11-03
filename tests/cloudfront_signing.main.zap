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

# A throwaway RSA test key (PKCS#8 PEM) for the live-signer path — NOT a real
# CloudFront key; generated solely to exercise crypto.rsa_sha1_sign end to end.
def test_pem() -> str:
    return "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCK+/gHCnV77KS7\n8EGEeKTcJ3Bf0KTFzvhLC+4VG1023Spwo/NKo6I6utd29eA7PIYbkhxEtXHtzofL\nLaJnNrFlkCeD20c0gEsT1R3ZLP+To4f4bWXAOVAnAa3OfPz2F28TlrVvNcIZ9/4A\nCqCCjh60XYvvBVvJDhSpL41PmWKc02UWtkwV4Do4Fv1RMkpkPDL7tYj8yTiN4PKH\nyVxDzpNNR97ULMSbFFsNDOAOJZwOGSlkdCY7Ei/VRAmJKcQXI+nWO6L+cSpm2l1r\n+gLVz4lkEuQCcFZyI0fuTn+CycuwFXq2iIZ9LGticblomPQAMn5GtOoARRiaTbXO\nGDfDBzFfAgMBAAECggEADPPBYAqZ+0QI8BjKSkmh94BXaR59FJAetIO2mtHzhGbl\nCx1EUYrhVf7OkKAGVw7jYpNhvgd4yBQstIMatOq0aoYeIJwhTSO9m2oLf49BfCVL\nyRuM1Xah4Ri3dVxRiK+TYuxzGRuV7KyfR6q13aTX+LAVF9/Ud26v/zpWvXnKZlnr\n0Swt10WDvtzVqIyjAduU7uPEWR/tJ3p6wUHoObk7/YgpmN1++LxcGARDCvONdujw\nSTJDINpMMyXZjq0XcKQt89pMBXw9EhAh+mPSYSyQ4TafQ2PxBqynpfaBOmcNv7H2\n2oGmCnnKp8/n22ywLVJFOhxNlZb6FMRJxDEyngfhaQKBgQDBbCJ3wXQiR2TAHZOu\nuk2KwX/FxP/vRXaVFqUJjrtrpLC6HuAsmFRivKnmHm6av2zuJ0a+TUCFqcXMSBZf\nAy5i2Kw/uBlUlSgtBpJZLhwnrFzErPYXfHAbkloI7kvEOXXp26vl//ftYf+v9vg6\nRQujqLHfumQwgVTIw28cDfFwyQKBgQC38xd8aej7BgcoyydANDqzcObN7pGsZX/W\nRmGQBkRlmUjnAdVUXr2r+EPUmf5JRzHkbQsFgZMqj1WNL7IKck5n0ybltFxheDKT\nNhyJ3LnwcyMlY+NPoykMLxlHMsELxS9wee6F3g7oxw9xsfzJ/nMYuGWDSbtyo71c\nxMnk71kM5wKBgElk4t9WRN8NACn2DyfqAap5Kia9TfBZB1ojMZSi2HNMFtNJC/9f\n/gVJWZ68RXPq10a3GJz1a1pMxYVyhSqgZmWTmijDjrkNsCUFrVqxqHVVbg4jI25e\nBZwwuIFTCuT2eMu4U03/BvDIkuEOcbqKoJQFWxlt/L57FNTpc6vNjqQhAoGABs0H\nBkOIKJe9dgWkytvje7Tl46E5Y41RH6P0gXWp27PCHUBVGcxy6MPCBj83RpBKSO67\nJJX40e8As7qas4YsXexRmNaFP9lIzWaHwZUWjsxC9WPvCIe4wcmP/rDisEO3EEqB\nxhNCq9qIOKTi+rjcmoJexm7YblGdc6uW507uFOsCgYEAsliiFMskj69RXNXsRmnn\n2Ml+72osao27v42kzKwjaz/1BLMZ4zGMcoZcix5OOhZb5DDIJ84lD3LEYXWLLw9B\nddvEWjgvg52oa3aGwqY8ed9EFWIB0V9uef6jh8/kcA1NnLfLFrz6NO8HLA6FrCqE\nFCHCjaT8b0sm0MMin/qTYAM=\n-----END PRIVATE KEY-----\n"


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

    # Live path: the stdlib RSA-SHA1 primitive (zap#628/#629) wired through
    # cloudfront_signer_pem. Exercises crypto.rsa_sha1_sign end to end; the
    # signature is deterministic (PKCS#1 v1.5), so assert it is stable and
    # non-empty rather than pinning RSA bytes (no RSA in the Python oracle).
    print("== live signer ==")
    auto live = cloudfront.cloudfront_signer_pem("APKALIVEKEY000001", test_pem())
    auto pol = cloudfront.canned_policy(url, expires)
    auto s1 = live.sign_policy(pol)
    auto s2 = live.sign_policy(pol)
    if len(s1) > 0 and s1 == s2:
        print("live signer: ok")
    else:
        print("live signer: FAILED")
