# Offline typed-errors test — exercises aws.errors (the typed error layer, #361)
# and the hand-wired S3 typed-error enum/classifier in aws.s3, deterministically,
# and pins the output in tests/expected/typed_errors.expected. No live AWS calls:
# every case feeds a canned `core.Response` (a known error body/header) through
# `errors.service_error_from_response` → `s3.s3_error_kind` → `s3.s3_error_name`.
#
# What it proves:
#   * CLASSIFY — a rest-xml `<Error><Code>` body, an awsJson namespaced `__type`,
#     and a rest-json `x-amzn-errortype` header each map to the right S3ErrorKind.
#   * NORMALIZE — "com.amazonaws.s3#AccessDenied" and "EntityTooLarge:" strip to
#     the bare shape name before matching.
#   * UNKNOWN FALLBACK — an unmodeled code ("InvalidArgument") lands in
#     `Unknown(code)`, still carrying the code (forward compatibility).
#   * CARRIER — `AwsServiceError` surfaces the normalized code, request id (from
#     either request-id header), and HTTP status; `format_error` renders them.
#   * RAISE BRIDGE — `check_response` raises on a fault (caught by a single
#     catch-all `except ... as e:` as the formatted message) and does NOT raise on
#     a 2xx response.
#
# Run: tools/run-tests.sh with the aws_core zenv active.

import aws_core.core
import aws_core.errors
import aws_core.s3

# --- canned-response builders ----------------------------------------------

# A rest-xml S3 error body: <Error><Code>..</Code><Message>..</Message></Error>.
def xml_error(str code, str message) -> str:
    return "<Error><Code>" + code + "</Code><Message>" + message + "</Message></Error>"

# A rest-xml error response (S3 sends the request id in x-amz-request-id).
def xml_resp(int64 status, str rid, str code, str message) -> core.Response:
    dict[str, str] h = {}
    h["content-type"] = "application/xml"
    h["x-amz-request-id"] = rid
    return core.Response(status=status, headers=h, body=xml_error(code, message))

# An awsJson error response: the shape name in the body `__type`, the request id
# in x-amzn-requestid.
def json_resp(int64 status, str rid, str type_name, str message) -> core.Response:
    dict[str, str] h = {}
    h["x-amzn-requestid"] = rid
    auto body = "{\"__type\":\"" + type_name + "\",\"message\":\"" + message + "\"}"
    return core.Response(status=status, headers=h, body=body)

# A rest-json error response whose code is ONLY in the x-amzn-errortype header
# (an empty JSON body), exercising the header fallback.
def header_resp(int64 status, str errtype) -> core.Response:
    dict[str, str] h = {}
    h["x-amzn-errortype"] = errtype
    return core.Response(status=status, headers=h, body="{}")

# Classify a response to its S3 error name, or "<none>" on success.
def classify(core.Response r) -> str:
    Optional[errors.AwsServiceError] e = errors.service_error_from_response(r)
    if e.is_none():
        return "<none>"
    return s3.s3_error_name(s3.s3_error_kind(e.unwrap().code))

def main():
    print("== classify ==")
    auto nsk = xml_resp(404, "ABC123", "NoSuchKey", "The specified key does not exist.")
    auto nsb = xml_resp(404, "B1", "NoSuchBucket", "no bucket")
    auto ad = json_resp(403, "J1", "com.amazonaws.s3#AccessDenied", "denied")
    auto etl = header_resp(400, "EntityTooLarge:")
    auto ukn = xml_resp(400, "U1", "InvalidArgument", "bad arg")
    print("rest-xml NoSuchKey -> " + classify(nsk))
    print("rest-xml NoSuchBucket -> " + classify(nsb))
    print("awsJson #AccessDenied -> " + classify(ad))
    print("rest-json header EntityTooLarge -> " + classify(etl))
    print("rest-xml InvalidArgument -> " + classify(ukn))

    print("== carrier ==")
    Optional[errors.AwsServiceError] ce = errors.service_error_from_response(nsk)
    auto c = ce.unwrap()
    auto status = str(c.http_status)
    print("code=" + c.code + " request-id=" + c.request_id + " status=" + status)
    print("format: " + errors.format_error(c))

    print("== success ==")
    dict[str, str] oh = {}
    auto ok = core.Response(status=200, headers=oh, body="")
    Optional[errors.AwsServiceError] none_e = errors.service_error_from_response(ok)
    print("error present: " + str(none_e.is_some()))
    auto raised_ok = False
    try:
        errors.check_response(ok)
    except Exception as e:
        raised_ok = True
    print("check_response raised on 200: " + str(raised_ok))

    print("== raise bridge ==")
    try:
        errors.check_response(nsk)
        print("no raise")
    except Exception as e:
        print("caught: " + e)
