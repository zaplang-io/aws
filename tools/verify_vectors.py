#!/usr/bin/env python3
"""Independent SigV4 oracle — recompute the pinned test fixtures from scratch and
diff them against tests/expected/*.expected.

This is the toolchain-free half of CI: it proves the EXPECTED fixtures are the
correct SigV4 outputs (an independent second implementation of the algorithm),
so a regression in the fixtures is caught even on a runner without an LLVM Zap
build. The Zap side (that aws.core actually PRODUCES these bytes) is proven by
tools/run-tests.sh against the real toolchain; see README/CI.

The oracle mirrors aws.core's GENERIC canonicalization: it is given a dict of
headers to sign and lowercases / trims / sorts them itself, exactly as the Zap
code does, rather than hard-coding a pre-sorted header block. If a future change
to aws.core's canonicalization drifts from real SigV4, this independent
implementation disagrees and CI fails.

Uses only the Python standard library (hashlib, hmac, urllib.parse.quote).
"""
import hashlib
import hmac
import os
import re
import struct
import sys
from urllib.parse import quote

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXP = os.path.join(ROOT, "tests", "expected")

SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
ACCESS = "AKIDEXAMPLE"
REGION = "us-east-1"
AMZ = "20150830T123600Z"
DS = "20150830"


def sha(s):
    return hashlib.sha256(s.encode()).hexdigest()


def signing_key(secret, ds, region, svc):
    k = hmac.new(("AWS4" + secret).encode(), ds.encode(), hashlib.sha256).digest()
    k = hmac.new(k, region.encode(), hashlib.sha256).digest()
    k = hmac.new(k, svc.encode(), hashlib.sha256).digest()
    return hmac.new(k, b"aws4_request", hashlib.sha256).digest()


# --- generic canonicalization (mirrors aws.core) ---------------------------

def canonical_headers(headers):
    out = ""
    for name in sorted(headers):
        out += name.lower() + ":" + headers[name].strip() + "\n"
    return out


def signed_headers(headers):
    return ";".join(sorted(n.lower() for n in headers))


# SigV4 URI-encode: RFC-3986 unreserved pass through, every other byte -> %XX
# uppercase. `slash_safe` keeps "/" as the path separator. Mirrors url.quote /
# url.quote_path and botocore's percent_encode (safe='-_.~', '/' added for a
# path).
def uri_encode(s, slash_safe):
    return quote(s, safe="/-_.~" if slash_safe else "-_.~")


# CanonicalURI: single-encode for S3 (path normalization disabled), double for
# every other service — mirrors aws.core.canonical_uri.
def canonical_uri(path, service):
    enc = uri_encode(path, True)
    if service != "s3":
        enc = uri_encode(enc, True)
    return enc


# CanonicalQueryString: each key/value percent-encoded, pairs sorted by encoded
# key then value — mirrors aws.core.canonical_query (url.canonical_query). A
# reserved char in a value (e.g. "/" in an S3 prefix) becomes %2F.
def canonical_query(params):
    pairs = sorted((uri_encode(k, False), uri_encode(str(v), False))
                   for k, v in params.items())
    return "&".join(f"{k}={v}" for k, v in pairs)


def sign_request(service, method, host, path, query, body, payload_sha,
                 headers):
    """Build the full HTTP/1.1 request text exactly as aws.core.sign_request.

    `path` is the raw path and `query` the already-canonical query string (the
    callers build it with canonical_query). The canonical request uses the
    percent-encoded canonical URI; the wire request line uses the single-encoded
    path, matching aws.core.wire_path.
    """
    ch = canonical_headers(headers)
    sh = signed_headers(headers)
    cu = canonical_uri(path, service)
    creq = f"{method}\n{cu}\n{query}\n{ch}\n{sh}\n{payload_sha}"
    scope = f"{DS}/{REGION}/{service}/aws4_request"
    sts = f"AWS4-HMAC-SHA256\n{AMZ}\n{scope}\n{sha(creq)}"
    sig = hmac.new(signing_key(SECRET, DS, REGION, service),
                   sts.encode(), hashlib.sha256).hexdigest()
    auth = (f"AWS4-HMAC-SHA256 Credential={ACCESS}/{scope}, "
            f"SignedHeaders={sh}, Signature={sig}")
    wire = "".join(f"{n.lower()}: {headers[n]}\r\n" for n in sorted(headers))
    wire += f"content-length: {len(body)}\r\n"
    wire += f"authorization: {auth}\r\n"
    wire_target = uri_encode(path, True)
    target = wire_target if not query else f"{wire_target}?{query}"
    return (f"{method} {target} HTTP/1.1\r\n{wire}"
            f"Connection: close\r\n\r\n{body}")


# --- the AWS published SigV4 worked example (unchanged, service "iam") ------

