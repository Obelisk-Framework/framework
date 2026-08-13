-- tests/sha256_spec.lua
-- Run: lua5.4 tests/sha256_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'
dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/Services/storage/sha256.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s', msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('sha256 of empty string matches FIPS 180-4 test vector', function()
    eq(Sha256.hex(Sha256.digest('')), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
end)

test('sha256 of "abc" matches FIPS 180-4 test vector', function()
    eq(Sha256.hex(Sha256.digest('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
end)

test('sha256 of a 64-byte-boundary-crossing message does not error', function()
    -- exercises the multi-chunk path (one 64-byte block of padding needed)
    local msg = string.rep('a', 55) -- 55 bytes: padding pushes this into a second block
    local digest = Sha256.hex(Sha256.digest(msg))
    eq(#digest, 64, 'hex digest should always be 64 chars')
end)

test('hmac-sha256 output is 32 raw bytes', function()
    local mac = Sha256.hmac('key', 'The quick brown fox jumps over the lazy dog')
    eq(#mac, 32, 'hmac digest should always be 32 raw bytes')
end)

test('hmac-sha256 is deterministic', function()
    local a = Sha256.hex(Sha256.hmac('key', 'message'))
    local b = Sha256.hex(Sha256.hmac('key', 'message'))
    eq(a, b)
end)

test('hmac-sha256 changes with the key', function()
    local a = Sha256.hex(Sha256.hmac('key1', 'message'))
    local b = Sha256.hex(Sha256.hmac('key2', 'message'))
    if a == b then error('expected different keys to produce different HMACs') end
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('sha256_spec: %d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('  FAIL: ' .. f.name .. '\n    ' .. tostring(f.err)) end
if #failures > 0 then os.exit(1) end
