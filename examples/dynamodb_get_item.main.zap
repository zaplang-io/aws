# Live example: DynamoDB GetItem against real AWS, through standard retry mode.
#
# Bundle + run:
#   tools/zrun.sh src/aws/core.zap src/aws/endpoints.zap src/aws/retry.zap \
#       src/aws/dynamodb.zap examples/dynamodb_get_item.main.zap
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
# This demo reads table "Users" with key id="alice" (edit below) and sends it
# through aws.retry's `retry_send`: each attempt re-signs with a fresh timestamp
# and a transient/throttling reply backs off (full jitter) and retries while the
# attempt cap and per-client retry-quota allow. A non-2xx final reply surfaces a
# typed error via aws.core.

import aws_core.core
import aws_core.dynamodb
import aws_core.endpoints
import aws_core.retry
import os

def need(str name) -> bool:
    if os.hasenv(name):
        return True
    print("missing required env var: " + name)
    return False

# One full GetItem attempt: sign with the current UTC time and send. Handing
# this to `retry_send` as the per-attempt closure is what makes each retry use a
# fresh SigV4 timestamp.
def ddb_get_item_once(
    core.Credentials creds,
    str region,
    str table,
    str host,
) -> core.Response:
    auto t = core.signing_time_now()
    auto req = dynamodb.get_item_request(
        creds,
        region,
        table,
        {"id": "alice"},
        t.amz_date,
        t.date_stamp,
    )
    return core.send(host, req)

def main():
    if not need("AWS_ACCESS_KEY_ID"):
        return
    if not need("AWS_SECRET_ACCESS_KEY"):
        return
    if not need("AWS_REGION"):
        return

    auto creds = core.credentials_from_env()
    auto region = os.getenv("AWS_REGION")
    auto table = "Users"
    auto host = endpoints.regional_host("dynamodb", region)

    # Show one signed request for illustration.
    auto t = core.signing_time_now()
    print("--- request ---")
    print(
        dynamodb.get_item_request(
            creds,
            region,
            table,
            {"id": "alice"},
            t.amz_date,
            t.date_stamp,
        ),
    )

    # Send through standard retry mode (shared per-client quota bucket).
    auto quota = retry.new_retry_quota()
    fn() -> core.Response attempt = lambda: ddb_get_item_once(creds, region, table, host)
    auto outcome = retry.retry_send(retry.standard_retry_config(), quota, attempt)

    print("--- response ---")
    print("status: " + str(outcome.response.status))
    print("attempts: " + str(outcome.attempts))
    print(outcome.response.body)
    if outcome.error.is_some():
        auto e = outcome.error.unwrap()
        print("error: " + e.code + " — " + e.message)