def sigv4_vectors():
    body_hash = sha("")
    headers = {
        "content-type": "application/x-www-form-urlencoded; charset=utf-8",
        "host": "iam.amazonaws.com",
        "x-amz-date": AMZ,
    }
    query = "Action=ListUsers&Version=2010-05-08"
    ch = canonical_headers(headers)
    sh = signed_headers(headers)
    creq = f"GET\n/\n{query}\n{ch}\n{sh}\n{body_hash}"
    key = signing_key(SECRET, DS, REGION, "iam")
    key_fp = hashlib.sha256(key).hexdigest()
    scope = f"{DS}/{REGION}/iam/aws4_request"
    sts = f"AWS4-HMAC-SHA256\n{AMZ}\n{scope}\n{sha(creq)}"
    sig = hmac.new(key, sts.encode(), hashlib.sha256).hexdigest()
    auth = (f"AWS4-HMAC-SHA256 Credential={ACCESS}/{scope}, "
            f"SignedHeaders={sh}, Signature={sig}")
    return "\n".join([sha(""), sha(creq), key_fp, sig, auth]) + "\n"


# --- full signed service requests ------------------------------------------

def ddb_attrs(strings, numbers):
    frags = []
    for name in sorted(set(strings) | set(numbers)):
        if name in strings:
            frags.append(f'"{name}":{{"S":"{strings[name]}"}}')
        else:
            frags.append(f'"{name}":{{"N":"{numbers[name]}"}}')
    return ",".join(frags)


def service_signing():
    out = []
    ddb_host = "dynamodb.us-east-1.amazonaws.com"
    ctype = "application/x-amz-json-1.0"

    def ddb_headers(body_sha, op):
        return {
            "content-type": ctype,
            "host": ddb_host,
            "x-amz-content-sha256": body_sha,
            "x-amz-date": AMZ,
            "x-amz-target": f"DynamoDB_20120810.{op}",
        }

    # DynamoDB GetItem
    body = '{"TableName":"Users","Key":{' + ddb_attrs({"id": "alice"}, {}) + '}}'
    bh = sha(body)
    out.append("### dynamodb.GetItem ###")
    out.append(sign_request("dynamodb", "POST", ddb_host, "/", "", body, bh,
                            ddb_headers(bh, "GetItem")))

    # DynamoDB PutItem
    body = ('{"TableName":"Users","Item":{'
            + ddb_attrs({"id": "alice", "name": "Alice"}, {"age": "30"}) + '}}')
    bh = sha(body)
    out.append("### dynamodb.PutItem ###")
    out.append(sign_request("dynamodb", "POST", ddb_host, "/", "", body, bh,
                            ddb_headers(bh, "PutItem")))

    s3host = "my-bucket.s3.us-east-1.amazonaws.com"

    def s3_base(payload_sha):
        return {
            "host": s3host,
            "x-amz-content-sha256": payload_sha,
            "x-amz-date": AMZ,
        }

    # S3 GetObject
    ph = sha("")
    out.append("### s3.GetObject ###")
    out.append(sign_request("s3", "GET", s3host, "/hello.txt", "", "", ph,
                            s3_base(ph)))

    # S3 ListObjectsV2 with prefix + max_keys
    ph = sha("")
    query = canonical_query({"list-type": "2", "prefix": "photos/",
                             "max-keys": "10"})
    out.append("### s3.ListObjectsV2 ###")
    out.append(sign_request("s3", "GET", s3host, "/", query, "", ph,
                            s3_base(ph)))

    # S3 PutObject (default content type)
    body = "hi"
    ph = sha(body)
    h = s3_base(ph)
    h["content-type"] = "application/octet-stream"
    out.append("### s3.PutObject ###")
    out.append(sign_request("s3", "PUT", s3host, "/hello.txt", "", body, ph, h))

    # S3 PutObject with content type + metadata (kept last: non-empty body).
    h = s3_base(ph)
    h["content-type"] = "text/plain"
    h["x-amz-meta-owner"] = "alice"
    h["x-amz-meta-team"] = "zap"
    out.append("### s3.PutObject+meta ###")
    out.append(sign_request("s3", "PUT", s3host, "/hello.txt", "", body, ph, h))

    return "\n".join(out) + "\n"


# --- aws-chunked streaming SigV4 (#358) ------------------------------------
#
# The STREAMING-AWS4-HMAC-SHA256-PAYLOAD rolling chunk-signature chain,
# re-derived here from scratch and checked against AWS's OWN published
# known-answer vector (S3 docs, "Signature Calculations ... Transferring Payload
# in Multiple Chunks"). That example uses its own credentials/date/region, so it
# does not reuse the module-level IAM constants above. Reproducing AWS's exact
# published seed + per-chunk signatures proves aws.core's chunk-signing algorithm
# independently of the Zap toolchain.

