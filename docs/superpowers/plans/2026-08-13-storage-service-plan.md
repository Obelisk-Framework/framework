# Storage Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pluggable file-storage primitive (`Storage.put`/`Storage.delete`/`Storage.url`) with a local-disk provider and an S3-compatible provider, plus an `/storage/upload` HTTP endpoint that FiveM's `screenshot-basic` resource can POST to, per `docs/superpowers/specs/2026-08-13-storage-service-design.md`.

**Architecture:** `StorageService.lua` selects one adapter (`storage/local.lua` or `storage/s3.lua`) at boot based on the `storage_driver` convar, matching `Database.init()`'s driver-selection-by-convar pattern exactly. The S3 adapter signs requests with a hand-rolled AWS SigV4 implementation built on a pure-Lua SHA-256/HMAC-SHA256 (FXServer's Lua sandbox has no crypto library and no `io`/`os.execute` — file I/O goes through `SaveResourceFile`/`LoadResourceFile`, network I/O through `PerformHttpRequest`). The upload endpoint mints short-lived single-use tokens server-side and validates them before writing anything, so the endpoint is never an open write-anything primitive.

**Tech Stack:** Lua 5.4 (FXServer), hand-rolled test runner (`lua5.4 tests/*_spec.lua`, `dofile` + custom `test`/`eq`/`truthy` helpers — see any existing `tests/*_spec.lua` for the pattern), `tests/support/fivem_stubs.lua` for native stubs.

## Global Constraints

- No third-party Lua libraries — FXServer's Lua 5.4 sandbox only. SHA-256/HMAC/SigV4 must be pure Lua.
- File I/O (local provider) uses `SaveResourceFile(resourceName, path, data, length)` / `LoadResourceFile(resourceName, path)` / `GetResourcePath(resourceName)` natives — never `io.*`. These natives are resource-relative (`GetCurrentResourceName()`), not filesystem-absolute.
- Network I/O (S3 provider, and this task never adds a raw socket) uses `PerformHttpRequest(url, callback, method, data, headers)` wrapped in a `promise`/`Citizen.Await` pair to present a synchronous call, matching `Database.querySync`'s synchronous style (see `core/server/ORM/Database.lua:146-164` for the async/sync pairing convention this mirrors).
- Every new server file gets an entry in `fxmanifest.lua`'s `server_scripts` list — glob patterns here only match one directory level (`Services/*.lua` does NOT pick up `Services/storage/*.lua`).
- Boot fails fast (loud `print` + `return false`, no in-memory fallback) if the selected `storage_driver`'s required convars are missing, matching `Database.init()`'s FATAL-print pattern (`core/server/ORM/Database.lua:111-123`).
- Test files load stubs first via `dofile(scriptDir .. 'support/fivem_stubs.lua')`, then `dofile` the source files under test, in dependency order. Add new spec files to `package.json`'s `"test"` script.

---

### Task 1: Pure-Lua SHA-256 + HMAC-SHA256

**Files:**
- Create: `core/server/Services/storage/sha256.lua`
- Test: `tests/sha256_spec.lua`

**Interfaces:**
- Produces: `Sha256.digest(msg)` → raw 32-byte string. `Sha256.hex(rawBytes)` → lowercase hex string. `Sha256.hmac(key, msg)` → raw 32-byte string (HMAC-SHA256).

- [ ] **Step 1: Write the failing tests**

```lua
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 tests/sha256_spec.lua`
Expected: error, `core/server/Services/storage/sha256.lua` does not exist yet.

- [ ] **Step 3: Write the implementation**

