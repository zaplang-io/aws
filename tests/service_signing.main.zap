# Offline service-signing test — builds complete, SigV4-signed HTTP requests for
# DynamoDB and S3 through aws.dynamodb / aws.s3 and prints them verbatim. The
# signatures are independently reproducible with botocore / any SigV4 oracle,
# and tests/expected/service_signing.expected pins the exact request bytes, so
# any drift in request assembly or signing fails the diff. No live AWS calls.
#
# Fixed inputs use AWS's published example credentials + timestamp so the output
# is fully deterministic.
#
# Run: tools/zrun.sh src/aws/core.zap src/aws/dynamodb.zap src/aws/s3.zap \
#          tests/service_signing.main.zap

def main():
    auto creds = credentials(
        "AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    )
    auto region = "us-east-1"
    auto amz_date = "20150830T123600Z"
    auto date_stamp = "20150830"

    # DynamoDB GetItem on table "Users", key id="alice". The body is 48 bytes.
    print("### dynamodb.GetItem ###")
    auto ddb = get_item_request(
        creds, region, "Users", "id", "alice", amz_date, date_stamp, "48"
    )
    print(ddb)

    # S3 GetObject my-bucket/hello.txt.
    print("### s3.GetObject ###")
    auto s3get = get_object_request(
        creds, region, "my-bucket", "hello.txt", amz_date, date_stamp
    )
    print(s3get)

    # S3 PutObject my-bucket/hello.txt with body "hi" (2 bytes).
    print("### s3.PutObject ###")
    auto s3put = put_object_request(
        creds, region, "my-bucket", "hello.txt", "hi", "2", amz_date,
        date_stamp,
    )
    print(s3put)
