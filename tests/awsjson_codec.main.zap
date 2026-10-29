# Offline awsJson codec test (zaplang-io/zap#344). Exercises the aws.awsjson
# codec end to end with no live AWS calls: request serialization (headers + body
# + X-Amz-Target, both protocol versions), response parsing via @derive(Json),
# and __type / X-Amzn-ErrorType error dispatch. The transport is fixtured — canned
# raw HTTP response text is fed through aws.core.parse_response, the same seam the
# TLS transport feeds — so the response path is tested without a socket.
#
# Fixed credentials + timestamp (AWS's published SigV4 example) make the signed
# DescribeTable request fully deterministic; tests/expected/awsjson_codec.expected
# pins the bytes.
#
# Run: tools/zrun.sh src/aws/core.zap src/aws/endpoints.zap src/aws/awsjson.zap \
#          src/aws/dynamodb.zap tests/awsjson_codec.main.zap

def main():
    auto creds = credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    auto region = "us-east-1"
    auto amz_date = "20150830T123600Z"
    auto date_stamp = "20150830"

    # --- request serialization: @derive(Json) input shape through the codec ---
    # DescribeTableInput(TableName="Users").to_json() == {"TableName":"Users"};
    # the full signed request pins headers + body + target + signature.
    print("### DescribeTable request (awsJson 1.0) ###")
    print(describe_table_request(creds, region, "Users", amz_date, date_stamp))

    # --- X-Amz-Target + Content-Type selection (1.0 vs 1.1) ---
    print("### target + content-type ###")
    auto p10 = awsjson_1_0("DynamoDB_20120810", "dynamodb")
    auto p11 = awsjson_1_1("Kinesis_20131202", "kinesis")
    print(awsjson_target(p10, "GetItem"))
    print(p10.content_type)
    print(awsjson_target(p11, "PutRecord"))
    print(p11.content_type)

    # --- response parsing via @derive(Json) (fixtured transport) ---
    # A canned 200 body, parsed by the transport seam then the output shape.
    print("### response parsing ###")
    auto ok_raw = "HTTP/1.1 200 OK\r\ncontent-type: application/x-amz-json-1.0\r\n\r\n{\"Table\":{\"TableName\":\"Users\",\"TableStatus\":\"ACTIVE\",\"ItemCount\":42,\"CreationDateTime\":1.6e9}}"
    auto ok = parse_response(ok_raw)
    print("status: " + str(ok.status))
    auto out = DescribeTableOutput.from_json(ok.body)
    print(out.Table.TableName.unwrap_or("?"))
    print(out.Table.TableStatus.unwrap_or("?"))
    print(str(out.Table.ItemCount.unwrap_or(-1)))

    # --- error dispatch: namespaced __type in the body ---
    print("### error: __type body ###")
    auto err_raw = "HTTP/1.1 400 Bad Request\r\nx-amzn-requestid: req-1\r\n\r\n{\"__type\":\"com.amazonaws.dynamodb.v20120810#ResourceNotFoundException\",\"message\":\"Requested resource not found\"}"
    auto err_resp = parse_response(err_raw)
    Optional[AwsError] e = awsjson_error(err_resp)
    if e.is_some():
        auto ev = e.unwrap()
        print("code: " + ev.code)
        print("message: " + ev.message)
        print("status: " + str(ev.status))

    # --- error dispatch: X-Amzn-ErrorType header (URL-suffixed), no __type ---
    print("### error: errortype header ###")
    auto hdr_raw = "HTTP/1.1 400 Bad Request\r\nx-amzn-errortype: ValidationException:http://internal.amazon.com/coral/\r\n\r\n{\"Message\":\"bad input\"}"
    auto hdr_resp = parse_response(hdr_raw)
    Optional[AwsError] e2 = awsjson_error(hdr_resp)
    if e2.is_some():
        auto ev2 = e2.unwrap()
        print("code: " + ev2.code)
        print("message: " + ev2.message)

    # --- a 2xx response dispatches to no error ---
    print("### success -> no error ###")
    Optional[AwsError] none = awsjson_error(ok)
    if none.is_none():
        print("no error on 2xx")
