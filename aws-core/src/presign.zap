# aws.presign — S3 presigned URL + presigned POST (ergonomics epic #432, ticket
# #439).
#
# The Zap counterpart of boto3's `client.generate_presigned_url` and
# `client.generate_presigned_post`: the two ways to hand time-boxed S3 access to
# a browser or a third party without sharing credentials.
#
#   * `generate_presigned_url` mints a signed GET/PUT (or any operation) URL whose
#     SigV4 signature rides in the query string — a link curl or a browser uses
#     directly until it expires.
#   * `generate_presigned_post` mints a POST policy + the form fields a browser
#     `multipart/form-data` upload posts straight to S3, with caller conditions
#     (content-length-range, starts-with, an ACL, …) baked into the signed policy.
#
# WHY HAND-WRITTEN (D-0001, generated-is-product): the low-level query-parameter
# SigV4 presigner is aws-core core surface (`core.presign_url`, #359, D-0003). This
# module is the boto3 CLIENT-METHOD ergonomics on top of it — the operation→
# method/host/path mapping for a URL, and the whole POST-policy machinery (policy
# document, base64, the HMAC-over-policy signature, the field set) which #359 does
# not cover. It is the S3 sibling of the DynamoDB ergonomics modules (conditions
# #433, marshal #434, batch_writer #435) and the companion of the managed-transfer
# helper (#438): resource-layer conveniences hand-written over the generated
# client and aws-core primitives, not derivable from the botocore model.
#
# ## Presigned URL (query-parameter SigV4)
# `generate_presigned_url` builds the S3 object `Request` (virtual-hosted host via
# `endpoints.resolve_s3`, the object-key path via `s3`) for the chosen HTTP method
# and hands it to `core.presign_url`, so the canonicalization, signing key,
# string-to-sign, and the UNSIGNED-PAYLOAD convention are the exact #359 code
# proven byte-for-byte against AWS's published vector. `params` become extra signed
# query parameters (e.g. `response-content-disposition`, `versionId`). Thin method
# wrappers `presign_get` / `presign_put` match boto3's common cases.
#
# ## Presigned POST (browser form upload)
# The POST path signs a base64-encoded POLICY document rather than a canonical
# request: `x-amz-signature = HexEncode(HMAC-SHA256(signing_key, base64(policy)))`,
# with the same `kDate→kRegion→kService→kSigning` key chain as header/URL signing
# (`core.signing_key` + `core.sign`). The returned `fields` are exactly what the
# browser form must POST, and the matching conditions are appended to the signed
# policy so S3 accepts them. Caller `conditions` are pre-rendered JSON fragments
# (e.g. `["content-length-range", 0, 1048576]`), keeping JSON string-escaping off
# this hand path, matching the `conditions` / `marshal` / `restxml` serializers.
#
# Both paths are purely additive over #359 and are re-derived independently by
# `tools/verify_vectors.py` (the SigV4 presign + the base64-policy HMAC), with the
# pinned fixtures in `tests/s3_presign.main.zap`.

import core
import endpoints
import s3
import base64

# ---------------------------------------------------------------------------
# Presigned URL (generate_presigned_url)
# ---------------------------------------------------------------------------

# Mint a presigned S3 object URL for `method` (GET/PUT/HEAD/DELETE/…), valid for
# `expires` seconds from `amz_date`. `params` are extra query parameters merged
# onto the link and signed (e.g. `response-content-type`, `versionId`). The host
# is the bucket's resolved S3 endpoint and the path is the signed object key, so
# the result is the same bytes `core.presign_url` proves against AWS's published
# known-answer vector. boto3's `client.generate_presigned_url('get_object', ...)`.
def generate_presigned_url(
    core.Credentials creds,
    str region,
    str bucket,
    str key,
    str amz_date,
    str date_stamp,
    str method = "GET",
    int64 expires = 3600,
    dict[str, str] params = {},
) -> core.PresignedUrl:
    auto ep = endpoints.resolve_s3(bucket, region, endpoints.default_s3_options())
    auto host = ep.host
    dict[str, str] headers = {}
    headers["host"] = host
    auto req = core.Request(
        method=method,
        service="s3",
        region=region,
        host=host,
        path=s3.s3_object_path(ep, bucket, key),
        query=params,
        headers=headers,
        body="",
    )
    return core.presign_url(creds, req, expires, amz_date, date_stamp)

# A presigned GET link (the download case) — boto3's default operation.
def presign_get(
    core.Credentials creds,
    str region,
    str bucket,
    str key,
    str amz_date,
    str date_stamp,
    int64 expires = 3600,
    dict[str, str] params = {},
) -> core.PresignedUrl:
    return generate_presigned_url(
        creds,
        region,
        bucket,
        key,
        amz_date,
        date_stamp,
        "GET",
        expires,
        params,
    )

# A presigned PUT link (the direct-upload case). The uploader sends the body with
# a plain HTTP PUT to the URL; the payload stays UNSIGNED-PAYLOAD, so any body is
# accepted within the expiry.
def presign_put(
    core.Credentials creds,
    str region,
    str bucket,
    str key,
    str amz_date,
    str date_stamp,
    int64 expires = 3600,
    dict[str, str] params = {},
) -> core.PresignedUrl:
    return generate_presigned_url(
        creds,
        region,
        bucket,
        key,
        amz_date,
        date_stamp,
        "PUT",
        expires,
        params,
    )

