# Live example: DynamoDB GetItem against real AWS.
#
# Bundle + run:
#   tools/zrun.sh src/aws/core.zap src/aws/endpoints.zap src/aws/dynamodb.zap \
#       examples/dynamodb_get_item.main.zap
#
# Required environment (see README "Running against real AWS"):
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   credentials (env provider)
#   AWS_SESSION_TOKEN                          optional, for temporary creds
#   AWS_REGION                                 e.g. us-east-1
#
# The SigV4 timestamp is now stamped by the SDK from the current UTC time
# (sign_request_now / datetime); the v1 ZAP_AWS_AMZ_DATE / ZAP_AWS_DATE_STAMP
# env vars are no longer needed (FRICTION #4 resolved). SigV4 rejects a
# timestamp skewed more than ~5 minutes, so the host clock must be roughly
# correct.
#
# This demo reads table "Users" with key id="alice" (edit below), sends the
# request over TLS, and surfaces a typed error via aws.core on a non-2xx reply.

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

    auto creds = credentials_from_env()
    auto region = os.getenv("AWS_REGION")
    auto t = signing_time_now()

    auto table = "Users"
    auto req = get_item_request(
        creds,
        region,
        table,
        {"id": "alice"},
        t.amz_date,
        t.date_stamp,
    )
    auto host = regional_host("dynamodb", region)
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
