# Offline rest-json + HTTP-binding test. Exercises the protocol-agnostic binding
# layer (aws.binding) and the rest-json codec (aws.restjson) end to end with no
# live AWS calls:
#   * a URI-label + greedy-label + query + header + JSON-document request, built
#     through the binding layer and SigV4-signed — printed verbatim (golden);
#   * a raw-payload (httpPayload) member request;
#   * httpPrefixHeaders (an x-amz-meta-* map) on a request;
#   * response binding — status + headers -> output members, JSON body decoded
#     with @derive(Json), and prefix-headers collected back into a map;
#   * restJson1 error dispatch — code from x-amzn-errortype, message from body.
#
# Fixed credentials + timestamp (AWS's published example values) make the signed
# output fully deterministic, so tests/expected/restjson_binding.expected pins
# the exact request bytes and any drift in binding/signing fails the diff. The
# core SigV4 signer is unchanged and is proven byte-for-byte elsewhere
# (tests/sigv4_vectors, tests/service_signing), so this fixture only guards the
# binding/codec layering on top of it.
#
# Run: tools/zrun.sh src/aws/core.zap src/aws/endpoints.zap src/aws/binding.zap \
#          src/aws/restjson.zap tests/restjson_binding.main.zap

# A request document (the "document members" serialized into the JSON body).
@derive(Json)
struct PutThingInput:
    str name
    int64 size
    bool active

# A response document (the members carried in the JSON response body).
@derive(Json)
struct PutThingOutput:
    str id
    int64 version

def main():
    auto creds = credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    auto region = "us-east-1"
    auto service = "execute-api"
    auto host = "example.execute-api.us-east-1.amazonaws.com"
    auto amz_date = "20150830T123600Z"
    auto date_stamp = "20150830"

    # --- 1. uri-label + greedy-label + query + header + JSON document ---------
    print("### rest-json PutThing (label+query+header+document) ###")
    auto doc = PutThingInput(name="gadget", size=7, active=True)
    auto b = new_binding("PUT", "/things/{Id}/items/{Path+}")
    dict[str, str] labels = {}
    labels["Id"] = "a b"
    dict[str, str] greedy = {}
    greedy["Path"] = "deep/key path"
    dict[str, str] query = {}
    query["mode"] = "fast"
    query["q"] = "a b"
    dict[str, str] headers = {}
    headers["x-custom"] = "hello"
    auto plan = HttpBinding(
        method="PUT",
        path_template="/things/{Id}/items/{Path+}",
        labels=labels,
        greedy_labels=greedy,
        query=query,
        headers=headers,
        prefix_header_prefix="",
        prefix_headers={},
        payload_kind=PayloadKind.Empty,
        body="",
        content_type="",
    )
    auto plan_doc = rest_json_document(plan, doc.to_json())
    print(rest_json_sign(creds, plan_doc, service, region, host, amz_date, date_stamp))

    # --- 2. raw-payload (httpPayload) member ----------------------------------
    print("### rest-json PutRaw (raw payload member) ###")
    dict[str, str] raw_labels = {}
    raw_labels["Id"] = "blob1"
    auto rb = HttpBinding(
        method="PUT",
        path_template="/raw/{Id}",
        labels=raw_labels,
        greedy_labels={},
        query={},
        headers={},
        prefix_header_prefix="",
        prefix_headers={},
        payload_kind=PayloadKind.Empty,
        body="",
        content_type="",
    )
    auto rb_raw = rest_json_raw_payload(
        rb,
        "raw-payload-bytes",
        "application/octet-stream",
    )
    print(rest_json_sign(creds, rb_raw, service, region, host, amz_date, date_stamp))

    # --- 3. httpPrefixHeaders (x-amz-meta-* map) ------------------------------
    print("### rest-json PutMeta (prefix headers) ###")
    dict[str, str] meta = {}
    meta["owner"] = "alice"
    meta["team"] = "zap"
    auto mb = HttpBinding(
        method="PUT",
        path_template="/meta",
        labels={},
        greedy_labels={},
        query={},
        headers={},
        prefix_header_prefix="x-amz-meta-",
        prefix_headers=meta,
        payload_kind=PayloadKind.Empty,
        body="",
        content_type="",
    )
    auto mb_doc = rest_json_document(mb, "{}")
    print(rest_json_sign(creds, mb_doc, service, region, host, amz_date, date_stamp))

    # --- 4. response binding: status + headers -> members, JSON body decode ---
    print("### rest-json response binding ###")
    auto ok_raw = "HTTP/1.1 200 OK\r\n" + "content-type: application/json\r\n" + "x-request-id: req-123\r\n" + "x-amz-meta-owner: alice\r\n" + "x-amz-meta-team: zap\r\n" + "\r\n" + "{\"id\":\"thing-9\",\"version\":3}"
    auto resp = parse_response(ok_raw)
    print("status=" + str(bound_status(resp)))
    Optional[str] rid = bound_header(resp, "X-Request-Id")
    print("x-request-id=" + rid.unwrap_or("<none>"))
    auto out = PutThingOutput.from_json(rest_json_body(resp))
    print("out.id=" + out.id)
    print("out.version=" + str(out.version))
    auto collected = collect_prefix_headers(resp, "x-amz-meta-")
    Optional[str] mo = collected.get("owner")
    Optional[str] mt = collected.get("team")
    print("meta.owner=" + mo.unwrap_or("<none>"))
    print("meta.team=" + mt.unwrap_or("<none>"))

    # --- 5. restJson1 error dispatch ------------------------------------------
    print("### rest-json error dispatch ###")
    auto err_raw = "HTTP/1.1 400 Bad Request\r\n" + "content-type: application/json\r\n" + "x-amzn-errortype: ResourceNotFoundException:http://internal.amazon.com/coral/\r\n" + "\r\n" + "{\"message\":\"no such thing\"}"
    auto err_resp = parse_response(err_raw)
    Optional[AwsError] e = rest_json_error(err_resp)
    auto ev = e.unwrap_or(AwsError(code="<none>", message="<none>", status=0))
    print("code=" + ev.code)
    print("message=" + ev.message)
    print("status=" + str(ev.status))

    # Error code carried only in the body as a namespaced __type.
    auto err2_raw = "HTTP/1.1 500 Internal Server Error\r\n" + "content-type: application/json\r\n" + "\r\n" + "{\"__type\":\"com.amazonaws.foo#InternalFailure\",\"Message\":\"boom\"}"
    auto err2 = parse_response(err2_raw)
    Optional[AwsError] e2 = rest_json_error(err2)
    auto ev2 = e2.unwrap_or(AwsError(code="<none>", message="<none>", status=0))
    print("code2=" + ev2.code)
    print("message2=" + ev2.message)

    # A 2xx response yields no error.
    Optional[AwsError] none_err = rest_json_error(resp)
    if none_err.is_none():
        print("ok-no-error")