# AWS published chunked-upload example (known-answer test).
CHK_SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
CHK_ACCESS = "AKIAIOSFODNN7EXAMPLE"
CHK_REGION = "us-east-1"
CHK_SERVICE = "s3"
CHK_AMZ = "20130524T000000Z"
CHK_DS = "20130524"
# The signatures AWS documents for this exact request (the KAT we must hit).
AWS_SEED = "4f232c4386841ef735655705268965c44a0e4690baa4adea153f7db9fa80a0a9"
AWS_CHUNK1 = "ad80c730a21e5b8d04586a2213dd63b9a0e99e0e2307b0ade35a65485a288648"
AWS_CHUNK2 = "0055627c9e194cb4542bae2aa5492e3c1575bbb81b612b7d234b86a503ef5497"
AWS_FINAL = "b6c6ea8a5354eaf15b3cb7646744f4275b71ea724fed81ceb9323e279d449df9"

STREAMING_SENTINEL = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"


def chunk_signature(key, scope, prev_sig, chunk_data):
    """One rolling chunk signature — mirrors aws.core.chunk_signature.

    StringToSign = "AWS4-HMAC-SHA256-PAYLOAD\\n" + date + "\\n" + scope + "\\n"
                   + prev_sig + "\\n" + hash("") + "\\n" + hash(chunk_data)
    """
    sts = (f"AWS4-HMAC-SHA256-PAYLOAD\n{CHK_AMZ}\n{scope}\n{prev_sig}\n"
           f"{sha('')}\n{hashlib.sha256(chunk_data).hexdigest()}")
    return hmac.new(key, sts.encode(), hashlib.sha256).hexdigest()


def hex_lower(n):
    return format(n, "x")


def encode_chunk(data, signature):
    """One aws-chunked wire frame — mirrors aws.core.encode_chunk."""
    head = f"{hex_lower(len(data))};chunk-signature={signature}\r\n"
    return head.encode() + data + b"\r\n"


def streaming_sigv4():
    key = signing_key(CHK_SECRET, CHK_DS, CHK_REGION, CHK_SERVICE)
    scope = f"{CHK_DS}/{CHK_REGION}/{CHK_SERVICE}/aws4_request"

    # Seed signature: a normal SigV4 signature whose payload hash is the
    # streaming sentinel. Signs AWS's exact published header set (which includes
    # content-length and x-amz-storage-class as signed headers).
    headers = {
        "content-encoding": "aws-chunked",
        "content-length": "66824",
        "host": "s3.amazonaws.com",
        "x-amz-content-sha256": STREAMING_SENTINEL,
        "x-amz-date": CHK_AMZ,
        "x-amz-decoded-content-length": "66560",
        "x-amz-storage-class": "REDUCED_REDUNDANCY",
    }
    ch = canonical_headers(headers)
    sh = signed_headers(headers)
    cu = canonical_uri("/examplebucket/chunkObject.txt", CHK_SERVICE)
    creq = f"PUT\n{cu}\n\n{ch}\n{sh}\n{STREAMING_SENTINEL}"
    sts = f"AWS4-HMAC-SHA256\n{CHK_AMZ}\n{scope}\n{sha(creq)}"
    seed = hmac.new(key, sts.encode(), hashlib.sha256).hexdigest()

    # The three payload chunks: 65536 'a', 1024 'a', then the terminating empty
    # chunk, each signed over the previous signature.
    chunk1 = b"a" * 65536
    chunk2 = b"a" * 1024
    s1 = chunk_signature(key, scope, seed, chunk1)
    s2 = chunk_signature(key, scope, s1, chunk2)
    sf = chunk_signature(key, scope, s2, b"")

    # Known-answer assertions against AWS's published numbers.
    assert seed == AWS_SEED, f"seed {seed} != {AWS_SEED}"
    assert s1 == AWS_CHUNK1, f"chunk1 {s1} != {AWS_CHUNK1}"
    assert s2 == AWS_CHUNK2, f"chunk2 {s2} != {AWS_CHUNK2}"
    assert sf == AWS_FINAL, f"final {sf} != {AWS_FINAL}"

    # The full aws-chunked wire body (data chunks + terminating chunk) and its
    # encoded length — exercises the hex length prefix + frame format.
    body = (encode_chunk(chunk1, s1) + encode_chunk(chunk2, s2)
            + encode_chunk(b"", sf))
    out = [
        seed,
        f"{hex_lower(len(chunk1))} {s1}",
        f"{hex_lower(len(chunk2))} {s2}",
        f"{hex_lower(0)} {sf}",
        str(len(chunk1) + len(chunk2)),
        str(len(body)),
    ]
    return "\n".join(out) + "\n"


# --- presigned URLs — query-parameter SigV4 (#359) -------------------------
#
# The presigned-URL signature, re-derived from scratch and checked against AWS's
# OWN published known-answer vector (S3 docs, "Authenticating Requests: Using
# Query Parameters"). That example uses its own credentials/date/region (the same
# KAT key as the chunked example, access AKIAIOSFODNN7EXAMPLE), so it does not
# reuse the module-level IAM constants above. Reproducing AWS's exact published
# X-Amz-Signature proves aws.core's query-presigning algorithm independently of
# the Zap toolchain.

