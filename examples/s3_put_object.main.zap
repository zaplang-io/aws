# Live example: S3 PutObject against real AWS, showing the boto3-style ergonomic
# API — a content type and object metadata passed as keyword arguments.
#
# Bundle + run:
#   tools/zrun.sh src/aws/core.zap src/aws/s3.zap \
#       examples/s3_put_object.main.zap
#
# Required environment (see README "Running against real AWS"):
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   credentials
#   AWS_SESSION_TOKEN                          optional (temporary creds)
#   AWS_REGION                                 bucket's region, e.g. us-east-1
#   ZAP_AWS_BUCKET                             bucket name
#   ZAP_AWS_KEY                                object key, e.g. hello.txt
#   ZAP_AWS_AMZ_DATE / ZAP_AWS_DATE_STAMP      SigV4 timestamp + scope date
#     export ZAP_AWS_AMZ_DATE=$(date -u +%Y%m%dT%H%M%SZ)
#     export ZAP_AWS_DATE_STAMP=$(date -u +%Y%m%d)
#
# The body, content type and metadata below are the whole payload the SDK signs;
# Content-Length and the x-amz-meta-* headers are derived for you.

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
    if not need("ZAP_AWS_AMZ_DATE"):
        return
    if not need("ZAP_AWS_DATE_STAMP"):
        return

    auto creds = credentials_from_env()
    auto region = os.getenv("AWS_REGION")
    auto bucket = os.getenv("ZAP_AWS_BUCKET")
    auto key = os.getenv("ZAP_AWS_KEY")
    auto amz_date = os.getenv("ZAP_AWS_AMZ_DATE")
    auto date_stamp = os.getenv("ZAP_AWS_DATE_STAMP")

    auto req = put_object_request(
        creds,
        region,
        bucket,
        key,
        "hello from zap\n",
        amz_date,
        date_stamp,
        content_type="text/plain",
        metadata={"owner": "zap", "source": "example"},
    )
    auto host = s3_host(bucket, region)
    print("--- request ---")
    print(req)
    print("--- response ---")
    print(send_https(host, req))