# Mint a presigned URL using the current UTC time (the usual live path), mirroring
# `core.presign_url_now`.
def generate_presigned_url_now(
    core.Credentials creds,
    str region,
    str bucket,
    str key,
    str method = "GET",
    int64 expires = 3600,
    dict[str, str] params = {},
) -> core.PresignedUrl:
    auto t = core.signing_time_now()
    return generate_presigned_url(
        creds,
        region,
        bucket,
        key,
        t.amz_date,
        t.date_stamp,
        method,
        expires,
        params,
    )

# ---------------------------------------------------------------------------
# Presigned POST (generate_presigned_post)
# ---------------------------------------------------------------------------

# One form field the browser must POST, name→value. Ordered (a list, not a dict)
# so the field set is deterministic for the pinned fixtures.
struct PostField:
    str name
    str value

# A minted presigned POST: the `url` the form posts to, the ordered `fields` it
# must carry (including `policy` and `x-amz-signature`), and the base64 `policy`
# and hex `signature` on their own for inspection/testing.
struct PresignedPost:
    str url
    list[PostField] fields
    str policy
    str signature

# The signed POST policy document (rest JSON). `conditions` are the caller's
# pre-rendered JSON condition fragments; the auto conditions matching the signed
# fields (key, algorithm, credential, date, and the session token when present)
# are appended so S3 accepts the posted fields. `expiration` is an ISO-8601 UTC
# instant (e.g. "2013-05-24T00:00:00Z"). No JSON string escaping on this hand
# path, matching the sibling hand serializers.
def _policy_document(
    str expiration,
    list[str] conditions,
    str key,
    str algorithm,
    str credential,
    str amz_date,
    str session_token,
) -> str:
    auto out = "{\"expiration\":\"" + expiration + "\",\"conditions\":["
    auto first = True
    for c in conditions:
        if not first:
            out = out + ","
        out = out + c
        first = False
    list[str] autoc = []
    autoc.append("{\"key\":\"" + key + "\"}")
    autoc.append("{\"x-amz-algorithm\":\"" + algorithm + "\"}")
    autoc.append("{\"x-amz-credential\":\"" + credential + "\"}")
    autoc.append("{\"x-amz-date\":\"" + amz_date + "\"}")
    if len(session_token) > 0:
        autoc.append("{\"x-amz-security-token\":\"" + session_token + "\"}")
    for c in autoc:
        if not first:
            out = out + ","
        out = out + c
        first = False
    return out + "]}"

# Mint a presigned POST for a browser `multipart/form-data` upload to
# `bucket`/`key`, valid until `expiration` (an ISO-8601 UTC instant). `conditions`
# are pre-rendered JSON policy conditions (e.g.
# `"[\"content-length-range\", 0, 1048576]"`, `"{\"acl\":\"public-read\"}"`);
# `extra_fields` are additional form fields the caller wants echoed back (each one
# a policy condition is also the caller's responsibility, via `conditions`). The
# signature is `HMAC-SHA256(signing_key, base64(policy))`, hex-encoded — the same
# key chain as URL/header signing. boto3's `client.generate_presigned_post`.
def generate_presigned_post(
    core.Credentials creds,
    str region,
    str bucket,
    str key,
    str amz_date,
    str date_stamp,
    str expiration,
    list[str] conditions = [],
    list[PostField] extra_fields = [],
) -> PresignedPost:
    auto ep = endpoints.resolve_s3(bucket, region, endpoints.default_s3_options())
    auto algorithm = core.presign_algorithm()
    auto cred_scope = core.credential_scope(date_stamp, region, "s3")
    auto credential = creds.access_key + "/" + cred_scope
    auto token = ""
    if creds.has_session:
        token = creds.session_token
    auto policy_json = _policy_document(
        expiration,
        conditions,
        key,
        algorithm,
        credential,
        amz_date,
        token,
    )
    auto policy_b64 = base64.encode(policy_json)
    auto signing_key = core.signing_key(creds.secret_key, date_stamp, region, "s3")
    auto signature = core.sign(signing_key, policy_b64)

    # The form fields, in a deterministic order: caller extras, key, the SigV4
    # fields, the optional session token, then the policy and signature.
    list[PostField] fields = []
    for f in extra_fields:
        fields.append(f)
    fields.append(PostField(name="key", value=key))
    fields.append(PostField(name="x-amz-algorithm", value=algorithm))
    fields.append(PostField(name="x-amz-credential", value=credential))
    fields.append(PostField(name="x-amz-date", value=amz_date))
    if len(token) > 0:
        fields.append(PostField(name="x-amz-security-token", value=token))
    fields.append(PostField(name="policy", value=policy_b64))
    fields.append(PostField(name="x-amz-signature", value=signature))

    auto url = "https://" + ep.host + "/"
    return PresignedPost(url=url, fields=fields, policy=policy_b64, signature=signature)
