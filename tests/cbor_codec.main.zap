# Offline smithy-rpc-v2-cbor codec test (zaplang-io/zap#428, part 1). Exercises
# the aws.cbor codec end to end with no live AWS calls:
#   * canonical CBOR encoding of every value-model kind — integers (the 1/2/3/5
#     byte forms + negatives), bool, null, text, blob, double/float, timestamp
#     (tag 1) — byte-checked (hex) against botocore's RpcV2CBORSerializer output;
#   * a hand-rolled struct (map keyed by member name, insertion order, nested
#     list/map/blob/timestamp) and two representative ops from the 25 cbor-only
#     services — CloudWatch PutMetricData (query→cbor upstream) and Translate
#     TranslateText — byte-checked against botocore;
#   * request framing — the /service/{Svc}/operation/{Op} path and the
#     smithy-protocol / Accept / Content-Type headers;
#   * a signed request (SigV4 over the CBOR body via aws.cbor.cbor_signature,
#     reusing core's primitives) — the content hash + signature are deterministic
#     under the pinned AWS example credentials/timestamp;
#   * response decode — the CBOR body decoded back to the value tree and read via
#     the module accessors;
#   * error dispatch — a CBOR error map's `__type` / `message` surfaced as an
#     aws.core.AwsError.
#
# Fixed credentials + timestamp (AWS's published SigV4 example values) make the
# signed output fully deterministic, so tests/expected/cbor_codec.expected pins
# the exact bytes; the CBOR body hex IS the ORACLE the aws-codegen cbor emitter
# (#428 part 2, deferred) will byte-diff its generated output against, and
# tools/verify_vectors.py re-derives this whole fixture from an independent
# pure-Python canonical-CBOR encoder.

import aws_core.core
import aws_core.cbor
import crypto
import hex

