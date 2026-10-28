#!/usr/bin/env python3
"""Independent SigV4 oracle — recompute the pinned test fixtures from scratch and
diff them against tests/expected/*.expected.

This is the toolchain-free half of CI: it proves the EXPECTED fixtures are the
correct SigV4 outputs (an independent second implementation of the algorithm),
so a regression in the fixtures is caught even on a runner without an LLVM Zap
build. The Zap side (that aws.core actually PRODUCES these bytes) is proven by
tools/run-tests.sh against the real toolchain; see README/CI.

Uses only the Python standard library (hashlib, hmac).
"""
import hashlib
import hmac
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXP = os.path.join(ROOT, "tests", "expected")

SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
ACCESS = "AKIDEXAMPLE"
REGION = "us-east-1"
AMZ = "20150830T123600Z"
DS = "20150830"


def sha(s):
    return hashlib.sha256(s.encode()).hexdigest()


def hm(k, m):
    return hmac.new(k, m.encode(), hashlib.sha256).digest()


def signing_key(secret, ds, region, svc):
    k = hm(("AWS4" + secret).encode(), ds)
    k = hm(k, region)
    k = hm(k, svc)
    return hm(k, "aws4_request")


def sign(secret, ds, region, svc, creq):
    scope = f"{ds}/{region}/{svc}/aws4_request"
    sts = "AWS4-HMAC-SHA256\n" + AMZ + "\n" + scope + "\n" + sha(creq)
    return hmac.new(signing_key(secret, ds, region, svc),
                    sts.encode(), hashlib.sha256).hexdigest(), scope


def sigv4_vectors():
    body_hash = sha("")
    ctype = "application/x-www-form-urlencoded; charset=utf-8"
    query = "Action=ListUsers&Version=2010-05-08"
    ch = (f"content-type:{ctype}\nhost:iam.amazonaws.com\n"
          f"x-amz-date:{AMZ}\n")
    sh = "content-type;host;x-amz-date"
    creq = f"GET\n/\n{query}\n{ch}\n{sh}\n{body_hash}"
    key = signing_key(SECRET, DS, REGION, "iam")
    key_fp = hashlib.sha256(key).hexdigest()
    sig, scope = sign(SECRET, DS, REGION, "iam", creq)
    auth = (f"AWS4-HMAC-SHA256 Credential={ACCESS}/{scope}, "
            f"SignedHeaders={sh}, Signature={sig}")
    return "\n".join([sha(""), sha(creq), key_fp, sig, auth]) + "\n"


def http_req(method, target, headers_block, body):
    return (f"{method} {target} HTTP/1.1\r\n{headers_block}"
            f"Connection: close\r\n\r\n{body}")


def service_signing():
    out = []
    # DynamoDB GetItem
    host = "dynamodb.us-east-1.amazonaws.com"
    body = '{"TableName":"Users","Key":{"id":{"S":"alice"}}}'
    bh = sha(body)
    ctype = "application/x-amz-json-1.0"
    target = "DynamoDB_20120810.GetItem"
    ch = (f"content-type:{ctype}\nhost:{host}\n"
          f"x-amz-content-sha256:{bh}\nx-amz-date:{AMZ}\n"
          f"x-amz-target:{target}\n")
    sh = "content-type;host;x-amz-content-sha256;x-amz-date;x-amz-target"
    creq = f"POST\n/\n\n{ch}\n{sh}\n{bh}"
    sig, scope = sign(SECRET, DS, REGION, "dynamodb", creq)
    auth = (f"AWS4-HMAC-SHA256 Credential={ACCESS}/{scope}, "
            f"SignedHeaders={sh}, Signature={sig}")
    hb = (f"Host: {host}\r\nContent-Type: {ctype}\r\n"
          f"X-Amz-Date: {AMZ}\r\nX-Amz-Content-Sha256: {bh}\r\n"
          f"X-Amz-Target: {target}\r\nContent-Length: 48\r\n"
          f"Authorization: {auth}\r\n")
    out.append("### dynamodb.GetItem ###")
    out.append(http_req("POST", "/", hb, body))

    # S3 GetObject + PutObject
    s3host = "my-bucket.s3.us-east-1.amazonaws.com"
    sh3 = "host;x-amz-content-sha256;x-amz-date"
    for label, method, target, bdy, clen in [
        ("### s3.GetObject ###", "GET", "/hello.txt", "", "0"),
        ("### s3.PutObject ###", "PUT", "/hello.txt", "hi", "2"),
    ]:
        ph = sha(bdy)
        ch = f"host:{s3host}\nx-amz-content-sha256:{ph}\nx-amz-date:{AMZ}\n"
        creq = f"{method}\n{target}\n\n{ch}\n{sh3}\n{ph}"
        sig, scope = sign(SECRET, DS, REGION, "s3", creq)
        auth = (f"AWS4-HMAC-SHA256 Credential={ACCESS}/{scope}, "
                f"SignedHeaders={sh3}, Signature={sig}")
        hb = (f"Host: {s3host}\r\nX-Amz-Date: {AMZ}\r\n"
              f"X-Amz-Content-Sha256: {ph}\r\nContent-Length: {clen}\r\n"
              f"Authorization: {auth}\r\n")
        out.append(label)
        out.append(http_req(method, target, hb, bdy))
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
