# Offline rest-xml codec test. Exercises the rest-xml protocol (aws.restxml) over
# the protocol-agnostic HTTP binding layer (aws.binding), end to end, with no live
# AWS calls:
#   * XML document serialization honoring the AWS shape traits — a default
#     xmlNamespace on the root, an xmlAttribute, a nested structure, a wrapped
#     list, and a flattened (xmlFlattened) list — byte-checked against the
#     known-correct canonical payload;
#   * a signed S3 PUT request carrying that XML body (binding integration: URI
#     label encoding + the XML Content-Type + SigV4 via binding_sign);
#   * a prefixed-namespace root plus text escaping (& < >);
#   * response parsing — the XML body parsed back and read with the inverse
#     helpers (scalars, attribute, wrapped list, flattened list) and a
#     dumps(parse(body)) == body round-trip;
#   * rest-xml error dispatch — both the bare <Error> document S3 emits and the
#     <ErrorResponse><Error>…</Error></ErrorResponse> wrapper the other rest-xml
#     services use, plus a 2xx no-error.
#
# Fixed credentials + timestamp (AWS's published example values) make the signed
# output fully deterministic, so tests/expected/restxml_codec.expected pins the
# exact request bytes and any drift in binding/signing/serialization fails the
# diff. The canonical XML body bytes are the ORACLE the aws-codegen XML emitter
# (#354) byte-diffs its generated output against; the core SigV4 signer is proven
# byte-for-byte elsewhere (tests/sigv4_vectors, tests/service_signing).
#
# Run: tools/zrun.sh src/aws/core.zap src/aws/endpoints.zap src/aws/binding.zap \
#          src/aws/restxml.zap tests/restxml_codec.main.zap

def main():
    auto creds = credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    auto region = "us-east-1"
    auto amz_date = "20150830T123600Z"
    auto date_stamp = "20150830"

    # --- 1. XML document body: namespace + attribute + nested + wrapped + flattened
    print("### rest-xml serialize (namespace+attribute+nested+wrapped+flattened) ###")
    auto root = rest_xml_root_ns("PutThingRequest", "http://example.amazonaws.com/doc/2021-01-01/")
    rest_xml_attribute(root, "version", "2")
    rest_xml_scalar(root, "Name", "gadget")
    auto owner = rest_xml_struct(root, "Owner")
    rest_xml_scalar(owner, "Id", "o-1")
    list[str] tag_vals = ["red", "blue"]
    rest_xml_wrapped_list(root, "Tags", "Tag", tag_vals)
    list[str] alias_vals = ["a1", "a2"]
    rest_xml_flat_list(root, "Alias", alias_vals)
    auto body = rest_xml_serialize(root)
    print(body)

    # --- 2. signed S3 PUT request carrying that body (binding integration) -----
    print("### rest-xml PutThing (S3, signed) ###")
    auto host = "my-bucket.s3.us-east-1.amazonaws.com"
    dict[str, str] labels = {}
    labels["Id"] = "a b"
    auto plan = HttpBinding(
        method="PUT",
        path_template="/thing/{Id}",
        labels=labels,
        greedy_labels={},
        query={},
        headers={},
        prefix_header_prefix="",
        prefix_headers={},
        payload_kind=PayloadKind.Empty,
        body="",
        content_type="",
    )
    auto plan_doc = rest_xml_document(plan, body)
    print(rest_xml_sign(creds, plan_doc, "s3", region, host, amz_date, date_stamp))

    # --- 3. prefixed-namespace root + text escaping (& < >) --------------------
    print("### rest-xml prefixed namespace + escaping ###")
    auto pre = rest_xml_root_prefixed("ChangeSet", "ns", "urn:aws:route53")
    rest_xml_scalar(pre, "Comment", "a < b & c > d")
    print(rest_xml_serialize(pre))

    # --- 4. parse round-trip: read members back with the inverse helpers -------
    print("### rest-xml parse round-trip ###")
    auto resp = parse_response("HTTP/1.1 200 OK\r\n" + "content-type: application/xml\r\n" + "\r\n" + body)
    auto doc = rest_xml_parse(resp)
    print("Name=" + doc.find("Name").unwrap().get_text())
    print("version=" + doc.get_attr("version").unwrap())
    print("Owner.Id=" + doc.find("Owner").unwrap().find("Id").unwrap().get_text())
    auto tags = rest_xml_wrapped_list_values(doc, "Tags", "Tag")
    print("tags=" + str(len(tags)) + ":" + tags[0] + "," + tags[1])
    auto aliases = rest_xml_flat_list_values(doc, "Alias")
    print("alias=" + str(len(aliases)) + ":" + aliases[0] + "," + aliases[1])
    if rest_xml_serialize(doc) == body:
        print("roundtrip-ok")

    # --- 5. error dispatch: bare <Error> (S3) and <ErrorResponse> wrapper ------
    print("### rest-xml error dispatch ###")
    auto bare = "HTTP/1.1 404 Not Found\r\n" + "content-type: application/xml\r\n" + "\r\n" + "<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message><RequestId>REQ1</RequestId></Error>"
    auto er1 = rest_xml_error(parse_response(bare))
    auto ev1 = er1.unwrap_or(AwsError(code="<none>", message="<none>", status=0))
    print("code=" + ev1.code)
    print("message=" + ev1.message)
    print("status=" + str(ev1.status))

    auto wrapped = "HTTP/1.1 403 Forbidden\r\n" + "content-type: application/xml\r\n" + "\r\n" + "<ErrorResponse xmlns=\"urn:aws\"><Error><Code>AccessDenied</Code><Message>denied</Message></Error><RequestId>REQ2</RequestId></ErrorResponse>"
    auto er2 = rest_xml_error(parse_response(wrapped))
    auto ev2 = er2.unwrap_or(AwsError(code="<none>", message="<none>", status=0))
    print("code2=" + ev2.code)
    print("message2=" + ev2.message)
    print("status2=" + str(ev2.status))

    # A 2xx response yields no error.
    Optional[AwsError] none_err = rest_xml_error(resp)
    if none_err.is_none():
        print("ok-no-error")
