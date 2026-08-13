-- tests/storage_service_spec.lua
-- Run: lua5.4 tests/storage_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'
dofile(scriptDir .. 'support/fivem_stubs.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s', msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

-- Fake the "local" adapter's public surface, sidestepping real file I/O.
-- StorageService dispatches to whichever global its selected driver names,
-- so replacing the global before init() runs is enough to fake it out.
local putCalls, deleteCalls = {}, {}
_G.StorageLocal = {
    configure = function(_) end,
    put = function(key, bytes, ct) putCalls[#putCalls+1] = {key=key, bytes=bytes, ct=ct}; return '/storage/' .. key end,
    delete = function(key) deleteCalls[#deleteCalls+1] = key; return true end,
    url = function(key) return '/storage/' .. key end,
}

dofile(ROOT .. '/core/server/Services/StorageService.lua')

test('init defaults to the local driver and succeeds with no convars set', function()
    truthy(Storage.init())
    truthy(Storage.ready)
end)

test('put dispatches to the selected adapter and returns its url', function()
    local url = Storage.put('a/b.jpg', 'data', 'image/jpeg')
    eq(url, '/storage/a/b.jpg')
    eq(#putCalls, 1)
    eq(putCalls[1].key, 'a/b.jpg')
end)

test('delete dispatches to the selected adapter', function()
    truthy(Storage.delete('a/b.jpg'))
    eq(#deleteCalls, 1)
    eq(deleteCalls[1], 'a/b.jpg')
end)

test('url dispatches to the selected adapter without a put/delete call', function()
    eq(Storage.url('some/key.png'), '/storage/some/key.png')
end)

test('an unknown storage_driver fails init loudly rather than defaulting silently', function()
    _G.GetConvar = function(name, default)
        if name == 'storage_driver' then return 'nonsense' end
        return default
    end
    local ok = Storage.init()
    eq(ok, false)
    _G.GetConvar = function(_, default) return default end -- restore for later tests
end)

test('selecting the s3 driver without required convars fails init loudly', function()
    _G.GetConvar = function(name, default)
        if name == 'storage_driver' then return 's3' end
        return default
    end
    local ok = Storage.init()
    eq(ok, false)
    _G.GetConvar = function(_, default) return default end
end)

test('uploadUrl builds an absolute, resource-prefixed URL to the upload endpoint', function()
    local url = Storage.uploadUrl()
    truthy(url:find('http://127.0.0.1:', 1, true), 'expected an absolute http://127.0.0.1:<port> URL')
    truthy(url:find('/storage/upload', 1, true), 'expected the URL to end at /storage/upload')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('storage_service_spec: %d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('  FAIL: ' .. f.name .. '\n    ' .. tostring(f.err)) end
if #failures > 0 then os.exit(1) end