def main():
    # --- 1. primitives: byte-checked against botocore ------------------------
    print("### primitives ###")
    print("int 0: " + hex.encode(cbor.cbor_encode(cbor.cbor_int(0))))
    print("int 23: " + hex.encode(cbor.cbor_encode(cbor.cbor_int(23))))
    print("int 24: " + hex.encode(cbor.cbor_encode(cbor.cbor_int(24))))
    print("int 255: " + hex.encode(cbor.cbor_encode(cbor.cbor_int(255))))
    print("int 256: " + hex.encode(cbor.cbor_encode(cbor.cbor_int(256))))
    print("int 1000000: " + hex.encode(cbor.cbor_encode(cbor.cbor_int(1000000))))
    print("int -1: " + hex.encode(cbor.cbor_encode(cbor.cbor_int(0 - 1))))
    print("int -500: " + hex.encode(cbor.cbor_encode(cbor.cbor_int(0 - 500))))
    print("bool true: " + hex.encode(cbor.cbor_encode(cbor.cbor_bool(True))))
    print("bool false: " + hex.encode(cbor.cbor_encode(cbor.cbor_bool(False))))
    print("null: " + hex.encode(cbor.cbor_encode(cbor.cbor_null())))
    print("text hi: " + hex.encode(cbor.cbor_encode(cbor.cbor_text("hi"))))
    print(
        "blob 010203: " + hex.encode(cbor.cbor_encode(cbor.cbor_blob(bytes([1, 2, 3])))),
    )
    print("double 1.5: " + hex.encode(cbor.cbor_encode(cbor.cbor_double(1.5))))
    print("double 100.0: " + hex.encode(cbor.cbor_encode(cbor.cbor_double(100.0))))
    print("double -3.25: " + hex.encode(cbor.cbor_encode(cbor.cbor_double(0.0 - 3.25))))
    print("single 1.5: " + hex.encode(cbor.cbor_encode(cbor.cbor_single(1.5))))
    print(
        "timestamp 1577836800: " + hex.encode(cbor.cbor_encode(cbor.cbor_timestamp(1577836800))),
    )

    # --- 2. hand-rolled struct (nested list/map/blob/timestamp) --------------
    print("### struct ###")
    list[str] s_keys = [
        "Name",
        "Count",
        "Ratio",
        "Flag",
        "When",
        "Tags",
        "Meta",
        "Data",
        "Neg",
    ]
    list[cbor.CborValue] tag_items = [cbor.cbor_text("a"), cbor.cbor_text("bb")]
    list[str] meta_keys = ["k"]
    list[cbor.CborValue] meta_vals = [cbor.cbor_text("v")]
    list[cbor.CborValue] s_vals = [
        cbor.cbor_text("hi"),
        cbor.cbor_int(3),
        cbor.cbor_double(1.5),
        cbor.cbor_bool(True),
        cbor.cbor_timestamp(1577836800),
        cbor.cbor_list(tag_items),
        cbor.cbor_map(meta_keys, meta_vals),
        cbor.cbor_blob(bytes([1, 2, 3])),
        cbor.cbor_int(0 - 500),
    ]
    auto struct_v = cbor.cbor_map(s_keys, s_vals)
    auto struct_bytes = cbor.cbor_encode(struct_v)
    print(hex.encode(struct_bytes))

    # --- 3. CloudWatch PutMetricData (representative cbor-only service) -------
    print("### cloudwatch PutMetricData ###")
    list[str] md1_keys = ["MetricName", "Value", "Unit", "StorageResolution"]
    list[cbor.CborValue] md1_vals = [
        cbor.cbor_text("Latency"),
        cbor.cbor_double(100.0),
        cbor.cbor_text("Milliseconds"),
        cbor.cbor_int(1),
    ]
    list[str] md2_keys = ["MetricName", "Value", "Unit"]
    list[cbor.CborValue] md2_vals = [
        cbor.cbor_text("Errors"),
        cbor.cbor_double(0.5),
        cbor.cbor_text("Count"),
    ]
    list[cbor.CborValue] md_items = [
        cbor.cbor_map(md1_keys, md1_vals),
        cbor.cbor_map(md2_keys, md2_vals),
    ]
    list[str] cw_keys = ["Namespace", "MetricData"]
    list[cbor.CborValue] cw_vals = [
        cbor.cbor_text("MyApp/Prod"),
        cbor.cbor_list(md_items),
    ]
    auto cw = cbor.cbor_map(cw_keys, cw_vals)
    auto cw_bytes = cbor.cbor_encode(cw)
    print(hex.encode(cw_bytes))

    # --- 4. Translate TranslateText (representative cbor-only service) --------
    print("### translate TranslateText ###")
    list[str] tr_keys = ["Text", "SourceLanguageCode", "TargetLanguageCode"]
    list[cbor.CborValue] tr_vals = [
        cbor.cbor_text("Hello, world"),
        cbor.cbor_text("en"),
        cbor.cbor_text("es"),
    ]
    print(hex.encode(cbor.cbor_encode(cbor.cbor_map(tr_keys, tr_vals))))

    # --- 5. empty struct -----------------------------------------------------
    print("### empty struct ###")
    list[str] e_keys = []
    list[cbor.CborValue] e_vals = []
    print(hex.encode(cbor.cbor_encode(cbor.cbor_map(e_keys, e_vals))))

    # --- 6. framing ----------------------------------------------------------
    print("### framing ###")
    auto creds = core.credentials(
        "AKIDEXAMPLE",
        "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    )
    auto host = "monitoring.us-east-1.amazonaws.com"
    auto req = cbor.cbor_build_request(
        "monitoring",
        "us-east-1",
        host,
        "CloudWatch",
        "PutMetricData",
        cw_bytes,
        "20150830T123600Z",
    )
    print("path=" + req.path)
    Optional[str] acc = req.headers.get("accept")
    print("accept=" + acc.unwrap_or(""))
    Optional[str] proto = req.headers.get("smithy-protocol")
    print("smithy-protocol=" + proto.unwrap_or(""))
    Optional[str] ctype = req.headers.get("content-type")
    print("content-type=" + ctype.unwrap_or(""))

    # --- 7. signed request (deterministic under the pinned example values) ---
    print("### signed ###")
    print("content-sha256=" + crypto.sha256(cw_bytes))
    print(
        "signature=" + cbor.cbor_signature(creds, req, cw_bytes, "20150830T123600Z", "20150830"),
    )
    print("signed-headers=" + core.signed_headers(req.headers))

    # --- 8. response decode --------------------------------------------------
    print("### decode ###")
    auto root = cbor.cbor_decode(struct_bytes)
    Optional[cbor.CborValue] nv = cbor.cbor_map_get(root, "Name")
    print("Name=" + cbor.cbor_as_text(nv.unwrap()))
    Optional[cbor.CborValue] cv = cbor.cbor_map_get(root, "Count")
    print("Count=" + str(cbor.cbor_as_int(cv.unwrap())))
    Optional[cbor.CborValue] fv = cbor.cbor_map_get(root, "Flag")
    if cbor.cbor_as_bool(fv.unwrap()):
        print("Flag=true")
    else:
        print("Flag=false")
    Optional[cbor.CborValue] tv = cbor.cbor_map_get(root, "Tags")
    print("Tags.len=" + str(cbor.cbor_list_len(tv.unwrap())))
    Optional[cbor.CborValue] wv = cbor.cbor_map_get(root, "When")
    print("When=" + str(cbor.cbor_as_timestamp(wv.unwrap())))

    # --- 9. error dispatch (CBOR __type / message) ---------------------------
    print("### error ###")
    list[str] err_keys = ["__type", "message"]
    list[cbor.CborValue] err_vals = [
        cbor.cbor_text("com.amazonaws.cloudwatch#InvalidParameterValueException"),
        cbor.cbor_text("bad metric value"),
    ]
    auto err_bytes = cbor.cbor_encode(cbor.cbor_map(err_keys, err_vals))
    print("error-body=" + hex.encode(err_bytes))
    Optional[core.AwsError] e = cbor.cbor_error(400, err_bytes)
    auto ev = e.unwrap_or(core.AwsError(code="<none>", message="<none>", status=0))
    print("code=" + ev.code)
    print("message=" + ev.message)
    print("status=" + str(ev.status))
