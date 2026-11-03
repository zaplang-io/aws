# aws.cloudfront — CloudFront signed URLs & signed cookies for private content.
#
# A hand-written ERGONOMICS module (epic #432, D-0001): boto3's
# `botocore.signers.CloudFrontSigner` plus the `generate_presigned_url` /
# signed-cookie conveniences, for serving private content through a CloudFront
# distribution with a trusted key group / key pair. It is NOT SigV4 — CloudFront
# private content uses an RSA-SHA1 signature over a POLICY document with a
# CloudFront key-pair private key, so this module shares nothing with
# aws.core's SigV4 presigner (#359) beyond the base64 primitive. It rides on
# aws.core only for packaging (bundled after it, the import contract every
# sibling module uses); the signing math is entirely CloudFront's own.
#
# ## The two policy shapes (botocore's canned vs. custom)
#   * CANNED policy — one Resource + a single DateLessThan (expiry) condition.
#     The signed URL carries `Expires`/`Signature`/`Key-Pair-Id` (the policy is
#     reconstructed by CloudFront from the fixed canned template, so it is never
#     transmitted); the signed cookies carry `CloudFront-Expires`/`-Signature`/
#     `-Key-Pair-Id`. One URL, one expiry — the common case.
#   * CUSTOM policy — an explicit policy document that may also set a start time
#     (DateGreaterThan), an IP/CIDR restriction (IpAddress), and a wildcard
#     Resource. The full policy is transmitted, CloudFront-base64-encoded, as the
#     `Policy` query param (URL) / `CloudFront-Policy` cookie. The signature is
#     over the exact policy bytes, so the byte sequence this module emits IS the
#     contract (hence the pinned-fixture test, like the SigV4 oracle).
#
# ## The CloudFront base64 variant
# CloudFront uses standard base64 with three characters remapped so the value is
# URL/cookie safe: `+` -> `-`, `=` -> `_`, `/` -> `~`. `cloudfront_b64` applies
# that to a standard `base64.encode` (padded, matches botocore's
# `base64.b64encode` + `.translate(b'-_~', b'+=/')`).
#
# ## The RSA-SHA1 signer SEAM + the live PEM constructor
# CloudFront signs `RSA-SHA1(private_key, policy_bytes)`. The RSA signature is
# taken as an injected seam — a `fn(bytes) -> bytes` that maps the policy bytes to
# the raw signature bytes — exactly as aws.paginators takes a fetch closure and
# aws.waiters leaves the poll `operation` unmodeled. Everything else (policy
# construction, the base64 variant, URL/cookie assembly) is implemented and pinned
# here. `cloudfront_signer(key_pair_id, rsa_sha1)` takes any such seam;
# `cloudfront_signer_pem(key_pair_id, pem_key)` is the LIVE constructor, backed by
# the stdlib primitive `crypto.rsa_sha1_sign` over a PKCS#1 or PKCS#8 PEM. (RSA
# was originally a gap in the crypto module #105, which shipped SHA/HMAC/CSPRNG
# only; filed as zaplang-io/zap#628 and added in #629 — so callers that hold the
# CloudFront key-pair private key need no seam of their own.)
#
# Depends on aws.core (bundled ahead of this file).

import core
import base64
import crypto

# ---------------------------------------------------------------------------
# The CloudFront base64 variant
# ---------------------------------------------------------------------------

# Standard base64 (padded) with CloudFront's URL/cookie-safe substitution:
# `+` -> `-`, `=` -> `_`, `/` -> `~`. Takes bytes so callers pass a raw signature
# or policy bytes without an implicit str<->bytes coercion.
def cloudfront_b64(bytes data) -> str:
    auto s = base64.encode(data)
    s = s.replace("+", "-")
    s = s.replace("=", "_")
    s = s.replace("/", "~")
    return s

