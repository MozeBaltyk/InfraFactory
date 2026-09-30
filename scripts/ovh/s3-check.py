#!/usr/bin/env python3
"""AWS SigV4 probe for an S3-compatible bucket (OVH Object Storage).

Reads AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY from the environment and probes
the bucket with the operations the OpenTofu S3 backend needs: list, write,
read, and delete (a short-lived probe object). Prints one summary line and
exits 0 only when list + write + read + delete all succeed. Never prints secrets.
"""
import hashlib
import hmac
import os
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone


def _hmac(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def _sha256(data):
    if isinstance(data, str):
        data = data.encode()
    return hashlib.sha256(data).hexdigest()


def _sign(access, secret, region, service, method, host, uri, query, payload_hash, amzdate):
    datestamp = amzdate[:8]
    canonical_headers = (
        f"host:{host}\n"
        f"x-amz-content-sha256:{payload_hash}\n"
        f"x-amz-date:{amzdate}\n"
    )
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = "\n".join(
        [method, uri, query, canonical_headers, signed_headers, payload_hash]
    )
    scope = f"{datestamp}/{region}/{service}/aws4_request"
    string_to_sign = "\n".join(["AWS4-HMAC-SHA256", amzdate, scope, _sha256(canonical_request)])
    key = _hmac(("AWS4" + secret).encode(), datestamp)
    key = _hmac(key, region)
    key = _hmac(key, service)
    key = _hmac(key, "aws4_request")
    signature = hmac.new(key, string_to_sign.encode(), hashlib.sha256).hexdigest()
    return (
        f"AWS4-HMAC-SHA256 Credential={access}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )


def call(req, method, bucket, key, query, body, access, secret, region, endpoint):
    host = endpoint.split("://", 1)[1].rstrip("/")
    amzdate = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    payload_hash = _sha256(body) if body else _sha256("")
    uri = "/" + urllib.parse.quote(bucket, safe="")
    if key:
        uri += "/" + urllib.parse.quote(key, safe="")
    auth = _sign(access, secret, region, "s3", method, host, uri, query, payload_hash, amzdate)
    url = endpoint.rstrip("/") + uri + (("?" + query) if query else "")
    data = body if body else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Host", host)
    request.add_header("x-amz-date", amzdate)
    request.add_header("x-amz-content-sha256", payload_hash)
    request.add_header("Authorization", auth)

    try:
        with urllib.request.urlopen(request, timeout=15) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except Exception as exc:  # noqa: BLE001
        return f"ERR:{type(exc).__name__}"


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: s3-check.py BUCKET REGION ENDPOINT")
    bucket, region, endpoint = sys.argv[1:4]
    access = os.environ.get("AWS_ACCESS_KEY_ID", "")
    secret = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    if not access or not secret:
        print("bucket '{}': skipped (credentials not set)".format(bucket), file=sys.stderr)
        sys.exit(2)

    probe_key = ".infrafactory-s3-probe-{}".format(secrets.token_hex(16))
    body = b"infrafactory probe"

    list_code = call(None, "GET", bucket, "", "max-keys=1", None, access, secret, region, endpoint)
    put_code = call(None, "PUT", bucket, probe_key, "", body, access, secret, region, endpoint)
    head_code = call(None, "HEAD", bucket, probe_key, "", None, access, secret, region, endpoint)
    del_code = call(None, "DELETE", bucket, probe_key, "", None, access, secret, region, endpoint)

    def label(code, ok):
        if code == ok:
            return "ok"
        if isinstance(code, str):
            return "fail({})".format(code)
        return "fail({})".format(code)

    summary = "bucket '{}': list={} write={} read={} delete={}".format(
        bucket,
        label(list_code, 200),
        label(put_code, 200),
        label(head_code, 200),
        label(del_code, 204),
    )

    ok = list_code == 200 and put_code == 200 and head_code == 200 and del_code == 204
    if ok:
        print(summary)
        sys.exit(0)
    print(summary, file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