```lua
-- core/server/Services/storage/sha256.lua
--- Pure-Lua SHA-256 + HMAC-SHA256. FXServer's Lua 5.4 sandbox has no crypto
--- library, so this exists to give StorageService's S3 adapter (AWS SigV4
--- needs HMAC-SHA256 chained four times per request) something to sign with.
--- Uses Lua 5.4's native 64-bit integers and bitwise operators (&, |, ~, <<,
--- >>) — no bit32 library needed.
Sha256 = {}

local MASK32 = 0xFFFFFFFF

local K = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

local function rrotate(x, n)
  x = x & MASK32
  return ((x >> n) | (x << (32 - n))) & MASK32
end

local function toBytesBE32(n)
  return string.char((n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
end

--- @param msg string
--- @return string raw 32-byte digest
function Sha256.digest(msg)
  local H = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}

  local bitlen = #msg * 8
  local padded = msg .. '\128'
  while (#padded % 64) ~= 56 do padded = padded .. '\0' end
  for i = 7, 0, -1 do
    padded = padded .. string.char((bitlen >> (i * 8)) & 0xFF)
  end

  for chunkStart = 1, #padded, 64 do
    local w = {}
    for i = 0, 15 do
      local o = chunkStart + i * 4
      w[i] = (padded:byte(o) << 24) | (padded:byte(o + 1) << 16) | (padded:byte(o + 2) << 8) | padded:byte(o + 3)
    end
    for i = 16, 63 do
      local s0 = rrotate(w[i - 15], 7) ~ rrotate(w[i - 15], 18) ~ (w[i - 15] >> 3)
      local s1 = rrotate(w[i - 2], 17) ~ rrotate(w[i - 2], 19) ~ (w[i - 2] >> 10)
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & MASK32
    end

    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for i = 0, 63 do
      local s1 = rrotate(e, 6) ~ rrotate(e, 11) ~ rrotate(e, 25)
      local ch = (e & f) ~ ((~e & MASK32) & g)
      local temp1 = (h + s1 + ch + K[i + 1] + w[i]) & MASK32
      local s0 = rrotate(a, 2) ~ rrotate(a, 13) ~ rrotate(a, 22)
      local maj = (a & b) ~ (a & c) ~ (b & c)
      local temp2 = (s0 + maj) & MASK32
      h = g; g = f; f = e; e = (d + temp1) & MASK32
      d = c; c = b; b = a; a = (temp1 + temp2) & MASK32
    end

    H[1] = (H[1] + a) & MASK32; H[2] = (H[2] + b) & MASK32
    H[3] = (H[3] + c) & MASK32; H[4] = (H[4] + d) & MASK32
    H[5] = (H[5] + e) & MASK32; H[6] = (H[6] + f) & MASK32
    H[7] = (H[7] + g) & MASK32; H[8] = (H[8] + h) & MASK32
  end

  local out = {}
  for i = 1, 8 do out[i] = toBytesBE32(H[i]) end
  return table.concat(out)
end

--- @param raw string 32-byte raw digest
--- @return string 64-char lowercase hex
function Sha256.hex(raw)
  local out = {}
  for i = 1, #raw do out[i] = string.format('%02x', raw:byte(i)) end
  return table.concat(out)
end

--- @param key string
--- @param msg string
--- @return string raw 32-byte HMAC-SHA256
function Sha256.hmac(key, msg)
  local blockSize = 64
  if #key > blockSize then key = Sha256.digest(key) end
  if #key < blockSize then key = key .. string.rep('\0', blockSize - #key) end

  local ipad, opad = {}, {}
  for i = 1, blockSize do
    local kb = key:byte(i)
    ipad[i] = string.char(kb ~ 0x36)
    opad[i] = string.char(kb ~ 0x5c)
  end

  local inner = Sha256.digest(table.concat(ipad) .. msg)
  return Sha256.digest(table.concat(opad) .. inner)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 tests/sha256_spec.lua`
Expected: `sha256_spec: 6/6 passed`

- [ ] **Step 5: Commit**

```bash
git add core/server/Services/storage/sha256.lua tests/sha256_spec.lua
git commit -m "feat(storage): add pure-Lua SHA-256 / HMAC-SHA256"
```

---

### Task 2: AWS SigV4 signer

**Files:**
- Create: `core/server/Services/storage/sigv4.lua`
- Test: `tests/sigv4_spec.lua`

**Interfaces:**
- Consumes: `Sha256.digest`, `Sha256.hex`, `Sha256.hmac` (Task 1).
- Produces: `Sigv4.canonicalRequest(method, canonicalUri, canonicalQuery, signedHeaderNames, headers, payloadHash)` → string. `Sigv4.stringToSign(amzDate, dateStamp, region, service, canonicalRequestHash)` → string. `Sigv4.signature(secretKey, dateStamp, region, service, stringToSign)` → 64-char lowercase hex string.

- [ ] **Step 1: Write the failing test**

This test reuses AWS's own published worked example (GET a private S3 object) so the expected hex values are verifiably correct rather than hand-typed from memory. **Before filling in the three `EXPECTED_*` constants below, open
<https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html>,
find the "Example: GET Object" walkthrough (bucket `examplebucket`, object
`test.txt`, region `us-east-1`, date `20130524T000000Z`, access key
`AKIAIOSFODNN7EXAMPLE`, secret `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY`),
and copy its three intermediate values (canonical request's SHA-256 hash,
the string-to-sign, and the final signature) verbatim** — do not hand-type
them from memory; a transcription error here is exactly the class of bug
this test exists to catch.

```lua
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

-- Copied verbatim from AWS's "Example: GET Object" walkthrough — see the
-- doc link in this file's header comment. Do not hand-type these.
local EXPECTED_CANONICAL_REQUEST_HASH = 'FILL_IN_FROM_AWS_DOC'
local EXPECTED_STRING_TO_SIGN = 'FILL_IN_FROM_AWS_DOC'
local EXPECTED_SIGNATURE = 'FILL_IN_FROM_AWS_DOC'

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
```

- [ ] **Step 2: Fill in the three `EXPECTED_*` constants**

Open the AWS doc link in the file's header comment, find the "Example: GET Object" section, and replace the three `'FILL_IN_FROM_AWS_DOC'` placeholders with the exact values AWS publishes for the canonical request's hash, the string-to-sign, and the final signature.

- [ ] **Step 3: Run test to verify it fails**

Run: `lua5.4 tests/sigv4_spec.lua`
Expected: FAIL, `core/server/Services/storage/sigv4.lua` does not exist yet.

- [ ] **Step 4: Write the implementation**

