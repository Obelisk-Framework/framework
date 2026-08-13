-- tests/storage_upload_handler_spec.lua
-- Run: lua5.4 tests/storage_upload_handler_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'
dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/Services/storage/local.lua')
dofile(ROOT .. '/core/server/Services/storage/sha256.lua')
dofile(ROOT .. '/core/server/Services/storage/sigv4.lua')
dofile(ROOT .. '/core/server/Services/storage/s3.lua')
dofile(ROOT .. '/core/server/Services/StorageService.lua')
dofile(ROOT .. '/core/server/Services/storage/upload_handler.lua')

Storage.init() -- defaults to the local driver; upload_handler calls Storage.put

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s', msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

-- Builds a real multipart/form-data body: one "token" field, one "files[]" file field.
local function buildMultipartBody(boundary, token, fileBytes)
    local parts = {}
    parts[#parts+1] = '--' .. boundary .. '\r\n'
    parts[#parts+1] = 'Content-Disposition: form-data; name="token"\r\n\r\n'
    parts[#parts+1] = token .. '\r\n'
    parts[#parts+1] = '--' .. boundary .. '\r\n'
    parts[#parts+1] = 'Content-Disposition: form-data; name="files[]"; filename="shot.jpg"\r\n'
    parts[#parts+1] = 'Content-Type: image/jpeg\r\n\r\n'
    parts[#parts+1] = fileBytes .. '\r\n'
    parts[#parts+1] = '--' .. boundary .. '--\r\n'
    return table.concat(parts)
end

-- Fake req/res matching the subset of the real FXServer HTTP API this
-- handler uses. setDataHandler's callback is invoked synchronously here
-- (the stub SetHttpHandler doesn't simulate real network timing).
local function fakeRequest(body, boundary)
    return {
        path = '/storage/upload',
        headers = { ['content-type'] = 'multipart/form-data; boundary=' .. boundary },
        setDataHandler = function(_self, cb) cb(body) end,
    }
end
local function fakeGetRequest(path)
    return { method = 'GET', path = path, headers = {} }
end
local function fakeResponse()
    local res = { status = nil, headers = nil, body = nil }
    res.writeHead = function(_self, status, headers) res.status = status; res.headers = headers end
    res.send = function(_self, body) res.body = body end
    return res
end

test('a valid token uploads the file and responds 200 with a url', function()
    local token = Storage.mintUploadToken('phone-photos/test1.jpg', 'image/jpeg')
    local boundary = 'TESTBOUNDARY123'
    local body = buildMultipartBody(boundary, token, 'fake-jpeg-bytes')
    local req, res = fakeRequest(body, boundary), fakeResponse()

    _registeredHttpHandler(req, res)

    eq(res.status, 200)
    truthy(res.body:find('/storage/phone%-photos/test1%.jpg'), 'response body should contain the stored url')
end)

test('an unknown token is rejected with 403', function()
    local boundary = 'TESTBOUNDARY456'
    local body = buildMultipartBody(boundary, 'not-a-real-token', 'bytes')
    local req, res = fakeRequest(body, boundary), fakeResponse()

    _registeredHttpHandler(req, res)

    eq(res.status, 403)
end)

test('a token can only be used once', function()
    local token = Storage.mintUploadToken('phone-photos/test2.jpg', 'image/jpeg')
    local boundary = 'TESTBOUNDARY789'
    local body = buildMultipartBody(boundary, token, 'bytes')

    local req1, res1 = fakeRequest(body, boundary), fakeResponse()
    _registeredHttpHandler(req1, res1)
    eq(res1.status, 200)

    local req2, res2 = fakeRequest(body, boundary), fakeResponse()
    _registeredHttpHandler(req2, res2)
    eq(res2.status, 403, 'a second use of the same token should be rejected')
end)

test('a request to a different path is not handled here (falls through with 404)', function()
    local req = { path = '/something/else', headers = {}, setDataHandler = function(_self, cb) cb('') end }
    local res = fakeResponse()
    _registeredHttpHandler(req, res)
    eq(res.status, 404)
end)

test('GET on a key that was put() returns 200 with the stored bytes', function()
    Storage.put('phone-photos/get-test.jpg', 'hello-bytes', 'image/jpeg')

    local req, res = fakeGetRequest('/storage/phone-photos/get-test.jpg'), fakeResponse()
    _registeredHttpHandler(req, res)

    eq(res.status, 200)
    eq(res.body, 'hello-bytes')
    truthy(res.headers['Content-Type'], 'expected a Content-Type header')
end)

test('GET on a missing key returns 404', function()
    local req, res = fakeGetRequest('/storage/phone-photos/does-not-exist.jpg'), fakeResponse()
    _registeredHttpHandler(req, res)

    eq(res.status, 404)
end)

test('GET with a path-traversal key is rejected with 404, not loaded', function()
    local req, res = fakeGetRequest('/storage/../../server.cfg'), fakeResponse()
    _registeredHttpHandler(req, res)

    eq(res.status, 404, 'a traversal key must not be loaded from disk')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('storage_upload_handler_spec: %d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('  FAIL: ' .. f.name .. '\n    ' .. tostring(f.err)) end
if #failures > 0 then os.exit(1) end