# ---------------------------------------------------------------------------
# Policy documents (compact JSON, byte-for-byte what is signed)
# ---------------------------------------------------------------------------
#
# Built by concatenation rather than json.dumps so the exact byte order is fixed
# (CloudFront reconstructs the CANNED policy from this precise template, and the
# CUSTOM policy's signature is over these exact bytes). Resources are placed
# verbatim; a CloudFront resource URL never contains JSON metacharacters.

# The fixed canned-policy template: one Resource + one DateLessThan condition.
def canned_condition(int64 expires) -> str:
    return "\"DateLessThan\":{\"AWS:EpochTime\":" + str(expires) + "}"

# The custom-policy condition block: DateLessThan (always), then DateGreaterThan
# when `date_greater_than` > 0, then IpAddress when `source_ip` is non-empty.
# This insertion order is the contract (the signature covers it verbatim).
def custom_condition(
    int64 date_less_than,
    int64 date_greater_than,
    str source_ip,
) -> str:
    auto cond = "\"DateLessThan\":{\"AWS:EpochTime\":" + str(date_less_than) + "}"
    if date_greater_than > 0:
        auto gt = "\"DateGreaterThan\":{\"AWS:EpochTime\":"
        cond = cond + "," + gt + str(date_greater_than) + "}"
    if len(source_ip) > 0:
        auto ip = "\"IpAddress\":{\"AWS:SourceIp\":\""
        cond = cond + "," + ip + source_ip + "\"}"
    return cond

# Wrap a condition block in the single-statement policy envelope.
def policy_doc(str resource, str condition) -> str:
    auto head = "{\"Statement\":[{\"Resource\":\""
    auto mid = "\",\"Condition\":{"
    return head + resource + mid + condition + "}}]}"

# A canned policy for `resource` expiring at `expires` (epoch seconds).
def canned_policy(str resource, int64 expires) -> str:
    return policy_doc(resource, canned_condition(expires))

# A custom policy for `resource`: `date_less_than` is the required expiry;
# `date_greater_than` (0 = omit) is an activation time; `source_ip` ("" = omit)
# restricts access to an IP or CIDR range.
def custom_policy(
    str resource,
    int64 date_less_than,
    int64 date_greater_than,
    str source_ip,
) -> str:
    auto cond = custom_condition(date_less_than, date_greater_than, source_ip)
    return policy_doc(resource, cond)

# ---------------------------------------------------------------------------
# Query-string assembly
# ---------------------------------------------------------------------------

# One ordered query parameter (CloudFront params are emitted in a fixed order and
# their values are already URL-safe after `cloudfront_b64`, so they are appended
# verbatim — no percent-encoding, matching botocore's signer).
struct QueryParam:
    str name
    str value

# Append `params` to `url`, choosing `?` or `&` depending on whether the URL
# already carries a query string.
def append_query(str url, list[QueryParam] params) -> str:
    auto sep = "?"
    if url.contains("?"):
        sep = "&"
    auto q = ""
    auto first = True
    for p in params:
        if first:
            first = False
        else:
            q = q + "&"
        q = q + p.name + "=" + p.value
    return url + sep + q

# ---------------------------------------------------------------------------
# The signer handle (boto3's CloudFrontSigner)
# ---------------------------------------------------------------------------

