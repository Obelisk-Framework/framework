#!/usr/bin/env python3
"""Independent cross-check of AWS SigV4, from scratch, using only Python's
stdlib (hashlib/hmac) — no AWS SDK, no network.

This is NOT a copy of anything AWS has published. It's a from-scratch
implementation of the publicly-documented algorithm described at:
  - https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html
  - https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html

It exists because the specific worked example historically used to
cross-check tests/sigv4_spec.lua (AWS's old "GET Object" walkthrough for
bucket `examplebucket` / object `test.txt`) has been retired from AWS's
docs site (see task-2-report.md in the storage-service plan for the dead
links checked). Rather than hand-type or guess hex constants, this script
independently re-derives them for the exact same fixed inputs that
tests/sigv4_spec.lua exercises, by chaining the same four steps
core/server/Services/storage/sigv4.lua implements:

  1. canonical request -> SHA-256 hex digest
  2. string to sign (algorithm, amz-date, credential scope, hashed canonical request)
  3. signing key (four chained HMAC-SHA256 calls: date -> region -> service -> aws4_request)
  4. final signature (HMAC-SHA256 of the string to sign, keyed by the signing key, hex)

Run: python3 tests/support/sigv4_reference.py
"""
import hashlib
import hmac


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def hmac_sha256(key: bytes, data: str) -> bytes:
    return hmac.new(key, data.encode('utf-8'), hashlib.sha256).digest()


def canonical_request(method, canonical_uri, canonical_query, signed_header_names, headers, payload_hash):
    canonical_headers = ''.join(name + ':' + headers[name] + '\n' for name in signed_header_names)
    signed_headers = ';'.join(signed_header_names)
    return '\n'.join([method, canonical_uri, canonical_query, canonical_headers, signed_headers, payload_hash])


def string_to_sign(amz_date, date_stamp, region, service, canonical_request_hash):
    scope = f'{date_stamp}/{region}/{service}/aws4_request'
    return '\n'.join(['AWS4-HMAC-SHA256', amz_date, scope, canonical_request_hash])


def signing_key(secret_key, date_stamp, region, service):
    k_date = hmac_sha256(('AWS4' + secret_key).encode('utf-8'), date_stamp)
    k_region = hmac_sha256(k_date, region)
    k_service = hmac_sha256(k_region, service)
    return hmac_sha256(k_service, 'aws4_request')


def signature(secret_key, date_stamp, region, service, string_to_sign_value):
    key = signing_key(secret_key, date_stamp, region, service)
    return hmac.new(key, string_to_sign_value.encode('utf-8'), hashlib.sha256).hexdigest()


if __name__ == '__main__':
    ACCESS_KEY = 'AKIAIOSFODNN7EXAMPLE'  # unused in the computation itself; kept for parity with the test file
    SECRET_KEY = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
    AMZ_DATE = '20130524T000000Z'
    DATE_STAMP = '20130524'
    REGION = 'us-east-1'
    SERVICE = 's3'
    EMPTY_PAYLOAD_HASH = sha256_hex(b'')

    headers = {
        'host': 'examplebucket.s3.amazonaws.com',
        'range': 'bytes=0-9',
        'x-amz-content-sha256': EMPTY_PAYLOAD_HASH,
        'x-amz-date': AMZ_DATE,
    }
    signed_header_names = ['host', 'range', 'x-amz-content-sha256', 'x-amz-date']

    creq = canonical_request('GET', '/test.txt', '', signed_header_names, headers, EMPTY_PAYLOAD_HASH)
    creq_hash = sha256_hex(creq.encode('utf-8'))
    sts = string_to_sign(AMZ_DATE, DATE_STAMP, REGION, SERVICE, creq_hash)
    sig = signature(SECRET_KEY, DATE_STAMP, REGION, SERVICE, sts)

    print('empty payload hash:', EMPTY_PAYLOAD_HASH)
    print('canonical request:')
    print(creq)
    print()
    print('canonical request hash:', creq_hash)
    print()
    print('string to sign:')
    print(sts)
    print()
    print('signature:', sig)