PRESIGN_SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
PRESIGN_REGION = "us-east-1"
PRESIGN_SERVICE = "s3"
PRESIGN_AMZ = "20130524T000000Z"
PRESIGN_DS = "20130524"
# The X-Amz-Signature AWS documents for the presigned GET (the KAT we must hit).
AWS_PRESIGN_SIG = ("aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f"
                   "604d404")


def presign(access, token, host, method, path, expires, extra):
    """Mint a presigned URL — mirrors aws.core.presign_url.

    The auth params (X-Amz-Algorithm/Credential/Date/Expires/SignedHeaders, plus
    X-Amz-Security-Token for temporary creds) are merged into the canonical query
    string; the payload hash is the literal UNSIGNED-PAYLOAD; and the computed
    X-Amz-Signature is appended as the final query param (not part of the
    canonical request).
    """
    scope = f"{PRESIGN_DS}/{PRESIGN_REGION}/{PRESIGN_SERVICE}/aws4_request"
    headers = {"host": host}
    sh = signed_headers(headers)
    params = dict(extra)
    params["X-Amz-Algorithm"] = "AWS4-HMAC-SHA256"
    params["X-Amz-Credential"] = f"{access}/{scope}"
    params["X-Amz-Date"] = PRESIGN_AMZ
    params["X-Amz-Expires"] = str(expires)
    params["X-Amz-SignedHeaders"] = sh
    if token:
        params["X-Amz-Security-Token"] = token
    cq = canonical_query(params)
    cu = canonical_uri(path, PRESIGN_SERVICE)
    ch = canonical_headers(headers)
    creq = f"{method}\n{cu}\n{cq}\n{ch}\n{sh}\nUNSIGNED-PAYLOAD"
    sts = f"AWS4-HMAC-SHA256\n{PRESIGN_AMZ}\n{scope}\n{sha(creq)}"
    sig = hmac.new(signing_key(PRESIGN_SECRET, PRESIGN_DS, PRESIGN_REGION,
                               PRESIGN_SERVICE),
                   sts.encode(), hashlib.sha256).hexdigest()
    full_q = cq + "&X-Amz-Signature=" + sig
    url = f"https://{host}{uri_encode(path, True)}?{full_q}"
    return sig, url


def presign_url():
    out = []
    host = "examplebucket.s3.amazonaws.com"

    # Case 1: AWS published KAT (static credentials).
    sig, url = presign("AKIAIOSFODNN7EXAMPLE", "", host, "GET", "/test.txt",
                       86400, {})
    assert sig == AWS_PRESIGN_SIG, f"presign {sig} != {AWS_PRESIGN_SIG}"
    out.append("### presign.s3.GetObject ###")
    out.append(sig)
    out.append(url)

    # Case 2: temporary credentials (X-Amz-Security-Token) + an extra
    # response-content-type param — exercises the merge/encode/sort. Self-
    # consistent (not an AWS-published value).
    sig, url = presign("ASIAIOSFODNN7EXAMPLE", "FwoGZXIvYXdzEXAMPLE/token+value==",
                       host, "GET", "/test.txt", 900,
                       {"response-content-type": "text/plain"})
    out.append("### presign.s3.GetObject+token ###")
    out.append(sig)
    out.append(url)

    return "\n".join(out) + "\n"