```lua
-- core/server/Services/storage/sigv4.lua
--- AWS Signature Version 4. Pure functions over strings — no I/O, no
--- knowledge of PerformHttpRequest. core/server/Services/storage/s3.lua
--- builds the actual request and calls these.
Sigv4 = {}

--- @param method string e.g. 'GET', 'PUT', 'DELETE'
--- @param canonicalUri string path, already URI-encoded, e.g. '/test.txt'
--- @param canonicalQuery string query string, already sorted/encoded, or ''
--- @param signedHeaderNames string[] lowercase header names, already sorted
--- @param headers table<string,string> lowercase name -> value, trimmed
--- @param payloadHash string sha256 hex of the request body ('' body -> the well-known empty-string hash)
--- @return string
function Sigv4.canonicalRequest(method, canonicalUri, canonicalQuery, signedHeaderNames, headers, payloadHash)
  local canonicalHeaders = {}
  for _, name in ipairs(signedHeaderNames) do
    canonicalHeaders[#canonicalHeaders + 1] = name .. ':' .. headers[name] .. '\n'
  end
  return table.concat({
    method,
    canonicalUri,
    canonicalQuery,
    table.concat(canonicalHeaders),
    table.concat(signedHeaderNames, ';'),
    payloadHash,
  }, '\n')
end

--- @param amzDate string e.g. '20130524T000000Z'
--- @param dateStamp string e.g. '20130524'
--- @param region string e.g. 'us-east-1'
--- @param service string e.g. 's3'
--- @param canonicalRequestHash string sha256 hex of the canonical request
--- @return string
function Sigv4.stringToSign(amzDate, dateStamp, region, service, canonicalRequestHash)
  local scope = dateStamp .. '/' .. region .. '/' .. service .. '/aws4_request'
  return table.concat({'AWS4-HMAC-SHA256', amzDate, scope, canonicalRequestHash}, '\n')
end

--- @param secretKey string
--- @param dateStamp string
--- @param region string
--- @param service string
--- @return string raw 32-byte signing key
function Sigv4.signingKey(secretKey, dateStamp, region, service)
  local kDate = Sha256.hmac('AWS4' .. secretKey, dateStamp)
  local kRegion = Sha256.hmac(kDate, region)
  local kService = Sha256.hmac(kRegion, service)
  return Sha256.hmac(kService, 'aws4_request')
end

--- @return string 64-char lowercase hex signature
function Sigv4.signature(secretKey, dateStamp, region, service, stringToSign)
  local key = Sigv4.signingKey(secretKey, dateStamp, region, service)
  return Sha256.hex(Sha256.hmac(key, stringToSign))
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `lua5.4 tests/sigv4_spec.lua`
Expected: `sigv4_spec: 4/4 passed`

If it fails, the bug is almost certainly in `EXPECTED_*` transcription (re-check against the AWS doc) rather than the signer — the algorithm here follows the spec directly.

- [ ] **Step 6: Commit**

```bash
git add core/server/Services/storage/sigv4.lua tests/sigv4_spec.lua
git commit -m "feat(storage): add AWS SigV4 signer"
```

---

### Task 3: Local storage adapter

**Files:**
- Create: `core/server/Services/storage/local.lua`
- Modify: `tests/support/fivem_stubs.lua` (add `SaveResourceFile`/`LoadResourceFile`/`GetResourcePath`/`RemoveResourceFile` stubs, real-filesystem-backed under a temp dir, since the test harness runs under vanilla `lua5.4` which does have `io`)
- Test: `tests/storage_local_spec.lua`

**Interfaces:**
- Produces: `StorageLocal.configure(cfg)` where `cfg = { basePath = string, urlPrefix = string }`. `StorageLocal.put(key, bytes, contentType)` → `url` string. `StorageLocal.delete(key)` → boolean. `StorageLocal.url(key)` → `url` string.

- [ ] **Step 1: Add file-native stubs**

`SaveResourceFile`/`LoadResourceFile`/`RemoveResourceFile` are FXServer natives that read/write files relative to a resource's own directory. Under vanilla `lua5.4` (no FXServer runtime), stub them with real `io` calls against a temp directory so `local.lua`'s tests exercise real file I/O without needing a running server.

```lua
-- append to tests/support/fivem_stubs.lua

-- Resource-relative file natives, backed by a real temp directory so
-- core/server/Services/storage/local.lua's tests exercise real file I/O.
-- Not resource-name-aware (single global root) — fine for this test suite,
-- which only ever runs as one "resource" at a time.
local RESOURCE_FILE_ROOT = os.tmpname()
os.remove(RESOURCE_FILE_ROOT) -- os.tmpname() creates the file; we want it as a directory
os.execute('mkdir -p ' .. RESOURCE_FILE_ROOT)

_G.GetCurrentResourceName = _G.GetCurrentResourceName or function() return 'core' end

_G.GetResourcePath = _G.GetResourcePath or function(_) return RESOURCE_FILE_ROOT end

local function ensureParentDir(fullPath)
    local dir = fullPath:match('(.*/)')
    if dir then os.execute('mkdir -p ' .. dir) end
end

_G.SaveResourceFile = _G.SaveResourceFile or function(_, path, data, _len)
    local full = RESOURCE_FILE_ROOT .. '/' .. path
    ensureParentDir(full)
    local f = io.open(full, 'wb')
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

