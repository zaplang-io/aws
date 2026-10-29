# Live example: DynamoDB GetItem against real AWS.
#
# Bundle + run:
#   tools/zrun.sh src/aws/core.zap src/aws/dynamodb.zap \
#       examples/dynamodb_get_item.main.zap
#
# Required environment (see README "Running against real AWS"):
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   credentials (env provider)
#   AWS_SESSION_TOKEN                          optional, for temporary creds
#   AWS_REGION                                 e.g. us-east-1
#   ZAP_AWS_AMZ_DATE                           SigV4 timestamp, YYYYMMDDTHHMMSSZ
#   ZAP_AWS_DATE_STAMP                         scope date, YYYYMMDD
#
# The two date vars are supplied by the caller because the runtime cannot yet
# reshape datetime.now() into the SigV4 basic format (no string surgery; see
# FRICTION.md). Generate them in the shell right before running, e.g.:
#   export ZAP_AWS_AMZ_DATE=$(date -u +%Y%m%dT%H%M%SZ)
#   export ZAP_AWS_DATE_STAMP=$(date -u +%Y%m%d)
# SigV4 rejects a timestamp skewed more than ~5 minutes, so run promptly.
#
# This demo reads table "Users" with key id="alice" (edit below). The key is an
# ordinary dict and Content-Length is computed by the SDK, so there is nothing
# to keep in sync by hand.

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
    if not need("ZAP_AWS_AMZ_DATE"):
        return
    if not need("ZAP_AWS_DATE_STAMP"):
        return

    auto creds = credentials_from_env()
    auto region = os.getenv("AWS_REGION")
    auto amz_date = os.getenv("ZAP_AWS_AMZ_DATE")
    auto date_stamp = os.getenv("ZAP_AWS_DATE_STAMP")

    auto table = "Users"
    auto req = get_item_request(
        creds,
        region,
        table,
        {"id": "alice"},
        amz_date,
        date_stamp,
    )
    auto host = regional_host("dynamodb", region)
    print("--- request ---")
    print(req)
    print("--- response ---")
    print(send_https(host, req))