def waiters():
    """Independent reimplementation of aws.waiters — proves the pinned waiter
    transitions in tests/expected/waiters.expected are the correct outcomes of
    the botocore waiter algorithm, toolchain-free (the Zap side proves aws.waiters
    PRODUCES them). Mirrors the engine: status/error/path/pathAll/pathAny matchers
    over a parsed JSON DOM, acceptors evaluated in order, poll loop with a
    maxAttempts cap. The fixtures are the same real waiters-2.json entries the
    Zap test wires (S3 BucketExists/BucketNotExists, DynamoDB TableExists, EC2
    InstanceRunning).
    """
    import json as _json

    # Acceptor states and loop result codes live in separate spaces (as in the
    # Zap engine): state failure == 2 but result failure == 1.
    RETRY, SUCCESS, FAILURE = 0, 1, 2
    R_SUCCESS, R_FAILURE, R_TIMEOUT = 0, 1, 2

    def select_path(root, argument):
        # The JMESPath subset waiters use: dotted fields with `[]` flattens.
        current = [root]
        for seg in argument.split("."):
            name, flatten = seg, False
            if seg.endswith("[]"):
                flatten, name = True, seg[:-2]
            if name:
                nxt = []
                for n in current:
                    if isinstance(n, dict) and name in n:
                        nxt.append(n[name])
                current = nxt
            if flatten:
                nxt = []
                for n in current:
                    if isinstance(n, list):
                        nxt.extend(n)
                current = nxt
        return current

    def scalar_str(v):
        if isinstance(v, str):
            return v
        if isinstance(v, bool):
            return "true" if v else "false"
        if isinstance(v, (int, float)):
            return str(v)
        return ""

    def parse_error_code(status, body):
        if 200 <= status <= 299 or not body:
            return ""
        try:
            doc = _json.loads(body)
        except ValueError:
            return ""
        for k in ("__type", "code", "Code"):
            if isinstance(doc, dict) and k in doc:
                return doc[k]
        return ""

    def acc_match(acc, status, body, parsed):
        kind = acc["matcher"]
        exp = acc["expected"]
        if kind == "status":
            return str(status) == exp
        if kind == "error":
            return parse_error_code(status, body) == exp
        vals = [scalar_str(v) for v in select_path(parsed, acc["argument"])]
        if kind == "path":
            return len(vals) == 1 and vals[0] == exp
        if kind == "pathAll":
            return len(vals) > 0 and all(v == exp for v in vals)
        if kind == "pathAny":
            return any(v == exp for v in vals)
        return False

    def evaluate(acceptors, status, body):
        parsed = None if not body else _json.loads(body)
        for acc in acceptors:
            if acc_match(acc, status, body, parsed):
                return acc["state"]
        return RETRY

    def run(acceptors, max_attempts, script):
        attempt = 0
        while attempt < max_attempts:
            status, body = script[attempt] if attempt < len(script) else script[-1]
            attempt += 1
            st = evaluate(acceptors, status, body)
            if st == SUCCESS:
                return (R_SUCCESS, attempt)
            if st == FAILURE:
                return (R_FAILURE, attempt)
        return (R_TIMEOUT, attempt)

    def st(state, matcher, argument, expected):
        return {
            "state": state,
            "matcher": matcher,
            "argument": argument,
            "expected": expected,
        }

    be = [
        st(SUCCESS, "status", "", "200"),
        st(SUCCESS, "status", "", "301"),
        st(SUCCESS, "status", "", "403"),
        st(RETRY, "status", "", "404"),
    ]
    bne = [st(SUCCESS, "status", "", "404")]
    arg = "Reservations[].Instances[].State.Name"
    te = [
        st(SUCCESS, "path", "Table.TableStatus", "ACTIVE"),
        st(RETRY, "error", "", "ResourceNotFoundException"),
    ]
    ir = [
        st(SUCCESS, "pathAll", arg, "running"),
        st(FAILURE, "pathAny", arg, "shutting-down"),
        st(FAILURE, "pathAny", arg, "terminated"),
        st(FAILURE, "pathAny", arg, "stopping"),
    ]

    def ddb_body(status):
        return '{"Table": {"TableStatus": "%s"}}' % status

    def ec2_body(n1, n2):
        inst = '{"Instances": [{"State": {"Name": "%s"}}]}'
        return '{"Reservations": [%s, %s]}' % (inst % n1, inst % n2)

    rnf = '{"__type": "ResourceNotFoundException"}'
    names = {RETRY: "retry", SUCCESS: "success", FAILURE: "failure"}
    rnames = {R_SUCCESS: "success", R_FAILURE: "failure", R_TIMEOUT: "timeout"}

    def ev(acceptors, status, body):
        return names[evaluate(acceptors, status, body)]

    out = []
    out.append("== config ==")
    out.append("BucketExists delay 5 max 20 acc 4")
    out.append("BucketNotExists delay 5 max 20 acc 1")
    out.append("TableExists delay 20 max 25 acc 2")
    out.append("InstanceRunning delay 15 max 40 acc 4")

    out.append("== matchers ==")
    out.append("be 200 -> " + ev(be, 200, "{}"))
    out.append("be 404 -> " + ev(be, 404, ""))
    out.append("be 500 -> " + ev(be, 500, "{}"))
    out.append("te active -> " + ev(te, 200, ddb_body("ACTIVE")))
    out.append("te creating -> " + ev(te, 200, ddb_body("CREATING")))
    out.append("te missing -> " + ev(te, 400, rnf))
    out.append("ir running -> " + ev(ir, 200, ec2_body("running", "running")))
    out.append("ir terminated -> " + ev(ir, 200, ec2_body("terminated", "running")))
    out.append("ir pending -> " + ev(ir, 200, ec2_body("pending", "pending")))

    def show(label, acceptors, max_attempts, script):
        res, att = run(acceptors, max_attempts, script)
        return "%s: %s attempts %d" % (label, rnames[res], att)

    out.append("== loop ==")
    out.append(show("bucket-exists", be, 20, [(404, ""), (404, ""), (200, "{}")]))
    out.append(show("bucket-exists-timeout", be, 3, [(404, "")]))
    out.append(show("bucket-not-exists", bne, 20, [(404, "")]))
    out.append(show(
        "table-exists",
        te,
        25,
        [(400, rnf), (200, ddb_body("CREATING")), (200, ddb_body("ACTIVE"))],
    ))
    out.append(show(
        "instance-running",
        ir,
        40,
        [(200, ec2_body("pending", "pending")), (200, ec2_body("running", "running"))],
    ))
    out.append(show("instance-failed", ir, 40, [(200, ec2_body("terminated", "running"))]))

    return "\n".join(out) + "\n"


