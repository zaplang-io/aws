# Live example: S3 ListObjectsV2 against real AWS (virtual-hosted-style).
#
# Bundle + run:
#   tools/zrun.sh src/aws/core.zap src/aws/s3.zap \
#       examples/s3_list_objects.main.zap
#
# Required environment (see README "Running against real AWS"):
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   credentials
#   AWS_SESSION_TOKEN                          optional (temporary creds)
#   AWS_REGION                                 bucket's region, e.g. us-east-1
#   ZAP_AWS_BUCKET                             bucket name
#   ZAP_AWS_AMZ_DATE / ZAP_AWS_DATE_STAMP      SigV4 timestamp + scope date
#     export ZAP_AWS_AMZ_DATE=$(date -u +%Y%m%dT%H%M%SZ)
#     export ZAP_AWS_DATE_STAMP=$(date -u +%Y%m%d)
#
# The response is rest-xml; v1 prints it raw (no xml parser yet — D-0011 §4).

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
    if not need("ZAP_AWS_AMZ_DATE"):
        return
    if not need("ZAP_AWS_DATE_STAMP"):
        return

    auto creds = credentials_from_env()
    auto region = os.getenv("AWS_REGION")
    auto bucket = os.getenv("ZAP_AWS_BUCKET")
    auto amz_date = os.getenv("ZAP_AWS_AMZ_DATE")
    auto date_stamp = os.getenv("ZAP_AWS_DATE_STAMP")

    auto req = list_objects_v2_request(creds, region, bucket, amz_date, date_stamp)
    auto host = s3_host(bucket, region)
    print("--- request ---")
    print(req)
    print("--- response ---")
    print(send_https(host, req))
