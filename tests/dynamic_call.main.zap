# Offline dynamic-call escape-hatch test (#365) — proves `aws_core.dynamic` signs
# BYTE-IDENTICALLY to the generated/codec path. For three representative shapes it
# builds the signed HTTP/1.1 request two ways — once through the normal codec/
# oracle path, once through the dynamic `call()` signer — and asserts the bytes
# are equal:
#   * awsJson (DynamoDB GetItem), Decoded path  → vs aws_core.dynamodb / core.sign_request
#   * query   (STS GetCallerIdentity), Decoded  → vs aws_core.query / core.sign_request
#   * CBOR-style op, PreEncoded path            → vs aws_core.binding.binding_sign
#
# The signatures of the codec paths are themselves pinned against botocore in
# tests/service_signing.expected and re-derived by tools/verify_vectors.py, so
# "identical to the codec path" transitively means "identical to botocore". Fixed
# AWS example credentials + timestamp make the output deterministic. No live calls.
#
# Run: tools/run-tests.sh (case `dynamic_call`).

import aws_core.core
import aws_core.dynamic
import aws_core.dynamodb
import aws_core.query
import aws_core.binding
import aws_core.endpoints

# Print "<label>: yes" when the two signed requests are byte-identical, else
# "<label>: no" (which fails the pinned diff — the gate working).
def report(str label, str oracle, str got):
    if got == oracle:
        print(label + ": yes")
    else:
        print(label + ": no")

def main():
    auto creds = core.credentials(
        "AKIDEXAMPLE",
        "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    )
    auto region = "us-east-1"
    auto amz_date = "20150830T123600Z"
    auto date_stamp = "20150830"

    # --- awsJson (DynamoDB GetItem), Decoded (core.sign_request) ---------------
    # Oracle: the generated-equivalent client path.
    auto aws_oracle = dynamodb.get_item_request(
        creds,
        region,
        "Users",
        {"id": "alice"},
        amz_date,
        date_stamp,
    )
    # Escape hatch: caller supplies the awsJson wire details (Content-Type +
    # X-Amz-Target + the serialized JSON body); dynamic injects host/date/sha and
    # signs via core.sign_request.
    auto aws_body = dynamodb.get_item_body("Users", {"id": "alice"})
    dict[str, str] aws_h = {}
    aws_h["content-type"] = "application/x-amz-json-1.0"
    aws_h["x-amz-target"] = "DynamoDB_20120810.GetItem"
    auto aws_req = dynamic.dynamic_request(
        "POST",
        "dynamodb",
        region,
        headers=aws_h,
        body=aws_body,
    )
    auto aws_got = dynamic.sign_dynamic(creds, aws_req, amz_date, date_stamp)
    report("awsJson Decoded identical", aws_oracle, aws_got)

    # --- query (STS GetCallerIdentity), Decoded (core.sign_request) ------------
    auto q_host = endpoints.regional_host("sts", region)
    auto q_params = query.query_params("GetCallerIdentity", "2011-06-15")
    auto q_oracle = query.query_sign(
        creds,
        "sts",
        region,
        q_host,
        q_params,
        amz_date,
        date_stamp,
    )
    auto q_body = query.query_encode(q_params)
    dict[str, str] q_h = {}
    q_h["content-type"] = query.query_content_type()
    auto q_req = dynamic.dynamic_request(
        "POST",
        "sts",
        region,
        headers=q_h,
        body=q_body,
        host=q_host,
    )
    auto q_got = dynamic.sign_dynamic(creds, q_req, amz_date, date_stamp)
    report("query Decoded identical", q_oracle, q_got)

    # --- CBOR-style op, PreEncoded (binding.binding_sign) ----------------------
    # The smithy-rpc-v2-cbor services have no codec yet (#428); the escape hatch
    # is how they are reachable. A CBOR op POSTs a pre-encoded path with an
    # application/cbor body. Oracle: a core.Request carrying the full signed-header
    # set, signed with the binding signer directly.
    auto c_host = endpoints.regional_host("example", region)
    auto c_path = "/service/Example/operation/DoThing"
    auto c_body = "cbor-bytes"
    dict[str, str] c_oracle_h = {}
    c_oracle_h["smithy-protocol"] = "rpc-v2-cbor"
    c_oracle_h["content-type"] = "application/cbor"
    c_oracle_h["host"] = c_host
    c_oracle_h["x-amz-date"] = amz_date
    c_oracle_h["x-amz-content-sha256"] = core.payload_hash(c_body)
    dict[str, str] c_empty = {}
    auto c_oracle_req = core.Request(
        method="POST",
        service="example",
        region=region,
        host=c_host,
        path=c_path,
        query=c_empty,
        headers=c_oracle_h,
        body=c_body,
    )
    auto c_oracle = binding.binding_sign(creds, c_oracle_req, amz_date, date_stamp)
    # Escape hatch: caller supplies only the protocol headers + pre-encoded path.
    dict[str, str] c_h = {}
    c_h["smithy-protocol"] = "rpc-v2-cbor"
    c_h["content-type"] = "application/cbor"
    auto c_req = dynamic.dynamic_request(
        "POST",
        "example",
        region,
        headers=c_h,
        body=c_body,
        path=c_path,
        host=c_host,
        path_mode=dynamic.PathMode.PreEncoded,
    )
    auto c_got = dynamic.sign_dynamic(creds, c_req, amz_date, date_stamp)
    report("cbor PreEncoded identical", c_oracle, c_got)