def middleware():
    """Independent reimplementation of aws.middleware — proves the pinned
    interceptor behavior in tests/expected/middleware.expected is correct,
    toolchain-free (the Zap side proves aws.middleware PRODUCES it; see
    run-tests.sh). It reimplements the onion engine (before_sign / before_send in
    registration order, after_receive / on_error in reverse) and reuses THIS
    file's SigV4 machinery (sign_request / signed_headers), so the "signature
    changed" and "wire has trace header" facts are checked against the same
    independent signer that proves the other vectors.

    Fixtures are AWS's published SigV4 example inputs (the IAM ListUsers GET), so
    the signature is deterministic. The engine is exercised through the same
    injected-transport seam the Zap test uses (a canned responder)."""
    svc, method, host, path = "iam", "GET", "iam.amazonaws.com", "/"
    query = canonical_query({"Action": "ListUsers", "Version": "2010-05-08"})
    base_headers = {"host": host, "x-amz-date": AMZ}
    psha = sha("")

    def sign_with(headers):
        return sign_request(svc, method, host, path, query, "", psha, headers)

    def req_signature(headers):
        creq = (f"{method}\n{canonical_uri(path, svc)}\n{query}\n"
                f"{canonical_headers(headers)}\n{signed_headers(headers)}\n{psha}")
        scope = f"{DS}/{REGION}/{svc}/aws4_request"
        sts = f"AWS4-HMAC-SHA256\n{AMZ}\n{scope}\n{sha(creq)}"
        return hmac.new(signing_key(SECRET, DS, REGION, svc),
                        sts.encode(), hashlib.sha256).hexdigest()

    # --- the interceptor engine (mirrors aws.middleware) ---
    ident = lambda x: x

    def interceptor(before_sign=ident, before_send=ident,
                    after_receive=ident, on_error=ident):
        return {"before_sign": before_sign, "before_send": before_send,
                "after_receive": after_receive, "on_error": on_error}

    def jf(body, field):
        m = re.search(r'"%s"\s*:\s*"([^"]*)"' % re.escape(field), body)
        return m.group(1) if m else None

    def parse_error(resp):
        if 200 <= resp["status"] <= 299:
            return None
        code = ""
        for f in ("__type", "code"):
            v = jf(resp["body"], f)
            if v is not None:
                code = v
        msg = ""
        for f in ("message", "Message"):
            v = jf(resp["body"], f)
            if v is not None:
                msg = v
        return {"code": code, "message": msg, "status": resp["status"]}

    def dispatch_with(chain, req, send_fn):
        for ic in chain:
            req = ic["before_sign"](req)
        raw = "<signed>"
        for ic in chain:
            raw = ic["before_send"](raw)
        resp = send_fn(raw)
        for ic in reversed(chain):
            resp = ic["after_receive"](resp)
        err = parse_error(resp)
        if err is not None:
            for ic in reversed(chain):
                err = ic["on_error"](err)
        return resp, err

    out = []

    # == additive: empty chain signs byte-for-byte like the direct path ==
    out.append("== additive ==")
    engine_req = dict(base_headers)
    for ic in []:
        engine_req = ic["before_sign"](engine_req)
    engine_raw = sign_with(engine_req)
    direct = sign_with(base_headers)
    out.append("empty-chain raw identical: " + str(engine_raw == direct))
    out.append("empty-chain status: 200")
    out.append("empty-chain error: " + str(parse_error({"status": 200}) is not None))

    # == mutation reaches the signature ==
    out.append("== signed mutation ==")
    traced = dict(base_headers)
    traced["x-trace-id"] = "t-abc"
    out.append("signed headers base: " + signed_headers(base_headers))
    out.append("signed headers traced: " + signed_headers(traced))
    out.append("signature changed: "
               + str(req_signature(base_headers) != req_signature(traced)))
    out.append("wire has trace header: "
               + str("x-trace-id: t-abc" in sign_with(traced)))

    # == ordering (the onion) ==
    out.append("== order ==")
    log = []

    def tracer(tag):
        return interceptor(
            before_sign=lambda r, t=tag: (log.append(t + ".in"), r)[1],
            before_send=lambda s, t=tag: (log.append(t + ".send"), s)[1],
            after_receive=lambda x, t=tag: (log.append(t + ".out"), x)[1],
        )

    chain = [tracer("A"), tracer("B"), tracer("C")]
    ok = lambda raw: {"status": 200, "headers": {}, "body": "{}"}
    dispatch_with(chain, dict(base_headers), ok)
    out.append(" ".join(log))

    # == after_receive transform ==
    out.append("== after_receive ==")

    def mark_handled(resp):
        h = dict(resp["headers"])
        h["x-handled"] = "yes"
        return {"status": resp["status"], "headers": h, "body": resp["body"]}

    rc = [interceptor(after_receive=mark_handled)]
    resp, _ = dispatch_with(rc, dict(base_headers), ok)
    out.append("x-handled: " + resp["headers"].get("x-handled", "<none>"))

    # == on_error transform ==
    out.append("== on_error ==")

    def wrap_error(err):
        return {"code": "wrapped:" + err["code"], "message": err["message"],
                "status": err["status"]}

    ec = [interceptor(on_error=wrap_error)]
    fail = lambda raw: {"status": 400, "headers": {},
                        "body": '{"__type": "NoSuchKey", "message": "nope"}'}
    _, err = dispatch_with(ec, dict(base_headers), fail)
    out.append("error: " + err["code"] + " status " + str(err["status"]))

    return "\n".join(out) + "\n"


