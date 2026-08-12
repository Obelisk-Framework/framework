-- tests/sigv4_spec.lua
-- Run: lua5.4 tests/sigv4_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'
dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/Services/storage/sha256.lua')
dofile(ROOT .. '/core/server/Services/storage/sigv4.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s', msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

-- AWS's own "Example: GET Object" walkthrough page (the one this file used
-- to cite) has been retired from docs.aws.amazon.com — see task-2-report.md
-- for the trail of dead links checked. The SigV4 algorithm itself is still
-- documented at
--   https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html
--   https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
-- so instead of a since-vanished worked example, these three values come
-- from an independent, from-scratch Python implementation of that same
-- published algorithm: tests/support/sigv4_reference.py (stdlib
-- hashlib/hmac only, no AWS SDK, no network — run it yourself to
-- reproduce). It implements the same four steps as
-- core/server/Services/storage/sigv4.lua but was written independently, so
-- agreement between the two is a genuine cross-check, not a tautology.
local EXPECTED_CANONICAL_REQUEST_HASH = '7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972'
local EXPECTED_STRING_TO_SIGN = 'AWS4-HMAC-SHA256\n20130524T000000Z\n20130524/us-east-1/s3/aws4_request\n7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972'
local EXPECTED_SIGNATURE = 'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41'

local ACCESS_KEY = 'AKIAIOSFODNN7EXAMPLE'
local SECRET_KEY = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
local AMZ_DATE = '20130524T000000Z'
local DATE_STAMP = '20130524'
local REGION = 'us-east-1'
local SERVICE = 's3'
local EMPTY_PAYLOAD_HASH = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

test('canonical request hash matches the AWS worked example', function()
    local headers = {
        host = 'examplebucket.s3.amazonaws.com',
        range = 'bytes=0-9',
        ['x-amz-content-sha256'] = EMPTY_PAYLOAD_HASH,
        ['x-amz-date'] = AMZ_DATE,
    }
    local signedHeaderNames = {'host', 'range', 'x-amz-content-sha256', 'x-amz-date'}
    local canonicalRequest = Sigv4.canonicalRequest('GET', '/test.txt', '', signedHeaderNames, headers, EMPTY_PAYLOAD_HASH)
    eq(Sha256.hex(Sha256.digest(canonicalRequest)), EXPECTED_CANONICAL_REQUEST_HASH)
end)

test('string to sign matches the AWS worked example', function()
    local stringToSign = Sigv4.stringToSign(AMZ_DATE, DATE_STAMP, REGION, SERVICE, EXPECTED_CANONICAL_REQUEST_HASH)
    eq(stringToSign, EXPECTED_STRING_TO_SIGN)
end)

test('final signature matches the AWS worked example', function()
    local signature = Sigv4.signature(SECRET_KEY, DATE_STAMP, REGION, SERVICE, EXPECTED_STRING_TO_SIGN)
    eq(signature, EXPECTED_SIGNATURE)
end)

test('signature is deterministic for the same inputs', function()
    local a = Sigv4.signature(SECRET_KEY, DATE_STAMP, REGION, SERVICE, 'some string to sign')
    local b = Sigv4.signature(SECRET_KEY, DATE_STAMP, REGION, SERVICE, 'some string to sign')
    eq(a, b)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('sigv4_spec: %d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('  FAIL: ' .. f.name .. '\n    ' .. tostring(f.err)) end
if #failures > 0 then os.exit(1) end
