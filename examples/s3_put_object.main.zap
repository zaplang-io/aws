# Live example: S3 PutObject against real AWS, showing the boto3-style ergonomic
# API — a content type and object metadata passed as keyword arguments.
#
# Bundle + run:
#   tools/zrun.sh src/aws/core.zap src/aws/endpoints.zap src/aws/s3.zap \
#       examples/s3_put_object.main.zap
#
# Required environment (see README "Running against real AWS"):
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   credentials
#   AWS_SESSION_TOKEN                          optional (temporary creds)
#   AWS_REGION                                 bucket's region, e.g. us-east-1
#   ZAP_AWS_BUCKET                             bucket name
#   ZAP_AWS_KEY                                object key, e.g. hello.txt
#
# The SigV4 timestamp is stamped by the SDK from the current UTC time
# (sign_request_now / datetime), so the v1 ZAP_AWS_AMZ_DATE / ZAP_AWS_DATE_STAMP
# env vars are no longer needed (FRICTION #4 resolved).
#
# The body, content type and metadata below are the whole payload the SDK signs;
# Content-Length and the x-amz-meta-* headers are derived for you.

import aws_core.core
import aws_core.s3
import os

def need(str name) -> bool:
    if os.hasenv(name):
        return True
    print("missing required env var: " + name)
    return False

def main():
    if not need("AWS_ACCESS_KEY_ID"):
        return
    if not need("AWS_SECRET_ACCESS_KEY"):
        return
    if not need("AWS_REGION"):
        return
    if not need("ZAP_AWS_BUCKET"):
        return
    if not need("ZAP_AWS_KEY"):
        return

    auto creds = core.credentials_from_env()
    auto region = os.getenv("AWS_REGION")
    auto bucket = os.getenv("ZAP_AWS_BUCKET")
    auto key = os.getenv("ZAP_AWS_KEY")
    auto t = core.signing_time_now()

    auto req = s3.put_object_request(
        creds,
        region,
        bucket,
        key,
        "hello from zap\n",
        t.amz_date,
        t.date_stamp,
        content_type="text/plain",
        metadata={"owner": "zap", "source": "example"},
    )
    auto host = s3.s3_host(bucket, region)
    print("--- request ---")
    print(req)
    print("--- response ---")
    auto resp = core.send(host, req)
    print("status: " + str(resp.status))
    print(resp.body)
    Optional[core.AwsError] err = core.parse_error(resp)
    if err.is_some():
        auto e = err.unwrap()
        print("error: " + e.code + " — " + e.message)
