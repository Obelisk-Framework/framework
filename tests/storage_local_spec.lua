-- tests/storage_local_spec.lua
-- Run: lua5.4 tests/storage_local_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'
dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/Services/storage/local.lua')
-- StorageLocal.url() delegates to Storage.baseUrl() (StorageService.lua) to
-- build an absolute, resource-prefixed URL — load it too so that resolves.
dofile(ROOT .. '/core/server/Services/StorageService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s', msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

StorageLocal.configure({ basePath = 'storage', urlPrefix = '/storage' })

test('put writes the file and returns an absolute, resource-prefixed url', function()
    local url = StorageLocal.put('photos/a.jpg', 'binarydata123', 'image/jpeg')
    truthy(url:find('http://127.0.0.1:', 1, true), 'expected an absolute http://127.0.0.1:<port> URL')
    truthy(url:find('/storage/photos/a.jpg', 1, true), 'expected the URL to end at /storage/photos/a.jpg')
end)

test('a file written by put can be read back byte-for-byte via LoadResourceFile', function()
    StorageLocal.put('roundtrip.txt', 'hello world', 'text/plain')
    local raw = LoadResourceFile(GetCurrentResourceName(), 'storage/roundtrip.txt')
    eq(raw, 'hello world')
end)

test('put creates nested directories that do not exist yet', function()
    local url = StorageLocal.put('deep/nested/path/file.bin', 'x', 'application/octet-stream')
    truthy(url:find('/storage/deep/nested/path/file.bin', 1, true))
    local raw = LoadResourceFile(GetCurrentResourceName(), 'storage/deep/nested/path/file.bin')
    eq(raw, 'x')
end)

test('url() returns an absolute, resource-prefixed URL matching put()', function()
    local url = StorageLocal.url('anything/here.png')
    truthy(url:find('http://127.0.0.1:', 1, true), 'expected an absolute http://127.0.0.1:<port> URL')
    truthy(url:find('/storage/anything/here.png', 1, true))
end)

test('delete removes a file that exists and returns true', function()
    StorageLocal.put('to-delete.txt', 'bye', 'text/plain')
    truthy(StorageLocal.delete('to-delete.txt'))
    eq(LoadResourceFile(GetCurrentResourceName(), 'storage/to-delete.txt'), nil)
end)

test('delete on a missing key does not error', function()
    local ok = pcall(function() StorageLocal.delete('never-existed.txt') end)
    truthy(ok, 'delete on a missing key should not error')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('storage_local_spec: %d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('  FAIL: ' .. f.name .. '\n    ' .. tostring(f.err)) end
if #failures > 0 then os.exit(1) end
