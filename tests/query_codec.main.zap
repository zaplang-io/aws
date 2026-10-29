# Offline query + ec2 codec test (zaplang-io/zap#353). Exercises the aws.query
# codec end to end with no live AWS calls:
#   * awsQuery request serialization — Action + Version, scalars, a nested
#     structure member, a wrapped list (`Name.member.N`), a flattened list
#     (`Name.N`) and a wrapped map (`Name.entry.N.key/value`) — byte-checked
#     against the known-correct form-urlencoded body, with space percent-encoded
#     to %20;
#   * ec2Query serialization — Capitalized member keys and an always-flattened
#     list (`Name.N`, no `member` segment) — byte-checked;
#   * a signed query request (IAM) carrying the serialized form body (SigV4 via
#     aws.core.sign_request, POST "/", content-type signed);
#   * response parsing — the awsQuery `<…Response><…Result>…<ResponseMetadata>`
#     envelope and the wrapper-less ec2 `<…Response>…<requestId>` envelope, read
#     back with the xml module + the result/request-id helpers;
#   * error dispatch — the awsQuery `<ErrorResponse><Error>` shape and the ec2
#     `<Response><Errors><Error>` shape, plus a 2xx no-error.
#
# Fixed credentials + timestamp (AWS's published SigV4 example values) make the
# signed output fully deterministic, so tests/expected/query_codec.expected pins
# the exact request bytes and any drift in serialization/signing fails the diff.
# The canonical form-encoded body bytes are the ORACLE the aws-codegen query/ec2
# emitter (#354) byte-diffs its generated output against; the core SigV4 signer
# is proven byte-for-byte elsewhere (tests/sigv4_vectors, tests/awsjson_codec).
#
# Run: tools/zrun.sh src/aws/core.zap src/aws/endpoints.zap src/aws/query.zap \
#          tests/query_codec.main.zap

def main():
    auto creds = credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    auto region = "us-east-1"
    auto amz_date = "20150830T123600Z"
    auto date_stamp = "20150830"

    # --- 1. awsQuery serialize: scalars + nested + wrapped list + flat list + map
    print("### query serialize (scalar+nested+wrapped-list+flat-list+map) ###")
    auto p = query_params("CreateThing", "2010-05-08")
    p = query_scalar(p, "Name", "my thing")
    p = query_scalar(p, "Count", "3")
    p = query_scalar(p, query_key("Owner", "Id"), "o-1")
    list[str] tag_vals = ["red", "blue"]
    p = query_list(p, "Tags", "member", tag_vals)
    list[str] alias_vals = ["a1", "a2"]
    p = query_flat_list(p, "Alias", alias_vals)
    list[str] attr_keys = ["k1"]
    list[str] attr_vals = ["v1"]
    p = query_map(p, "Attrs", "key", "value", attr_keys, attr_vals)
    auto body = query_encode(p)
    print(body)

    # --- 2. ec2Query serialize: Capitalized keys + always-flattened list -------
    print("### ec2 serialize (capitalized + flat list) ###")
    auto e = query_params("RunThings", "2016-11-15")
    e = query_scalar(e, "ImageId", "ami-1")
    list[str] sg_vals = ["sg-1", "sg-2"]
    e = query_flat_list(e, "SecurityGroup", sg_vals)
    print(query_encode(e))

    # --- 3. signed query request (IAM) carrying the form body ------------------
    print("### query CreateThing (IAM, signed) ###")
    auto host = "iam.amazonaws.com"
    print(query_sign(creds, "iam", region, host, p, amz_date, date_stamp))

    # --- 4. awsQuery response parse: <…Result> + <ResponseMetadata> ------------
    print("### query response parse ###")
    auto q_body = "<CreateThingResponse><CreateThingResult><Id>t-1</Id><Tags><member>red</member><member>blue</member></Tags></CreateThingResult><ResponseMetadata><RequestId>req-123</RequestId></ResponseMetadata></CreateThingResponse>"
    auto q_raw = "HTTP/1.1 200 OK\r\n" + "content-type: text/xml\r\n" + "\r\n" + q_body
    auto q_resp = parse_response(q_raw)
    auto q_root = query_parse(q_resp)
    auto q_result = query_result(q_root, "CreateThingResult").unwrap()
    print("Id=" + q_result.find("Id").unwrap().get_text())
    auto q_tags = q_result.find("Tags").unwrap().find_all("member")
    auto t0 = q_tags[0].get_text()
    auto t1 = q_tags[1].get_text()
    print("tags=" + str(len(q_tags)) + ":" + t0 + "," + t1)
    print("requestId=" + query_request_id(q_root))

    # --- 5. ec2Query response parse: no Result wrapper, lowercase requestId -----
    print("### ec2 response parse ###")
    auto c_body = "<RunThingsResponse><requestId>ec2-req-9</requestId><instanceId>i-1</instanceId></RunThingsResponse>"
    auto c_raw = "HTTP/1.1 200 OK\r\n" + "content-type: text/xml\r\n" + "\r\n" + c_body
    auto c_resp = parse_response(c_raw)
    auto c_root = query_parse(c_resp)
    auto c_result = ec2_result(c_root)
    print("instanceId=" + c_result.find("instanceId").unwrap().get_text())
    print("requestId=" + ec2_request_id(c_root))

    # --- 6. error dispatch: awsQuery <ErrorResponse> and ec2 <Response><Errors> -
    print("### query error dispatch ###")
    auto q_err = "HTTP/1.1 400 Bad Request\r\n" + "content-type: text/xml\r\n" + "\r\n" + "<ErrorResponse><Error><Type>Sender</Type><Code>InvalidParameterValue</Code><Message>bad param</Message></Error><RequestId>err-req-1</RequestId></ErrorResponse>"
    auto qe = query_error(parse_response(q_err))
    auto qev = qe.unwrap_or(AwsError(code="<none>", message="<none>", status=0))
    print("code=" + qev.code)
    print("message=" + qev.message)
    print("status=" + str(qev.status))

    auto c_err = "HTTP/1.1 400 Bad Request\r\n" + "content-type: text/xml\r\n" + "\r\n" + "<Response><Errors><Error><Code>InvalidInstanceID.NotFound</Code><Message>no instance</Message></Error></Errors><RequestId>ec2-err-1</RequestId></Response>"
    auto ce = ec2_error(parse_response(c_err))
    auto cev = ce.unwrap_or(AwsError(code="<none>", message="<none>", status=0))
    print("code2=" + cev.code)
    print("message2=" + cev.message)
    print("status2=" + str(cev.status))

    # A 2xx response yields no error.
    Optional[AwsError] none_err = query_error(q_resp)
    if none_err.is_none():
        print("ok-no-error")
