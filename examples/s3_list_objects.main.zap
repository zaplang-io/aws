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
#
# The SigV4 timestamp is stamped by the SDK from the current UTC time
# (sign_request_now / datetime), so the v1 ZAP_AWS_AMZ_DATE / ZAP_AWS_DATE_STAMP
# env vars are no longer needed (FRICTION #4 resolved).
#
# The response is rest-xml; this prints the raw body (a full XML parser is
# D-0011 §4). On a non-2xx reply aws.core.parse_error surfaces the <Code>.

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

    auto creds = credentials_from_env()
    auto region = os.getenv("AWS_REGION")
    auto bucket = os.getenv("ZAP_AWS_BUCKET")
    auto t = signing_time_now()

    auto req = list_objects_v2_request(
        creds,
        region,
        bucket,
        t.amz_date,
        t.date_stamp,
        prefix="photos/",
    )
    auto host = s3_host(bucket, region)
    print("--- request ---")
    print(req)
    print("--- response ---")
    auto resp = send(host, req)
    print("status: " + str(resp.status))
    print(resp.body)
    Optional[AwsError] err = parse_error(resp)
    if err.is_some():
        auto e = err.unwrap()
        print("error: " + e.code + " — " + e.message)
