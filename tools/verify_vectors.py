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
    if not ok:
        return 1
    print("vectors verified against independent oracle")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