_G.LoadResourceFile = _G.LoadResourceFile or function(_, path)
    local full = RESOURCE_FILE_ROOT .. '/' .. path
    local f = io.open(full, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

_G.RemoveResourceFile = _G.RemoveResourceFile or function(_, path)
    local full = RESOURCE_FILE_ROOT .. '/' .. path
    return os.remove(full) ~= nil
end
```

- [ ] **Step 2: Write the failing test**

```lua
-- tests/storage_local_spec.lua
-- Run: lua5.4 tests/storage_local_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'
dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/Services/storage/local.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s', msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

StorageLocal.configure({ basePath = 'storage', urlPrefix = '/storage' })

test('put writes the file and returns a url built from urlPrefix + key', function()
    local url = StorageLocal.put('photos/a.jpg', 'binarydata123', 'image/jpeg')
    eq(url, '/storage/photos/a.jpg')
end)

test('a file written by put can be read back byte-for-byte via LoadResourceFile', function()
    StorageLocal.put('roundtrip.txt', 'hello world', 'text/plain')
    local raw = LoadResourceFile(GetCurrentResourceName(), 'storage/roundtrip.txt')
    eq(raw, 'hello world')
end)

test('put creates nested directories that do not exist yet', function()
    local url = StorageLocal.put('deep/nested/path/file.bin', 'x', 'application/octet-stream')
    eq(url, '/storage/deep/nested/path/file.bin')
    local raw = LoadResourceFile(GetCurrentResourceName(), 'storage/deep/nested/path/file.bin')
    eq(raw, 'x')
end)

test('url() returns the same shape as put() without touching storage', function()
    eq(StorageLocal.url('anything/here.png'), '/storage/anything/here.png')
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `lua5.4 tests/storage_local_spec.lua`
Expected: FAIL, `core/server/Services/storage/local.lua` does not exist yet.

- [ ] **Step 4: Write the implementation**

```lua
-- core/server/Services/storage/local.lua
--- Local-disk storage provider. Files live under GetResourcePath(resource)
--- .. '/' .. basePath, written/read via the resource-relative file natives
--- (SaveResourceFile/LoadResourceFile/RemoveResourceFile) — FXServer's Lua
--- sandbox has no io library, so this cannot use io.open directly.
StorageLocal = {}

local config = { basePath = 'storage', urlPrefix = '/storage' }

--- @param cfg table { basePath: string, urlPrefix: string }
function StorageLocal.configure(cfg)
  config.basePath = cfg.basePath or config.basePath
  config.urlPrefix = cfg.urlPrefix or config.urlPrefix
end

local function resourcePath(key)
  return config.basePath .. '/' .. key
end

--- @param key string
--- @param bytes string raw file contents
--- @param _contentType string unused by the local provider (no metadata store)
--- @return string url
function StorageLocal.put(key, bytes, _contentType)
  SaveResourceFile(GetCurrentResourceName(), resourcePath(key), bytes, #bytes)
  return StorageLocal.url(key)
end

--- @param key string
--- @return boolean
function StorageLocal.delete(key)
  return RemoveResourceFile(GetCurrentResourceName(), resourcePath(key)) and true or false
end

--- @param key string
--- @return string url
function StorageLocal.url(key)
  return config.urlPrefix .. '/' .. key
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `lua5.4 tests/storage_local_spec.lua`
Expected: `storage_local_spec: 6/6 passed`

- [ ] **Step 6: Commit**

```bash
git add core/server/Services/storage/local.lua tests/storage_local_spec.lua tests/support/fivem_stubs.lua
git commit -m "feat(storage): add local-disk storage provider"
```

---

### Task 4: StorageService core (driver selection, dispatch, HTTP handler mount, wiring)

**Files:**
- Create: `core/server/Services/StorageService.lua`
- Modify: `fxmanifest.lua` (add `storage/*.lua` before the `Services/*.lua` glob, plus the explicit `StorageService.lua` entry)
- Modify: `core/server/bootstrap.lua` (call `Storage.init()`)
- Modify: `server.cfg.example` (repo root, one level above this worktree — see note in Step 6)
- Modify: `.gitignore` (ignore the local storage directory)
- Test: `tests/storage_service_spec.lua`

**Interfaces:**
- Consumes: `StorageLocal.configure/put/delete/url` (Task 3). `StorageS3` (Task 5) is referenced by name only — `StorageService.lua` must load and pass Task 4's tests before Task 5 exists, so the S3 branch is written now but only exercised once Task 5 lands.
- Produces: `Storage.init()` → boolean (mirrors `Database.init()`). `Storage.put(key, bytes, contentType)` → `url` string. `Storage.delete(key)` → boolean. `Storage.url(key)` → `url` string. `Storage.ready` → boolean.

- [ ] **Step 1: Write the failing test**

```lua
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

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('storage_service_spec: %d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('  FAIL: ' .. f.name .. '\n    ' .. tostring(f.err)) end
if #failures > 0 then os.exit(1) end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 tests/storage_service_spec.lua`
Expected: FAIL, `core/server/Services/StorageService.lua` does not exist yet.

- [ ] **Step 3: Write the implementation**

```lua
-- core/server/Services/StorageService.lua
--- Generic file storage: put/delete/url, dispatched to one adapter chosen at
--- boot by the storage_driver convar. Mirrors Database.init()'s driver-
--- selection-by-convar pattern (core/server/ORM/Database.lua) — same
--- fail-fast-with-a-loud-print behaviour, no in-memory fallback.
Storage = {}

Storage.ready = false
Storage.driver = nil -- 'local' | 's3'
local adapter = nil  -- the selected adapter table (StorageLocal or StorageS3)

local function failInit(lines)
  Storage.ready = false
  print('[Storage] ============================================================')
  for _, line in ipairs(lines) do print('[Storage] ' .. line) end
  print('[Storage] ============================================================')
  return false
end

--- @return boolean ready
function Storage.init()
  local driver = GetConvar('storage_driver', 'local')

  if driver == 'local' then
    StorageLocal.configure({
      basePath = GetConvar('storage_local_path', 'storage'),
      urlPrefix = '/storage',
    })
    adapter = StorageLocal
  elseif driver == 's3' then
    local endpoint = GetConvar('storage_s3_endpoint', '')
    local bucket = GetConvar('storage_s3_bucket', '')
    local accessKey = GetConvar('storage_s3_key', '')
    local secretKey = GetConvar('storage_s3_secret', '')
    if endpoint == '' or bucket == '' or accessKey == '' or secretKey == '' then
      return failInit({
        'FATAL: storage_driver "s3" requires storage_s3_endpoint, storage_s3_bucket,',
        'storage_s3_key and storage_s3_secret to all be set.',
        'Set them in server.cfg, or switch storage_driver back to "local".',
      })
    end
    StorageS3.configure({
      endpoint = endpoint,
      bucket = bucket,
      accessKey = accessKey,
      secretKey = secretKey,
      region = GetConvar('storage_s3_region', 'us-east-1'),
    })
    adapter = StorageS3
  else
    return failInit({
      'FATAL: unknown storage_driver "' .. tostring(driver) .. '".',
      'Valid values: "local" (default), "s3".',
    })
  end

  Storage.driver = driver
  Storage.ready = true
  print('[Storage] Initialized (driver: ' .. driver .. ')')
  return true
end

--- @param key string
--- @param bytes string raw file contents
--- @param contentType string MIME type, e.g. 'image/jpeg'
--- @return string url
function Storage.put(key, bytes, contentType)
  return adapter.put(key, bytes, contentType)
end

--- @param key string
--- @return boolean
function Storage.delete(key)
  return adapter.delete(key)
end

--- @param key string
--- @return string url
function Storage.url(key)
  return adapter.url(key)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 tests/storage_service_spec.lua`
Expected: `storage_service_spec: 6/6 passed`

- [ ] **Step 5: Wire into `fxmanifest.lua` and `bootstrap.lua`**

In `fxmanifest.lua`, inside `server_scripts`, add the storage adapter glob
*before* the existing `'core/server/Services/*.lua'` line (so both explicit
adapter files and the `StorageService.lua` catch-all load; order relative to
each other doesn't matter since `Storage.init()` runs later, from
`bootstrap.lua`, well after every file has loaded):

```lua
    -- Core Services
    'core/server/Services/Hooks.lua',
    'core/server/Services/ActionService.lua',
    'core/server/Services/InteractionService.lua',
    'core/server/Services/PolicyService.lua',
    'core/server/Services/NotificationService.lua',
    'core/server/Services/ProgressService.lua',
    'core/server/Services/KeybindService.lua',
    'core/server/Services/storage/*.lua',
    'core/server/Services/*.lua',
```

In `core/server/bootstrap.lua`, add the storage init call. It has no
dependency on `Database` (storage doesn't touch the DB), so it can run
before the `Database.init()` thread — put it right at the top of the file,
outside the existing `Citizen.CreateThread`, since nothing else needs to
wait for it:

```lua
-- Initialize Storage (no DB dependency, so this doesn't need to wait on the
-- Database.init() thread below).
if not Storage.init() then
    print('[Obelisk] WARNING: storage service failed to initialize. See the [Storage] FATAL message above. Continuing without file storage.')
end
```

Place this new block directly above the existing
`-- Initialize Database` comment.

- [ ] **Step 6: Add server.cfg convars and .gitignore entry**

`server.cfg.example` lives one directory above this worktree, at the
top-level `obelisk-framework` repo (not inside the `core` repo this plan's
other files live in) — edit it directly at
`<repo-root>/server.cfg.example`, add near the existing `db_driver` block:

```
# "local" (default) or "s3".
set storage_driver "local"

# local provider
set storage_local_path "storage"

# s3 provider (S3-compatible: AWS S3, MinIO, R2, Spaces, ...)
# set storage_s3_endpoint "https://s3.us-east-1.amazonaws.com"
# set storage_s3_bucket "obelisk-uploads"
# set storage_s3_key "changeme"
# set storage_s3_secret "changeme"
# set storage_s3_region "us-east-1"
```

Then copy the same block into `<repo-root>/server.cfg` (the real,
gitignored config file this repo already keeps alongside the example — see
this worktree's own `docs/superpowers/specs/2026-08-13-storage-service-design.md`
for why `storage_local_path` should stay gitignored the same way).

In this worktree's `.gitignore` (`core/.gitignore`), add:

```
storage/
```

- [ ] **Step 7: Run the full suite and commit**

Run: `lua5.4 tests/storage_service_spec.lua && lua5.4 tests/storage_local_spec.lua && lua5.4 tests/sigv4_spec.lua && lua5.4 tests/sha256_spec.lua`
Expected: all four report full pass counts.

```bash
git add core/server/Services/StorageService.lua tests/storage_service_spec.lua fxmanifest.lua core/server/bootstrap.lua .gitignore
git commit -m "feat(storage): add StorageService driver dispatch, wire into boot"
```

(The `server.cfg.example`/`server.cfg` edit from Step 6 lives in the
top-level `obelisk-framework` repo, a separate git repository from this
`core` worktree — commit it there separately with its own message, e.g.
`git -C <repo-root> add server.cfg.example server.cfg && git -C <repo-root> commit -m "Add storage_driver config for the new storage service"`.)

---

### Task 5: S3-compatible storage adapter

**Files:**
- Create: `core/server/Services/storage/s3.lua`
- Modify: `tests/support/fivem_stubs.lua` (add a spyable `PerformHttpRequest` stub)
- Test: `tests/storage_s3_spec.lua`

**Interfaces:**
- Consumes: `Sigv4.canonicalRequest/stringToSign/signature` (Task 2), `Sha256.digest/hex` (Task 1).
- Produces: `StorageS3.configure(cfg)` where `cfg = { endpoint, bucket, accessKey, secretKey, region }`. `StorageS3.put(key, bytes, contentType)` → `url`. `StorageS3.delete(key)` → boolean. `StorageS3.url(key)` → `url`.

- [ ] **Step 1: Add a spyable `PerformHttpRequest` stub**

```lua
-- append to tests/support/fivem_stubs.lua

-- PerformHttpRequest(url, callback, method, data, headers). Real FXServer
-- calls back asynchronously; here it calls back synchronously (same trick
-- Citizen.CreateThread's stub above uses) so storage_s3_spec.lua's
-- Citizen.Await(promise) pattern still works without ever actually waiting.
-- Tests install their own _G.PerformHttpRequest override when they need to
-- assert on the request that was made or control the response.
_G.PerformHttpRequest = _G.PerformHttpRequest or function(_url, callback, _method, _data, _headers)
    callback(200, '', {})
end
```

- [ ] **Step 2: Write the failing test**

These tests assert on the *shape* of the request StorageS3 builds (method,
URL, headers) by installing a spy `PerformHttpRequest`, never making a real
network call.

```lua
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `lua5.4 tests/storage_s3_spec.lua`
Expected: FAIL, `core/server/Services/storage/s3.lua` does not exist yet.

- [ ] **Step 4: Write the implementation**

```lua
-- core/server/Services/storage/s3.lua
--- S3-compatible storage provider (AWS S3, MinIO, R2, Spaces — anything
--- speaking the S3 API at a path-style endpoint). Signs every request with
--- AWS SigV4 (core/server/Services/storage/sigv4.lua). Uses
--- PerformHttpRequest wrapped in a promise/Citizen.Await pair to present a
--- synchronous call, matching Database.querySync's sync-over-async style.
StorageS3 = {}

local config = { endpoint = '', bucket = '', accessKey = '', secretKey = '', region = 'us-east-1' }

--- @param cfg table { endpoint, bucket, accessKey, secretKey, region }
function StorageS3.configure(cfg)
  for k, v in pairs(cfg) do config[k] = v end
end

local function amzDateNow()
  -- os.date with '!' formats in UTC, required by SigV4.
  return os.date('!%Y%m%dT%H%M%SZ'), os.date('!%Y%m%d')
end

--- @param method string
--- @param key string
--- @param body string
--- @return string url, table headers
local function signedRequest(method, key, body)
  local url = config.endpoint .. '/' .. config.bucket .. '/' .. key
  local host = url:match('^https?://([^/]+)')
  local amzDate, dateStamp = amzDateNow()
  local payloadHash = Sha256.hex(Sha256.digest(body or ''))

  local headers = {
    host = host,
    ['x-amz-content-sha256'] = payloadHash,
    ['x-amz-date'] = amzDate,
  }
  local signedHeaderNames = {'host', 'x-amz-content-sha256', 'x-amz-date'}
  table.sort(signedHeaderNames)

  local canonicalUri = '/' .. config.bucket .. '/' .. key
  local canonicalRequest = Sigv4.canonicalRequest(method, canonicalUri, '', signedHeaderNames, headers, payloadHash)
  local canonicalRequestHash = Sha256.hex(Sha256.digest(canonicalRequest))
  local stringToSign = Sigv4.stringToSign(amzDate, dateStamp, config.region, 's3', canonicalRequestHash)
  local signature = Sigv4.signature(config.secretKey, dateStamp, config.region, 's3', stringToSign)

  local credentialScope = dateStamp .. '/' .. config.region .. '/s3/aws4_request'
  local authorization = string.format(
    'AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s',
    config.accessKey, credentialScope, table.concat(signedHeaderNames, ';'), signature
  )

  local outHeaders = {
    ['x-amz-date'] = amzDate,
    ['x-amz-content-sha256'] = payloadHash,
    ['Authorization'] = authorization,
  }
  return url, outHeaders
end

--- Wraps PerformHttpRequest in a promise so callers get a synchronous call,
--- matching this framework's Database.querySync convention.
local function httpSync(method, url, body, headers)
  local p = promise.new()
  PerformHttpRequest(url, function(status, respBody, respHeaders)
    p:resolve({ status = status, body = respBody, headers = respHeaders })
  end, method, body or '', headers)
  return Citizen.Await(p)
end

--- @param key string
--- @param bytes string
--- @param contentType string
--- @return string url
function StorageS3.put(key, bytes, contentType)
  local url, headers = signedRequest('PUT', key, bytes)
  headers['Content-Type'] = contentType
  local result = httpSync('PUT', url, bytes, headers)
  if result.status < 200 or result.status >= 300 then
    error(string.format('[StorageS3] put failed for key "%s": HTTP %d %s', key, result.status, tostring(result.body)), 2)
  end
  return url
end

--- @param key string
--- @return boolean
function StorageS3.delete(key)
  local url, headers = signedRequest('DELETE', key, '')
  local result = httpSync('DELETE', url, '', headers)
  -- 404 counts as success: the end state ("this key has no object") matches
  -- what the caller wanted, same as StorageLocal.delete not erroring on a
  -- missing file.
  return (result.status >= 200 and result.status < 300) or result.status == 404
end

--- @param key string
--- @return string url
function StorageS3.url(key)
  return config.endpoint .. '/' .. config.bucket .. '/' .. key
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `lua5.4 tests/storage_s3_spec.lua`
Expected: `storage_s3_spec: 5/5 passed`

- [ ] **Step 6: Run the full suite (Task 4's fake-adapter test still passes since it never loads the real S3 adapter)**

Run: `lua5.4 tests/storage_service_spec.lua && lua5.4 tests/storage_local_spec.lua && lua5.4 tests/storage_s3_spec.lua && lua5.4 tests/sigv4_spec.lua && lua5.4 tests/sha256_spec.lua`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add core/server/Services/storage/s3.lua tests/storage_s3_spec.lua tests/support/fivem_stubs.lua
git commit -m "feat(storage): add S3-compatible storage provider"
```

---

### Task 6: Upload token minting + `/storage/upload` HTTP endpoint

**Files:**
- Create: `core/server/Services/storage/upload_handler.lua`
- Modify: `core/server/Services/StorageService.lua` (add `Storage.mintUploadToken`, wire the handler into `Storage.init()`)
- Modify: `tests/support/fivem_stubs.lua` (add a `SetHttpHandler` stub that just records the registered function, so tests can call it directly)
- Test: `tests/storage_upload_handler_spec.lua`
- Modify: `package.json` (add all five new spec files to the `"test"` script)

**Interfaces:**
- Consumes: `Storage.put` (Task 4/3/5).
- Produces: `Storage.mintUploadToken(key, contentType)` → `token` string. The registered HTTP handler (not directly called by other Lua code — exercised only via `SetHttpHandler`'s recorded function in tests, and by `screenshot-basic` in production).

- [ ] **Step 1: Add a `SetHttpHandler` stub**

```lua
-- append to tests/support/fivem_stubs.lua

-- SetHttpHandler(fn) registers fn as THE http handler for this resource.
-- Real FXServer calls it with (req, res) per request. The stub just records
-- the last-registered handler so tests can invoke it directly with fake
-- req/res tables — see tests/storage_upload_handler_spec.lua for the shape
-- those fakes take.
_G._registeredHttpHandler = nil
_G.SetHttpHandler = _G.SetHttpHandler or function(fn)
    _G._registeredHttpHandler = fn
end
```

- [ ] **Step 2: Write the failing test**

The real FXServer `req` object exposes `req.path`, `req.headers`, and
`req.setDataHandler(callback)` (callback receives the full raw body as a
string once received); `res` exposes `res.writeHead(status, headers)` and
`res.send(body)`. The handler must parse `multipart/form-data` itself (no
library available) — this test drives that parsing end-to-end by building a
real multipart body by hand.

```lua
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

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('storage_upload_handler_spec: %d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('  FAIL: ' .. f.name .. '\n    ' .. tostring(f.err)) end
if #failures > 0 then os.exit(1) end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `lua5.4 tests/storage_upload_handler_spec.lua`
Expected: FAIL — `Storage.mintUploadToken` doesn't exist yet, and `core/server/Services/storage/upload_handler.lua` doesn't exist.

- [ ] **Step 4: Add `Storage.mintUploadToken` to `StorageService.lua`**

Add this to `core/server/Services/StorageService.lua`, after `Storage.url`:

```lua
local PENDING_UPLOADS = {} -- token -> { key, contentType, expiresAt }
local TOKEN_TTL_SECONDS = 60

local function randomToken()
  local chars = '0123456789abcdefghijklmnopqrstuvwxyz'
  local out = {}
  for i = 1, 32 do
    local n = math.random(1, #chars)
    out[i] = chars:sub(n, n)
  end
  return table.concat(out)
end

--- Registers a pending upload and returns a short-lived, single-use token
--- for it. The caller hands this token to the client, which posts it (with
--- the file) to POST /storage/upload — the handler only ever writes to the
--- exact `key` this call registered, never a key the client supplies.
--- @param key string
--- @param contentType string
--- @return string token
function Storage.mintUploadToken(key, contentType)
  local token = randomToken()
  PENDING_UPLOADS[token] = { key = key, contentType = contentType, expiresAt = os.time() + TOKEN_TTL_SECONDS }
  return token
end

--- Consumes a token if valid (exists, not expired). Single-use: removes it
--- either way once looked up, so a second call for the same token always
--- misses. Returns nil if the token was never valid.
--- @param token string
--- @return table|nil { key, contentType }
function Storage.consumeUploadToken(token)
  local entry = PENDING_UPLOADS[token]
  PENDING_UPLOADS[token] = nil
  if not entry then return nil end
  if entry.expiresAt < os.time() then return nil end
  return entry
end
```

- [ ] **Step 5: Write `upload_handler.lua`**

```lua
-- core/server/Services/storage/upload_handler.lua
--- POST /storage/upload — the endpoint FiveM's screenshot-basic resource
--- (or any other client-side capture) posts multipart/form-data to. Only
--- writes to a key a server-minted token already named (Storage.
--- mintUploadToken/consumeUploadToken in StorageService.lua) — never a key
--- the client supplies directly, so this is not an open write-anything
--- endpoint. Registered from Storage.init() via SetHttpHandler.

--- Extracts the boundary token from a `Content-Type: multipart/form-data;
--- boundary=XYZ` header value.
--- @param contentType string
--- @return string|nil boundary
local function parseBoundary(contentType)
  return contentType and contentType:match('boundary=([^;]+)')
end

--- Splits a multipart body into its named parts. Returns a table keyed by
--- the `name="..."` in each part's Content-Disposition header, each value
--- `{ value = string, filename = string|nil, contentType = string|nil }`.
--- Minimal by design: handles exactly the shape screenshot-basic and this
--- endpoint's own tests produce (no nested multipart, no header folding).
--- @param body string
--- @param boundary string
--- @return table<string, table>
local function parseMultipart(body, boundary)
  local parts = {}
  local delimiter = '--' .. boundary
  for chunk in (body .. '\r\n' .. delimiter .. '--'):gmatch('(.-)\r\n' .. delimiter:gsub('%p', '%%%1')) do
    if chunk ~= '' and chunk ~= '--' then
      local headerBlock, value = chunk:match('^\r?\n?(.-)\r\n\r\n(.*)$')
      if headerBlock then
        local name = headerBlock:match('name="([^"]*)"')
        local filename = headerBlock:match('filename="([^"]*)"')
        local contentType = headerBlock:match('Content%-Type:%s*([^\r\n]+)')
        if name then
          parts[name] = { value = value, filename = filename, contentType = contentType }
        end
      end
    end
  end
  return parts
end

SetHttpHandler(function(req, res)
  if req.path ~= '/storage/upload' then
    res:writeHead(404, {})
    res:send('')
    return
  end

  req:setDataHandler(function(body)
    local boundary = parseBoundary(req.headers['content-type'])
    if not boundary then
      res:writeHead(400, {})
      res:send('missing multipart boundary')
      return
    end

    local parts = parseMultipart(body, boundary)
    local token = parts.token and parts.token.value
    local pending = token and Storage.consumeUploadToken(token)
    if not pending then
      res:writeHead(403, {})
      res:send('invalid or expired token')
      return
    end

    local file = parts['files[]']
    if not file or not file.value or #file.value == 0 then
      res:writeHead(400, {})
      res:send('missing file')
      return
    end

    local url = Storage.put(pending.key, file.value, pending.contentType)
    res:writeHead(200, { ['Content-Type'] = 'application/json' })
    res:send(json.encode({ url = url }))
  end)
end)
```

- [ ] **Step 6: Run test to verify it passes**

Run: `lua5.4 tests/storage_upload_handler_spec.lua`
Expected: `storage_upload_handler_spec: 4/4 passed`

If the multipart parser test fails, check the `gmatch` pattern's boundary
escaping first — `boundary:gsub('%p', '%%%1')` Lua-pattern-escapes every
punctuation character in the boundary string, which matters because
multipart boundaries commonly contain `-` and other Lua magic characters.

- [ ] **Step 7: Wire the handler into `Storage.init()`**

In `core/server/Services/StorageService.lua`, at the end of `Storage.init()`
(right before the final `return true`), the handler file needs to actually
run once. Since `fxmanifest.lua`'s `storage/*.lua` glob already loads
`upload_handler.lua` at script-load time (which calls `SetHttpHandler`
immediately, at the top level of that file — not deferred to `Storage.init()`),
no additional wiring is needed here: the handler self-registers when the
file loads, same as `ActionService.register` calls elsewhere in this
codebase that run at module-load time. Add a comment noting this in
`Storage.init()` so a future reader isn't left looking for a call that
doesn't exist:

```lua
  -- Note: the /storage/upload HTTP handler (core/server/Services/storage/
  -- upload_handler.lua) self-registers via SetHttpHandler when that file
  -- loads (see fxmanifest.lua's storage/*.lua glob) — nothing to call here.
```

Add that comment inside `Storage.init()`, directly above `Storage.driver = driver`.

- [ ] **Step 8: Add all five new spec files to `package.json`**

```json
"test": "lua5.4 tests/orm_spec.lua && lua5.4 tests/obelisk_spec.lua && lua5.4 tests/action_service_spec.lua && lua5.4 tests/migration_audit_spec.lua && lua5.4 tests/entity_streamer_service_spec.lua && lua5.4 tests/sha256_spec.lua && lua5.4 tests/sigv4_spec.lua && lua5.4 tests/storage_local_spec.lua && lua5.4 tests/storage_s3_spec.lua && lua5.4 tests/storage_service_spec.lua && lua5.4 tests/storage_upload_handler_spec.lua",
```

- [ ] **Step 9: Run the full test suite**

Run: `npm test`
Expected: every spec file (existing + all six new ones) reports a full pass count, exit code 0.

- [ ] **Step 10: Commit**

```bash
git add core/server/Services/StorageService.lua core/server/Services/storage/upload_handler.lua tests/storage_upload_handler_spec.lua tests/support/fivem_stubs.lua package.json
git commit -m "feat(storage): add upload token minting and /storage/upload endpoint"
```

---

## Manual verification (not part of the automated suite)

The design spec calls out that a live S3-compatible round trip and the
real `screenshot-basic` → `/storage/upload` flow are ops-verification steps,
not automated tests. Before calling this feature done end-to-end:

1. Start the stack (`docker compose up`), confirm `[Storage] Initialized
   (driver: local)` appears in server logs.
2. Hit `/storage/upload` with a hand-built multipart POST (`curl -F
   token=... -F files[]=@test.jpg http://localhost:30120/storage/upload`)
   using a token minted via a temporary debug command, confirm a 200 with a
   url, and that `GET <that url>` actually serves the file back.
3. If S3 credentials are available: set `storage_driver "s3"` plus the
   `storage_s3_*` convars in `server.cfg`, restart, repeat step 2, and
   additionally confirm the object actually appears in the bucket (and that
   `Storage.delete` removes it).

## Out of scope (matches the design spec)

- SFTP provider.
- Per-file access control / signed read URLs.
- Automatic cleanup of orphaned files.
- Anything Camera/`oblsk_phone`-specific — that's the next sub-project's plan.