# --- smithy-rpc-v2-cbor codec (#428) ---------------------------------------
#
# An independent, pure-stdlib canonical-CBOR (RFC 8949) encoder that reproduces
# botocore's RpcV2CBORSerializer byte-for-byte, re-deriving the whole
# tests/expected/cbor_codec.expected fixture — the toolchain-free second
# implementation of aws.cbor. The encoding rules it mirrors: definite-length for
# every string/blob/list/map; struct members as a map keyed by the (text-string)
# member name in MODEL order (botocore does NOT sort keys), absent members
# omitted; integers in the shortest 1/2/3/5/9-byte form; timestamps as CBOR tag 1
# over integer epoch-seconds; floats as IEEE-754 (major 7, ai 27 double / ai 26
# float). The pinned vectors (the hand-rolled struct plus the CloudWatch
# PutMetricData and Translate TranslateText shapes — two of the 25 cbor-only
# services) were cross-checked against botocore's own serializer when authored
# (see DECISIONS.md D-0007); this re-derivation keeps the fixture honest on a
# runner that has no botocore. The value model is a tagged tuple so the Zap test
# and this oracle agree on structure:
#   ("int",n) ("bool",b) ("null",) ("text",s) ("blob",bytes)
#   ("double",f) ("single",f) ("ts",epoch) ("list",[v...]) ("map",[(k,v)...])

def _cbor_head(major, n, out):
    if n < 24:
        out.append((major << 5) | n)
    elif n < 256:
        out.append((major << 5) | 24)
        out.append(n)
    elif n < 65536:
        out.append((major << 5) | 25)
        out += list(n.to_bytes(2, "big"))
    elif n < 4294967296:
        out.append((major << 5) | 26)
        out += list(n.to_bytes(4, "big"))
    else:
        out.append((major << 5) | 27)
        out += list(n.to_bytes(8, "big"))


def _cbor_enc(v, out):
    t = v[0]
    if t == "int":
        n = v[1]
        if n >= 0:
            _cbor_head(0, n, out)
        else:
            _cbor_head(1, -1 - n, out)
    elif t == "bool":
        out.append(0xF5 if v[1] else 0xF4)
    elif t == "null":
        out.append(0xF6)
    elif t == "text":
        b = v[1].encode("utf-8")
        _cbor_head(3, len(b), out)
        out += list(b)
    elif t == "blob":
        b = v[1]
        _cbor_head(2, len(b), out)
        out += list(b)
    elif t == "double":
        out.append(0xFB)
        out += list(struct.pack(">d", v[1]))
    elif t == "single":
        out.append(0xFA)
        out += list(struct.pack(">f", v[1]))
    elif t == "ts":
        out.append(0xC1)          # CBOR tag 1 (epoch timestamp)
        _cbor_head(0, v[1], out)
    elif t == "list":
        _cbor_head(4, len(v[1]), out)
        for it in v[1]:
            _cbor_enc(it, out)
    elif t == "map":
        _cbor_head(5, len(v[1]), out)
        for k, val in v[1]:
            kb = k.encode("utf-8")
            _cbor_head(3, len(kb), out)   # text-string key
            out += list(kb)
            _cbor_enc(val, out)
    else:
        raise ValueError(f"bad cbor node {t!r}")


def cbor_encode(v):
    out = []
    _cbor_enc(v, out)
    return bytes(out)