# A CloudFront signer: the trusted-signer `key_pair_id` (boto3's `key_id`) plus
# the injected RSA-SHA1 primitive `rsa_sha1(policy_bytes) -> signature_bytes`.
# The live adapter wraps the CloudFront key-pair private key; the offline test
# injects a deterministic stand-in (see the module header on the crypto gap).
struct CloudFrontSigner:
    str key_pair_id
    fn(bytes) -> bytes rsa_sha1

    # RSA-SHA1-sign a policy document and CloudFront-base64 the signature. The
    # fn-typed field is bound to a local before the call (the always-valid form
    # aws.middleware / aws.paginators use — a direct `self.rsa_sha1(...)` parses
    # as a method call).
    def sign_policy(self, str policy) -> str:
        fn(bytes) -> bytes signer = self.rsa_sha1
        auto sig = signer(bytes(policy))
        return cloudfront_b64(sig)

    # A canned-policy signed URL: carries Expires / Signature / Key-Pair-Id. The
    # policy's Resource is the URL itself.
    def signed_url_canned(self, str url, int64 expires) -> str:
        auto sig = self.sign_policy(canned_policy(url, expires))
        list[QueryParam] ps = [
            QueryParam(name="Expires", value=str(expires)),
            QueryParam(name="Signature", value=sig),
            QueryParam(name="Key-Pair-Id", value=self.key_pair_id),
        ]
        return append_query(url, ps)

    # A custom-policy signed URL: carries the full CloudFront-base64 Policy plus
    # Signature / Key-Pair-Id. `date_greater_than` (0 = omit) and `source_ip`
    # ("" = omit) add the start-time / IP conditions. Defaults live on the free
    # `custom_policy`, not here, because defaulted parameters on struct METHODS
    # miscompiled before zap#481 — the repo convention keeps method params
    # explicit (callers pass 0 / "" to omit).
    def signed_url_custom(
        self,
        str url,
        int64 expires,
        int64 date_greater_than,
        str source_ip,
    ) -> str:
        auto pol = custom_policy(url, expires, date_greater_than, source_ip)
        list[QueryParam] ps = [
            QueryParam(name="Policy", value=cloudfront_b64(bytes(pol))),
            QueryParam(name="Signature", value=self.sign_policy(pol)),
            QueryParam(name="Key-Pair-Id", value=self.key_pair_id),
        ]
        return append_query(url, ps)

    # Canned-policy signed cookies for `resource` (a URL, possibly with a `*`
    # wildcard path): CloudFront-Expires / -Signature / -Key-Pair-Id.
    def signed_cookies_canned(self, str resource, int64 expires) -> dict[str, str]:
        auto sig = self.sign_policy(canned_policy(resource, expires))
        dict[str, str] c = {}
        c["CloudFront-Expires"] = str(expires)
        c["CloudFront-Signature"] = sig
        c["CloudFront-Key-Pair-Id"] = self.key_pair_id
        return c

    # Custom-policy signed cookies: CloudFront-Policy (the CloudFront-base64
    # policy) / -Signature / -Key-Pair-Id. Same `date_greater_than` / `source_ip`
    # omit conventions as `signed_url_custom`.
    def signed_cookies_custom(
        self,
        str resource,
        int64 expires,
        int64 date_greater_than,
        str source_ip,
    ) -> dict[str, str]:
        auto pol = custom_policy(resource, expires, date_greater_than, source_ip)
        dict[str, str] c = {}
        c["CloudFront-Policy"] = cloudfront_b64(bytes(pol))
        c["CloudFront-Signature"] = self.sign_policy(pol)
        c["CloudFront-Key-Pair-Id"] = self.key_pair_id
        return c

# Construct a signer from the trusted key-pair id and the RSA-SHA1 seam.
def cloudfront_signer(str key_pair_id, fn(bytes) -> bytes rsa_sha1) -> CloudFrontSigner:
    return CloudFrontSigner(key_pair_id=key_pair_id, rsa_sha1=rsa_sha1)

# The LIVE constructor: a signer backed by the stdlib RSA-SHA1 primitive
# (zaplang-io/zap#628, added in #629) over a CloudFront key-pair private key.
# `pem_key` is the PEM private key (PKCS#1 `BEGIN RSA PRIVATE KEY` or PKCS#8
# `BEGIN PRIVATE KEY`). The injected seam calls `crypto.rsa_sha1_sign(pem, policy)`
# per policy and returns the raw signature bytes; `sign_policy` then applies the
# CloudFront base64 variant. `pem_key` is bound to a local before the lambda
# captures it (the always-valid closure form).
def cloudfront_signer_pem(str key_pair_id, str pem_key) -> CloudFrontSigner:
    auto pem = pem_key
    fn(bytes) -> bytes rsa = lambda p: crypto.rsa_sha1_sign(pem, p)
    return cloudfront_signer(key_pair_id, rsa)
