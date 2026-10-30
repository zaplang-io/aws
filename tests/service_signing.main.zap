# Offline service-signing test — builds complete, SigV4-signed HTTP requests for
# DynamoDB and S3 through aws.dynamodb / aws.s3 and prints them verbatim. The
# signatures are independently reproducible with botocore / any SigV4 oracle,
# and tests/expected/service_signing.expected pins the exact request bytes, so
# any drift in request assembly or signing fails the diff. No live AWS calls.
#
# Fixed inputs use AWS's published example credentials + timestamp so the output
# is fully deterministic.
#
# Besides the plain operations, this exercises the ergonomic API shapes:
#   * S3 PutObject with a content_type + a metadata dict (signed x-amz-meta-*).
#   * DynamoDB PutItem from string + numeric attribute dicts.
#   * S3 ListObjectsV2 with prefix + max_keys turned into a canonical query.
#
# Run: tools/zrun.sh src/aws/core.zap src/aws/endpoints.zap src/aws/dynamodb.zap \
#          src/aws/s3.zap tests/service_signing.main.zap

import aws_core.core
import aws_core.dynamodb
import aws_core.s3

def main():
    auto creds = core.credentials(
        "AKIDEXAMPLE",
        "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    )
    auto region = "us-east-1"
    auto amz_date = "20150830T123600Z"
    auto date_stamp = "20150830"

    # DynamoDB GetItem on table "Users", key id="alice".
    print("### dynamodb.GetItem ###")
    print(
        dynamodb.get_item_request(
            creds,
            region,
            "Users",
            {"id": "alice"},
            amz_date,
            date_stamp,
        ),
    )

    # DynamoDB PutItem: string attrs {id, name} + numeric attr {age}.
    print("### dynamodb.PutItem ###")
    print(
        dynamodb.put_item_request(
            creds,
            region,
            "Users",
            {"id": "alice", "name": "Alice"},
            amz_date,
            date_stamp,
            numbers={"age": "30"},
        ),
    )

    # S3 GetObject my-bucket/hello.txt.
    print("### s3.GetObject ###")
    print(
        s3.get_object_request(
            creds,
            region,
            "my-bucket",
            "hello.txt",
            amz_date,
            date_stamp,
        ),
    )

    # S3 ListObjectsV2 with prefix + max_keys (canonical query from a dict).
    print("### s3.ListObjectsV2 ###")
    print(
        s3.list_objects_v2_request(
            creds,
            region,
            "my-bucket",
            amz_date,
            date_stamp,
            prefix="photos/",
            max_keys=10,
        ),
    )

    # S3 PutObject my-bucket/hello.txt with body "hi" (default content type).
    print("### s3.PutObject ###")
    print(
        s3.put_object_request(
            creds,
            region,
            "my-bucket",
            "hello.txt",
            "hi",
            amz_date,
            date_stamp,
        ),
    )

    # S3 PutObject with an explicit content type + object metadata (signed).
    # Kept last: its body ("hi") is non-empty so the pinned output does not end
    # on a blank line (the shell test harness strips trailing newlines).
    print("### s3.PutObject+meta ###")
    print(
        s3.put_object_request(
            creds,
            region,
            "my-bucket",
            "hello.txt",
            "hi",
            amz_date,
            date_stamp,
            content_type="text/plain",
            metadata={"owner": "alice", "team": "zap"},
        ),
    )
