-- tests/storage_s3_spec.lua
-- Run: lua5.4 tests/storage_s3_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'
dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/Services/storage/sha256.lua')
dofile(ROOT .. '/core/server/Services/storage/sigv4.lua')
dofile(ROOT .. '/core/server/Services/storage/s3.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s', msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end
local function contains(haystack, needle, msg)
    if not haystack:find(needle, 1, true) then
        error((msg or 'expected substring not found') .. '\n     looked for: ' .. needle .. '\n     inside:     ' .. haystack, 2)
    end
end

StorageS3.configure({
    endpoint = 'https://s3.us-east-1.amazonaws.com',
    bucket = 'obelisk-uploads',
    accessKey = 'AKIDEXAMPLE',
    secretKey = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    region = 'us-east-1',
})

test('url() is path-style: endpoint/bucket/key, no network call', function()
    eq(StorageS3.url('photos/a.jpg'), 'https://s3.us-east-1.amazonaws.com/obelisk-uploads/photos/a.jpg')
end)

test('put() issues a PUT to the path-style url with an Authorization header', function()
    local seen = nil
    _G.PerformHttpRequest = function(url, callback, method, data, headers)
        seen = { url = url, method = method, data = data, headers = headers }
        callback(200, '', {})
    end
    local url = StorageS3.put('photos/a.jpg', 'binarydata', 'image/jpeg')
    truthy(seen, 'PerformHttpRequest should have been called')
    eq(seen.url, 'https://s3.us-east-1.amazonaws.com/obelisk-uploads/photos/a.jpg')
    eq(seen.method, 'PUT')
    eq(seen.data, 'binarydata')
    truthy(seen.headers['Authorization'], 'expected an Authorization header')
    contains(seen.headers['Authorization'], 'AWS4-HMAC-SHA256')
    contains(seen.headers['Authorization'], 'AKIDEXAMPLE')
    eq(seen.headers['x-amz-content-sha256'], Sha256.hex(Sha256.digest('binarydata')))
    eq(seen.headers.host, 's3.us-east-1.amazonaws.com', 'host header must be set for SigV4 (regression: commit 222cabf)')
    eq(url, 'https://s3.us-east-1.amazonaws.com/obelisk-uploads/photos/a.jpg')
end)

test('put() surfaces a non-2xx response as a Lua error', function()
    _G.PerformHttpRequest = function(_url, callback, _method, _data, _headers)
        callback(403, 'Forbidden', {})
    end
    local ok = pcall(function() StorageS3.put('x.jpg', 'y', 'image/jpeg') end)
    eq(ok, false, 'expected put() to error on a 403 response')
end)

test('delete() issues a DELETE with a signed Authorization header', function()
    local seen = nil
    _G.PerformHttpRequest = function(url, callback, method, _data, headers)
        seen = { url = url, method = method, headers = headers }
        callback(204, '', {})
    end
    local ok = StorageS3.delete('photos/a.jpg')
    truthy(ok)
    eq(seen.method, 'DELETE')
    eq(seen.url, 'https://s3.us-east-1.amazonaws.com/obelisk-uploads/photos/a.jpg')
    truthy(seen.headers['Authorization'])
end)

test('delete() treats a 404 as success (already gone)', function()
    _G.PerformHttpRequest = function(_url, callback, _method, _data, _headers)
        callback(404, '', {})
    end
    eq(StorageS3.delete('missing.jpg'), true)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('storage_s3_spec: %d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('  FAIL: ' .. f.name .. '\n    ' .. tostring(f.err)) end
if #failures > 0 then os.exit(1) end
