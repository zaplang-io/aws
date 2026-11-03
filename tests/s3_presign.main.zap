# Offline test for the S3 presign ergonomics (#439, epic #432): aws.presign's
# generate_presigned_url / presign_get / presign_put and generate_presigned_post.
# NO live AWS — the signatures are pure SigV4 over fixed inputs.
#
# The pinned values in tests/expected/s3_presign.expected are re-derived
# independently by tools/verify_vectors.py (`s3_presign`): the URL cases re-run
# the query-parameter SigV4 with the REGIONAL virtual-hosted host aws.endpoints
# resolves (so they exercise the ergonomics host/path wiring, not just the core
# presigner the KAT in tests/presign_url.main.zap already covers), and the POST
# cases re-derive base64(policy) and the HMAC-over-policy signature from scratch.
#
# What each block proves:
#   url.get         : a presigned GET link — host/path resolution + core.presign_url.
#   url.get+params  : extra signed query params merge, percent-encode and sort
#                     into the canonical query (response-content-type, versionId).
#   url.put         : a presigned PUT link in a non-us-east-1 region (scope region).
#   post            : a presigned POST policy + fields, with caller conditions and
#                     echoed form fields; the signature signs base64(policy).
#   post+token      : temporary credentials add the x-amz-security-token field and
#                     the matching policy condition.

import aws_core.core
import aws_core.presign

def _print_url(str tag, core.PresignedUrl u):
    print(tag)
    print(u.signature)
    print(u.url)

def _print_post(str tag, presign.PresignedPost p):
    print(tag)
    print(p.policy)
    print(p.signature)
    print(p.url)
    for f in p.fields:
        print("field " + f.name + "=" + f.value)

def main():
    auto secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    auto amz = "20130524T000000Z"
    auto ds = "20130524"
    auto creds = core.credentials("AKIAIOSFODNN7EXAMPLE", secret)

    # --- presigned GET -------------------------------------------------
    auto g = presign.presign_get(
        creds,
        "us-east-1",
        "examplebucket",
        "test.txt",
        amz,
        ds,
        86400,
    )
    _print_url("### presign.url.get ###", g)

    # --- presigned GET with extra signed query params ------------------
    dict[str, str] params = {}
    params["response-content-type"] = "text/plain"
    params["versionId"] = "L4kqtJlcpXroDVBH40Nr8X8g+rmSpXd3"
    auto gp = presign.generate_presigned_url(
        creds,
        "us-east-1",
        "examplebucket",
        "test.txt",
        amz,
        ds,
        "GET",
        900,
        params,
    )
    _print_url("### presign.url.get+params ###", gp)

    # --- presigned PUT (non-us-east-1 region) --------------------------
    auto pu = presign.presign_put(
        creds,
        "us-west-2",
        "my-bucket",
        "uploads/report.pdf",
        amz,
        ds,
        3600,
    )
    _print_url("### presign.url.put ###", pu)

    # --- presigned POST ------------------------------------------------
    list[str] conds = [
        "{\"acl\":\"public-read\"}",
        "[\"starts-with\",\"$Content-Type\",\"image/\"]",
        "[\"content-length-range\",1,10485760]",
    ]
    list[presign.PostField] extra = [
        presign.PostField(name="acl", value="public-read"),
        presign.PostField(name="Content-Type", value="image/png"),
    ]
    auto post = presign.generate_presigned_post(
        creds,
        "us-east-1",
        "examplebucket",
        "user/uploads/${filename}",
        amz,
        ds,
        "2013-05-24T12:00:00Z",
        conds,
        extra,
    )
    _print_post("### presign.post ###", post)

    # --- presigned POST with temporary credentials ---------------------
    auto token = "FwoGZXIvYXdzEXAMPLE/token+value=="
    auto tcreds = core.credentials("ASIAIOSFODNN7EXAMPLE", secret, token)
    list[str] conds2 = ["[\"content-length-range\",0,1048576]"]
    list[presign.PostField] noextra = []
    auto tpost = presign.generate_presigned_post(
        tcreds,
        "us-west-2",
        "my-bucket",
        "incoming/data.bin",
        amz,
        ds,
        "2013-05-24T12:00:00Z",
        conds2,
        noextra,
    )
    _print_post("### presign.post+token ###", tpost)