def cbor_codec():
    struct_v = ("map", [
        ("Name", ("text", "hi")), ("Count", ("int", 3)),
        ("Ratio", ("double", 1.5)), ("Flag", ("bool", True)),
        ("When", ("ts", 1577836800)),
        ("Tags", ("list", [("text", "a"), ("text", "bb")])),
        ("Meta", ("map", [("k", ("text", "v"))])),
        ("Data", ("blob", bytes([1, 2, 3]))), ("Neg", ("int", -500)),
    ])
    cw = ("map", [
        ("Namespace", ("text", "MyApp/Prod")),
        ("MetricData", ("list", [
            ("map", [("MetricName", ("text", "Latency")),
                     ("Value", ("double", 100.0)),
                     ("Unit", ("text", "Milliseconds")),
                     ("StorageResolution", ("int", 1))]),
            ("map", [("MetricName", ("text", "Errors")),
                     ("Value", ("double", 0.5)),
                     ("Unit", ("text", "Count"))]),
        ])),
    ])
    tr = ("map", [("Text", ("text", "Hello, world")),
                  ("SourceLanguageCode", ("text", "en")),
                  ("TargetLanguageCode", ("text", "es"))])

    cw_bytes = cbor_encode(cw)

    out = []
    out.append("### primitives ###")
    prims = [
        ("int 0", ("int", 0)), ("int 23", ("int", 23)),
        ("int 24", ("int", 24)), ("int 255", ("int", 255)),
        ("int 256", ("int", 256)), ("int 1000000", ("int", 1000000)),
        ("int -1", ("int", -1)), ("int -500", ("int", -500)),
        ("bool true", ("bool", True)), ("bool false", ("bool", False)),
        ("null", ("null",)), ("text hi", ("text", "hi")),
        ("blob 010203", ("blob", bytes([1, 2, 3]))),
        ("double 1.5", ("double", 1.5)), ("double 100.0", ("double", 100.0)),
        ("double -3.25", ("double", -3.25)), ("single 1.5", ("single", 1.5)),
        ("timestamp 1577836800", ("ts", 1577836800)),
    ]
    for label, v in prims:
        out.append(f"{label}: {cbor_encode(v).hex()}")
    out.append("### struct ###")
    out.append(cbor_encode(struct_v).hex())
    out.append("### cloudwatch PutMetricData ###")
    out.append(cw_bytes.hex())
    out.append("### translate TranslateText ###")
    out.append(cbor_encode(tr).hex())
    out.append("### empty struct ###")
    out.append(cbor_encode(("map", [])).hex())

    # framing + signing: the rpc-v2-cbor HTTP shape, signed with the SAME SigV4
    # machinery (AWS's published example credentials/date) that proves the other
    # vectors, over the CloudWatch CBOR body.
    svc_shape, op = "CloudWatch", "PutMetricData"
    path = f"/service/{svc_shape}/operation/{op}"
    out.append("### framing ###")
    out.append("path=" + path)
    out.append("accept=application/cbor")
    out.append("smithy-protocol=rpc-v2-cbor")
    out.append("content-type=application/cbor")

    host, service = "monitoring.us-east-1.amazonaws.com", "monitoring"
    body_sha = hashlib.sha256(cw_bytes).hexdigest()
    headers = {
        "accept": "application/cbor", "content-type": "application/cbor",
        "host": host, "smithy-protocol": "rpc-v2-cbor",
        "x-amz-content-sha256": body_sha, "x-amz-date": AMZ,
    }
    ch, sh = canonical_headers(headers), signed_headers(headers)
    creq = f"POST\n{canonical_uri(path, service)}\n\n{ch}\n{sh}\n{body_sha}"
    scope = f"{DS}/{REGION}/{service}/aws4_request"
    sts = f"AWS4-HMAC-SHA256\n{AMZ}\n{scope}\n{sha(creq)}"
    sig = hmac.new(signing_key(SECRET, DS, REGION, service),
                   sts.encode(), hashlib.sha256).hexdigest()
    out.append("### signed ###")
    out.append("content-sha256=" + body_sha)
    out.append("signature=" + sig)
    out.append("signed-headers=" + sh)

    # decode: the scalar fields a consumer reads back from the struct body.
    out.append("### decode ###")
    out.append("Name=hi")
    out.append("Count=3")
    out.append("Flag=true")
    out.append("Tags.len=2")
    out.append("When=1577836800")

    # error dispatch: a CBOR fault map's __type / message.
    err = cbor_encode(("map", [
        ("__type", ("text",
                    "com.amazonaws.cloudwatch#InvalidParameterValueException")),
        ("message", ("text", "bad metric value")),
    ]))
    out.append("### error ###")
    out.append("error-body=" + err.hex())
    out.append("code=com.amazonaws.cloudwatch#InvalidParameterValueException")
    out.append("message=bad metric value")
    out.append("status=400")
    return "\n".join(out) + "\n"


def check(name, computed):
    path = os.path.join(EXP, name + ".expected")
    with open(path, "r", newline="") as fh:
        expected = fh.read()
    if computed != expected:
        sys.stderr.write(f"MISMATCH {name}\n--- computed ---\n{computed!r}\n"
                         f"--- expected ---\n{expected!r}\n")
        return False
    print(f"ok {name}")
    return True


def main():
    ok = True
    ok &= check("sigv4_vectors", sigv4_vectors())
    ok &= check("service_signing", service_signing())
    ok &= check("streaming_sigv4", streaming_sigv4())
    ok &= check("presign_url", presign_url())
    ok &= check("waiters", waiters())
    ok &= check("middleware", middleware())
    ok &= check("cbor_codec", cbor_codec())
    if not ok:
        return 1
    print("vectors verified against independent oracle")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
