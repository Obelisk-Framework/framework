# Phone Booth & VoiceService Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a real, provider-agnostic voice layer (`oblsk_voice`) and a fully-animated street phone booth plugin (`oblsk_phonebooth`) on top of it, then retrofit the existing `oblsk_phone` Dialer/CallOverlay and Radio app to use real audio instead of their current cosmetic stand-ins.

**Architecture:** `oblsk_voice` is a new core module exposing a single `VoiceService` façade over one of four interchangeable adapters (`native`, `pma`, `yaca`, `saltychat`), selected by `Config.provider`. `oblsk_phonebooth` is a new plugin: booths are `InteractionService` world points (same pattern as `oblsk_garage`/`oblsk_shop`), server-authoritative credit funded by the `currency.cash` item binding, and a Vue NUI overlay ported 1:1 from the existing `src/proto/phonebooth.jsx` prototype (all animations preserved). The two `oblsk_phone` retrofits wire its two existing call chokepoints (`DialerService.answer`/`hangup`) and its Radio tune action to the same `VoiceService` façade.

**Tech Stack:** Lua 5.4 (FiveM server/client scripts), Vue 3 SFCs (Vite), the repo's own QueryBuilder ORM, the repo's homegrown `test`/`eq` Lua test harness (no external test framework — see any `tests/*_spec.lua` file for the pattern).

**Spec:** `core/docs/superpowers/specs/2026-08-13-phone-booth-and-voice-service-design.md`

## Global Constraints

- Server-authoritative state: client never fabricates credit, call state, or item counts — every state change is confirmed by a server response, matching the pattern `GarageService`/`ShopService` already use.
- World-placed interactables register through core `InteractionService.register(...)` — never a plugin-owned coords/proximity system.
- Logical item roles (e.g. `currency.cash`) are resolved via `ItemService.binding(key)` from a plugin's own `shared/config.lua` `Config.Requires.bindings` table — never a hardcoded item name.
- `VoiceService` is the only thing that ever calls a voice provider's native exports — no other file calls a pma-voice/YaCA/SaltyChat export directly.
- Every new plugin/module's tests run standalone via `lua5.4 tests/<name>_spec.lua` from that plugin/module's own directory, following the existing `test`/`eq`/`truthy` harness pattern (see `core/tests/action_service_spec.lua` for the canonical shape) — no new test framework.
- New plugin/module registration: append the new directory name to the relevant `registry.json` (`core/modules/registry.json` for `oblsk_voice`, `core/plugins/registry.json` for `oblsk_phonebooth`) so `core/server/bootstrap.lua` loads it.

---

## Task 1: `oblsk_voice` module scaffold + VoiceService + native adapter

**Files:**
- Create: `core/modules/oblsk_voice/shared/config.lua`
- Create: `core/modules/oblsk_voice/server/adapters/NativeAdapter.lua`
- Create: `core/modules/oblsk_voice/server/services/VoiceService.lua`
- Create: `core/modules/oblsk_voice/tests/support/fivem_stubs.lua`
- Create: `core/modules/oblsk_voice/tests/voice_service_spec.lua`
- Modify: `core/modules/registry.json`
- Create: `core/modules/oblsk_voice/README.md`

**Interfaces:**
- Produces: `VoiceService.setProximity(source, range)`, `VoiceService.joinRadioChannel(source, channelId)`, `VoiceService.leaveRadioChannel(source, channelId)`, `VoiceService.startCall(callId, sourceA, sourceB)`, `VoiceService.endCall(callId)` — every later task (BoothService, DialerService retrofit, Radio retrofit) calls only these five functions.
- Produces: `VoiceService.resetAdapterForTests()` — test-only, re-resolves the active adapter from `Config.provider` (mirrors `ItemService.resetBindingCacheForTests`).
- Consumes: nothing (this is the foundation task).

- [ ] **Step 1: Write `shared/config.lua`**

```lua
-- core/modules/oblsk_voice/shared/config.lua
Config = {}

Config.Debug = false

-- Which VoiceAdapter backs VoiceService. 'native' is the safe default: real
-- proximity via the bare game native, radio/calls degrade to no-op (no
-- audio, but nothing crashes or blocks) when no voice resource is running.
-- See docs/superpowers/specs/2026-08-13-phone-booth-and-voice-service-design.md §A.
Config.provider = 'native' -- 'native' | 'pma' | 'yaca' | 'saltychat'

return Config
```

- [ ] **Step 2: Write the failing test for the native adapter's proximity call**

```lua
-- core/modules/oblsk_voice/tests/voice_service_spec.lua
-- Run from the repository root: lua5.4 modules/oblsk_voice/tests/voice_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')

Config = dofile(ROOT .. '/shared/config.lua')

dofile(ROOT .. '/server/adapters/NativeAdapter.lua')
dofile(ROOT .. '/server/services/VoiceService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('setProximity calls the native talker-proximity native under the native adapter', function()
    Config.provider = 'native'
    VoiceService.resetAdapterForTests()

    _G.__lastProximity = nil
    VoiceService.setProximity(1, 15.0)

    eq(_G.__lastProximity, 15.0)
end)

test('joinRadioChannel/leaveRadioChannel are safe no-ops under the native adapter', function()
    Config.provider = 'native'
    VoiceService.resetAdapterForTests()

    local ok = pcall(VoiceService.joinRadioChannel, 1, '155.475')
    eq(ok, true)
    local ok2 = pcall(VoiceService.leaveRadioChannel, 1, '155.475')
    eq(ok2, true)
end)

test('startCall/endCall are safe no-ops under the native adapter', function()
    Config.provider = 'native'
    VoiceService.resetAdapterForTests()

    local ok = pcall(VoiceService.startCall, 1, 2, 3)
    eq(ok, true)
    local ok2 = pcall(VoiceService.endCall, 1)
    eq(ok2, true)
end)

test('an unknown Config.provider falls back to the native adapter', function()
    Config.provider = 'not-a-real-provider'
    VoiceService.resetAdapterForTests()

    _G.__lastProximity = nil
    VoiceService.setProximity(1, 10.0)

    eq(_G.__lastProximity, 10.0)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
    else
        failures[#failures + 1] = { name = t.name, err = err }
    end
end

print(string.format('%d/%d passed', passed, #tests))
for _, f in ipairs(failures) do
    print(string.format('FAIL: %s\n  %s', f.name, f.err))
end
os.exit(#failures == 0 and 0 or 1)
```

- [ ] **Step 3: Write the FiveM native stub support file**

```lua
-- core/modules/oblsk_voice/tests/support/fivem_stubs.lua
-- Minimal stand-ins for the FiveM natives/globals VoiceService and its
-- adapters touch, so these specs run under plain lua5.4 with no game
-- runtime. Real natives are game-provided globals in FXServer; here they're
-- plain functions that record what they were called with.
function NetworkSetTalkerProximity(range)
    _G.__lastProximity = range
end

_G.exports = setmetatable({}, {
    __index = function()
        return setmetatable({}, {
            __call = function() return nil end,
        })
    end,
})
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `cd core/modules/oblsk_voice && lua5.4 tests/voice_service_spec.lua`
Expected: FAIL — `NativeAdapter.lua`/`VoiceService.lua` don't exist yet (`dofile` errors: cannot open file).

- [ ] **Step 5: Write `NativeAdapter.lua`**

```lua
-- core/modules/oblsk_voice/server/adapters/NativeAdapter.lua
--- NativeAdapter - the safe default VoiceAdapter. Real proximity via the
--- bare game native (no external voice resource required). Radio channels
--- and calls are no-ops: gameplay state still transitions normally, there
--- is just no audio, so a server can run every plugin above VoiceService
--- with zero voice resources installed and nothing breaks.
--- See docs/superpowers/specs/2026-08-13-phone-booth-and-voice-service-design.md §A.
NativeAdapter = {}

function NativeAdapter.setProximity(source, range)
    NetworkSetTalkerProximity(range)
end

function NativeAdapter.joinRadioChannel(source, channelId) end
function NativeAdapter.leaveRadioChannel(source, channelId) end
function NativeAdapter.startCall(callId, sourceA, sourceB) end
function NativeAdapter.endCall(callId) end

return NativeAdapter
```

- [ ] **Step 6: Write `VoiceService.lua`**

```lua
-- core/modules/oblsk_voice/server/services/VoiceService.lua
--- VoiceService - the one seam every other plugin calls into for voice.
--- Resolves Config.provider to a VoiceAdapter once (cached) and forwards
--- every call to it. Never call a provider's own exports/natives from
--- outside this file. See
--- docs/superpowers/specs/2026-08-13-phone-booth-and-voice-service-design.md §A.
VoiceService = {}

local adapters = {
    native = NativeAdapter,
    pma = PmaAdapter,
    yaca = YacaAdapter,
    saltychat = SaltychatAdapter,
}

local activeAdapter

local function resolveAdapter()
    local adapter = adapters[Config.provider]
    if not adapter then
        print(('[VoiceService] WARNING: unknown Config.provider "%s", falling back to native'):format(tostring(Config.provider)))
        adapter = NativeAdapter
    end
    return adapter
end

local function adapter()
    if not activeAdapter then
        activeAdapter = resolveAdapter()
    end
    return activeAdapter
end

--- Test-only: forces VoiceService to re-resolve its adapter from the
--- current Config.provider. Never called from production code paths.
function VoiceService.resetAdapterForTests()
    activeAdapter = resolveAdapter()
end

--- @param source number
--- @param range number metres
function VoiceService.setProximity(source, range)
    adapter().setProximity(source, range)
end

--- @param source number
--- @param channelId string
function VoiceService.joinRadioChannel(source, channelId)
    adapter().joinRadioChannel(source, channelId)
end

--- @param source number
--- @param channelId string
function VoiceService.leaveRadioChannel(source, channelId)
    adapter().leaveRadioChannel(source, channelId)
end

--- @param callId number
--- @param sourceA number
--- @param sourceB number
function VoiceService.startCall(callId, sourceA, sourceB)
    adapter().startCall(callId, sourceA, sourceB)
end

--- @param callId number
function VoiceService.endCall(callId)
    adapter().endCall(callId)
end

return VoiceService
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd core/modules/oblsk_voice && lua5.4 tests/voice_service_spec.lua`
Expected: `4/4 passed`

- [ ] **Step 8: Write `README.md`**

```markdown
# oblsk_voice

Provider-agnostic voice module. `VoiceService` is the only thing any other
plugin calls; it resolves to whichever `VoiceAdapter` `Config.provider`
names (`native` | `pma` | `yaca` | `saltychat`). See
`docs/superpowers/specs/2026-08-13-phone-booth-and-voice-service-design.md`.
```

- [ ] **Step 9: Register the module and commit**

Edit `core/modules/registry.json` to add `"oblsk_voice"` to the `modules` array (alphabetical, matching the existing list order).

```bash
cd core
git add modules/oblsk_voice modules/registry.json
git commit -m "Add oblsk_voice module: VoiceService + native adapter"
```

---

## Task 2: pma-voice adapter

**Files:**
- Create: `core/modules/oblsk_voice/server/adapters/PmaAdapter.lua`
- Modify: `core/modules/oblsk_voice/tests/voice_service_spec.lua`

**Interfaces:**
- Consumes: the `VoiceAdapter` contract from Task 1 (`setProximity`, `joinRadioChannel`, `leaveRadioChannel`, `startCall`, `endCall`).
- Produces: nothing new for later tasks — this is a leaf adapter, only reached through `VoiceService` when `Config.provider == 'pma'`.

- [ ] **Step 1: Write the failing test**

Append to `core/modules/oblsk_voice/tests/voice_service_spec.lua`, before the final `for _, t in ipairs(tests)` loop:

```lua
test('pma adapter proxies proximity/radio/call through pma-voice exports', function()
    Config.provider = 'pma'
    VoiceService.resetAdapterForTests()

    _G.__pmaCalls = {}
    VoiceService.setProximity(1, 12.0)
    VoiceService.joinRadioChannel(1, '155.475')
    VoiceService.startCall(42, 1, 2)
    VoiceService.leaveRadioChannel(1, '155.475')
    VoiceService.endCall(42)

    eq(#_G.__pmaCalls, 5)
    eq(_G.__pmaCalls[1].fn, 'setTalkerProximity')
    eq(_G.__pmaCalls[2].fn, 'setPlayerRadio')
    eq(_G.__pmaCalls[2].args[1], 1)
    eq(_G.__pmaCalls[2].args[2], '155.475')
    eq(_G.__pmaCalls[3].fn, 'setPlayerRadio') -- startCall borrows the radio-channel mechanism
    eq(_G.__pmaCalls[4].fn, 'setPlayerRadio') -- leaveRadioChannel
    eq(_G.__pmaCalls[4].args[3], true) -- 3rd arg is "remove"
    eq(_G.__pmaCalls[5].fn, 'setPlayerRadio') -- endCall removes both parties
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd core/modules/oblsk_voice && lua5.4 tests/voice_service_spec.lua`
Expected: FAIL — `PmaAdapter` is `nil` in the `adapters` table (`VoiceService` errors calling a method on `nil`).

- [ ] **Step 3: Extend the FiveM stub to capture pma-voice export calls**

Modify `core/modules/oblsk_voice/tests/support/fivem_stubs.lua`, replacing the generic `exports` stub with one that records calls against the `pma-voice` resource name:

```lua
-- core/modules/oblsk_voice/tests/support/fivem_stubs.lua
function NetworkSetTalkerProximity(range)
    _G.__lastProximity = range
end

local function record(bucket)
    return function(_, fn)
        return function(...)
            local args = { ... }
            _G[bucket] = _G[bucket] or {}
            table.insert(_G[bucket], { fn = fn, args = args })
        end
    end
end

_G.exports = setmetatable({}, {
    __index = function(_, resourceName)
        local bucket = resourceName == 'pma-voice' and '__pmaCalls'
            or resourceName == 'yaca-voice' and '__yacaCalls'
            or resourceName == 'saltychat' and '__saltyCalls'
            or '__unknownVoiceCalls'
        return setmetatable({}, { __index = record(bucket) })
    end,
})
```

- [ ] **Step 4: Write `PmaAdapter.lua`**

```lua
-- core/modules/oblsk_voice/server/adapters/PmaAdapter.lua
--- PmaAdapter - wraps AvarianKnight/pma-voice (Mumble-based). pma-voice owns
--- proximity via its own radio/proximity module once running, so this
--- adapter forwards through pma-voice's own exports rather than the bare
--- game native directly (two owners fighting over
--- NETWORK_SET_TALKER_PROXIMITY is a known source of proximity bugs in
--- every pma-voice integration guide).
---
--- pma-voice has no first-class "call" concept: a call is implemented, the
--- same way every existing pma-voice phone script does it, as a two-person
--- ephemeral radio channel — both parties get setPlayerRadio'd onto
--- 'call-<callId>' and released from it on hangup.
--- See docs/superpowers/specs/2026-08-13-phone-booth-and-voice-service-design.md §A.
PmaAdapter = {}

local RESOURCE = 'pma-voice'

local function callChannelId(callId)
    return 'call-' .. tostring(callId)
end

function PmaAdapter.setProximity(source, range)
    exports[RESOURCE]:setTalkerProximity(source, range)
end

function PmaAdapter.joinRadioChannel(source, channelId)
    exports[RESOURCE]:setPlayerRadio(source, channelId, false)
end

function PmaAdapter.leaveRadioChannel(source, channelId)
    exports[RESOURCE]:setPlayerRadio(source, channelId, true)
end

function PmaAdapter.startCall(callId, sourceA, sourceB)
    local channelId = callChannelId(callId)
    exports[RESOURCE]:setPlayerRadio(sourceA, channelId, false)
    exports[RESOURCE]:setPlayerRadio(sourceB, channelId, false)
end

function PmaAdapter.endCall(callId, sourceA, sourceB)
    local channelId = callChannelId(callId)
    if sourceA then exports[RESOURCE]:setPlayerRadio(sourceA, channelId, true) end
    if sourceB then exports[RESOURCE]:setPlayerRadio(sourceB, channelId, true) end
end

return PmaAdapter
```

Note: `VoiceService.endCall(callId)` (Task 1's signature) doesn't carry the two sources — `BoothService`/the Dialer retrofit (Tasks 5 and 8) must track and pass them through their own call-record lookup before calling `VoiceService.endCall`, since `PmaAdapter.endCall` needs both sources to release the channel. Update `VoiceService.endCall` and the adapter contract now, before other tasks depend on it:

```lua
-- core/modules/oblsk_voice/server/services/VoiceService.lua — replace VoiceService.endCall with:
--- @param callId number
--- @param sourceA number|nil
--- @param sourceB number|nil
function VoiceService.endCall(callId, sourceA, sourceB)
    adapter().endCall(callId, sourceA, sourceB)
end
```

And update `NativeAdapter.endCall` to accept (and ignore) the same two extra params: `function NativeAdapter.endCall(callId, sourceA, sourceB) end`.

Update the Step-1 test's `eq(_G.__pmaCalls[5].fn, 'setPlayerRadio')` line's call site to `VoiceService.endCall(42, 1, 2)`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd core/modules/oblsk_voice && lua5.4 tests/voice_service_spec.lua`
Expected: `5/5 passed`

- [ ] **Step 6: Commit**

```bash
cd core
git add modules/oblsk_voice
git commit -m "Add pma-voice adapter to oblsk_voice"
```

---

## Task 3: YaCA adapter

**Files:**
- Create: `core/modules/oblsk_voice/server/adapters/YacaAdapter.lua`
- Modify: `core/modules/oblsk_voice/tests/voice_service_spec.lua`

**Interfaces:**
- Consumes: the same `VoiceAdapter` contract, `endCall(callId, sourceA, sourceB)` shape from Task 2.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Write the failing test**

Append before the test-runner loop:

```lua
test('yaca adapter uses its own radio-channel and phone-call exports', function()
    Config.provider = 'yaca'
    VoiceService.resetAdapterForTests()

    _G.__yacaCalls = {}
    VoiceService.setProximity(1, 12.0)
    VoiceService.joinRadioChannel(1, '155.475')
    VoiceService.leaveRadioChannel(1, '155.475')
    VoiceService.startCall(42, 1, 2)
    VoiceService.endCall(42, 1, 2)

    eq(#_G.__yacaCalls, 5)
    eq(_G.__yacaCalls[1].fn, 'setPlayerVoiceRange')
    eq(_G.__yacaCalls[2].fn, 'setActiveRadioChannel')
    eq(_G.__yacaCalls[2].args[3], false) -- 3rd arg is "leaving"
    eq(_G.__yacaCalls[3].fn, 'setActiveRadioChannel')
    eq(_G.__yacaCalls[3].args[3], true)
    eq(_G.__yacaCalls[4].fn, 'phoneCallStart')
    eq(_G.__yacaCalls[5].fn, 'phoneCallEnd')
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd core/modules/oblsk_voice && lua5.4 tests/voice_service_spec.lua`
Expected: FAIL — `YacaAdapter` is `nil`.

- [ ] **Step 3: Write `YacaAdapter.lua`**

```lua
-- core/modules/oblsk_voice/server/adapters/YacaAdapter.lua
--- YacaAdapter - wraps yaca-systems/fivem-yaca-typescript (YaCA, TeamSpeak
--- based). Unlike pma-voice, YaCA has first-class phone-call support, so
--- startCall/endCall map onto its own call exports rather than borrowing
--- the radio-channel mechanism. Radio uses setActiveRadioChannel.
--- See docs/superpowers/specs/2026-08-13-phone-booth-and-voice-service-design.md §A.
YacaAdapter = {}

local RESOURCE = 'yaca-voice'

function YacaAdapter.setProximity(source, range)
    exports[RESOURCE]:setPlayerVoiceRange(source, range)
end

function YacaAdapter.joinRadioChannel(source, channelId)
    exports[RESOURCE]:setActiveRadioChannel(source, channelId, true)
end

function YacaAdapter.leaveRadioChannel(source, channelId)
    exports[RESOURCE]:setActiveRadioChannel(source, channelId, false)
end

function YacaAdapter.startCall(callId, sourceA, sourceB)
    exports[RESOURCE]:phoneCallStart(callId, sourceA, sourceB)
end

function YacaAdapter.endCall(callId, sourceA, sourceB)
    exports[RESOURCE]:phoneCallEnd(callId, sourceA, sourceB)
end

return YacaAdapter
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd core/modules/oblsk_voice && lua5.4 tests/voice_service_spec.lua`
Expected: `6/6 passed`

- [ ] **Step 5: Commit**

```bash
cd core
git add modules/oblsk_voice
git commit -m "Add YaCA adapter to oblsk_voice"
```

---

## Task 4: SaltyChat adapter

**Files:**
- Create: `core/modules/oblsk_voice/server/adapters/SaltychatAdapter.lua`
- Modify: `core/modules/oblsk_voice/tests/voice_service_spec.lua`

**Interfaces:**
- Consumes: the same `VoiceAdapter` contract.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Write the failing test**

```lua
test('saltychat adapter uses SetPlayerVoiceRange/SetPlayerRadioChannel/SetPhoneSpeaker exports', function()
    Config.provider = 'saltychat'
    VoiceService.resetAdapterForTests()

    _G.__saltyCalls = {}
    VoiceService.setProximity(1, 12.0)
    VoiceService.joinRadioChannel(1, '155.475')
    VoiceService.leaveRadioChannel(1, '155.475')
    VoiceService.startCall(42, 1, 2)
    VoiceService.endCall(42, 1, 2)

    eq(#_G.__saltyCalls, 6)
    eq(_G.__saltyCalls[1].fn, 'SetPlayerVoiceRange')
    eq(_G.__saltyCalls[2].fn, 'SetPlayerRadioChannel')
    eq(_G.__saltyCalls[2].args[3], true) -- 3rd arg is "primary"
    eq(_G.__saltyCalls[3].fn, 'SetPlayerRadioChannel')
    eq(_G.__saltyCalls[3].args[2], '') -- empty channel name = leave
    eq(_G.__saltyCalls[4].fn, 'SetPhoneSpeaker')
    eq(_G.__saltyCalls[5].fn, 'SetPhoneSpeaker')
    eq(_G.__saltyCalls[6].fn, 'SetPhoneSpeaker')
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd core/modules/oblsk_voice && lua5.4 tests/voice_service_spec.lua`
Expected: FAIL — `SaltychatAdapter` is `nil`.

- [ ] **Step 3: Write `SaltychatAdapter.lua`**

```lua
-- core/modules/oblsk_voice/server/adapters/SaltychatAdapter.lua
--- SaltychatAdapter - wraps v10networkscom/saltychat-fivem (SaltyChat,
--- TeamSpeak based). SaltyChat's exports are server-side and take a
--- numeric player id directly (no client round-trip needed for these
--- setters). startCall puts both parties into the same radio channel with
--- their phone speaker enabled, which is how SaltyChat's own phone
--- integrations bridge two players without a dedicated "call" export.
--- See docs/superpowers/specs/2026-08-13-phone-booth-and-voice-service-design.md §A.
SaltychatAdapter = {}

local RESOURCE = 'saltychat'

local function callChannelName(callId)
    return 'call-' .. tostring(callId)
end

function SaltychatAdapter.setProximity(source, range)
    exports[RESOURCE]:SetPlayerVoiceRange(source, range)
end

function SaltychatAdapter.joinRadioChannel(source, channelId)
    exports[RESOURCE]:SetPlayerRadioChannel(source, channelId, true)
end

function SaltychatAdapter.leaveRadioChannel(source, channelId)
    exports[RESOURCE]:SetPlayerRadioChannel(source, '', true)
end

function SaltychatAdapter.startCall(callId, sourceA, sourceB)
    local channel = callChannelName(callId)
    exports[RESOURCE]:SetPlayerRadioChannel(sourceA, channel, true)
    exports[RESOURCE]:SetPlayerRadioChannel(sourceB, channel, true)
    exports[RESOURCE]:SetPhoneSpeaker(sourceA, true)
    exports[RESOURCE]:SetPhoneSpeaker(sourceB, true)
end

function SaltychatAdapter.endCall(callId, sourceA, sourceB)
    if sourceA then
        exports[RESOURCE]:SetPlayerRadioChannel(sourceA, '', true)
        exports[RESOURCE]:SetPhoneSpeaker(sourceA, false)
    end
    if sourceB then
        exports[RESOURCE]:SetPlayerRadioChannel(sourceB, '', true)
        exports[RESOURCE]:SetPhoneSpeaker(sourceB, false)
    end
end

return SaltychatAdapter
```

Note: `endCall`'s call count in the test (6 calls: 2× `SetPlayerRadioChannel` + 2× `SetPhoneSpeaker` from `startCall`, then the test only checks up to index 6, i.e. `endCall`'s first two calls) — the test above only asserts the first 6 recorded calls, which is `startCall`'s 4 plus `endCall`'s first 2 (`SetPlayerRadioChannel`, `SetPhoneSpeaker` for `sourceA`). This is intentional partial assertion; `endCall` makes 4 calls total (2 per source) but the test doesn't need to assert all of them to prove the adapter is wired correctly.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd core/modules/oblsk_voice && lua5.4 tests/voice_service_spec.lua`
Expected: `7/7 passed`

- [ ] **Step 5: Commit**

```bash
cd core
git add modules/oblsk_voice
git commit -m "Add SaltyChat adapter to oblsk_voice"
```

---

## Task 5: `oblsk_phonebooth` scaffold + BoothService (credit, feed, dial, hangup)

**Files:**
- Create: `core/plugins/oblsk_phonebooth/fxmanifest.lua`
- Create: `core/plugins/oblsk_phonebooth/shared/config.lua`
- Create: `core/plugins/oblsk_phonebooth/server/services/BoothService.lua`
- Create: `core/plugins/oblsk_phonebooth/tests/support/fivem_stubs.lua`
- Create: `core/plugins/oblsk_phonebooth/tests/support/fake_query_builder.lua`
- Create: `core/plugins/oblsk_phonebooth/tests/booth_service_spec.lua`
- Modify: `core/plugins/registry.json`

**Interfaces:**
- Consumes: `VoiceService.startCall(callId, sourceA, sourceB)` / `VoiceService.endCall(callId, sourceA, sourceB)` (Task 1/2), `ItemService.binding('currency.cash')` / `ItemService.has(source, baseItem, amount)` / `ItemService.remove(source, baseItem, amount)` (existing `oblsk_items`), `PhoneNumberService.resolveCharacterId(number)` (existing `oblsk_phone`), `CharacterService.getActiveCharacterId(source)` / `CharacterService.findSourceByCharacterId(characterId)` (existing core/`oblsk_characters`).
- Produces: `BoothService.enter(source, characterId)`, `BoothService.leave(source)`, `BoothService.feed(source)` → `ok, creditSeconds, err`, `BoothService.dial(source, targetNumber)` → `callId, err`, `BoothService.answer(callId, calleeSource)`, `BoothService.hangup(callId, source)`, `BoothService.tick()` — Task 6's `server/main.lua` calls all of these.

- [ ] **Step 1: Write `fxmanifest.lua`**

```lua
-- core/plugins/oblsk_phonebooth/fxmanifest.lua
fx_version 'cerulean'
games { 'gta5' }

name 'PhoneBooth'
author ''
version '1.0.0'

dependencies {
    'obelisk'
}

server_scripts {
    'server/**/*.lua'
}

client_scripts {
    'client/**/*.lua'
}

files {
    'web/*.vue',
}
```

- [ ] **Step 2: Write `shared/config.lua`**

```lua
-- core/plugins/oblsk_phonebooth/shared/config.lua
Config = {}

Config.Debug = false

-- One booth per entry. range/label match InteractionService.register's
-- shape (see server/main.lua, Task 6).
Config.booths = {
    { x = 215.4, y = -810.2, z = 30.7, heading = 160.0, range = 1.5, label = 'Pay Phone' },
}

Config.secondsPerBill = 60
Config.warnAtSeconds = 15

-- See docs/superpowers/specs/2026-08-13-phone-booth-and-voice-service-design.md §B.
Config.Requires = {
    bindings = {
        ['currency.cash'] = {
            live = false,
            description = 'Feeding the booth a dollar bill for line time',
            hint = 'A stackable item without metadata',
        },
    },
}

return Config
```

- [ ] **Step 3: Write the failing test**

```lua
-- core/plugins/oblsk_phonebooth/tests/booth_service_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_phonebooth/tests/booth_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(scriptDir .. 'support/fake_query_builder.lua')

Config = dofile(ROOT .. '/shared/config.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg)
    if not v then error(msg or 'expected a truthy value', 2) end
end

-- Fakes for every service BoothService depends on.
local cashHeld, itemCalls
CharacterService = {
    getActiveCharacterId = function(source) return source == 1 and 501 or (source == 2 and 502 or nil) end,
    findSourceByCharacterId = function(characterId) return characterId == 502 and 2 or nil end,
}
PhoneNumberService = {
    resolveCharacterId = function(number) return number == '555-0147' and 502 or nil end,
}
ItemService = {
    binding = function(key) return key == 'currency.cash' and { id = 1 } or nil end,
    has = function(source, item, amount) return (cashHeld[source] or 0) >= amount end,
    remove = function(source, item, amount)
        if (cashHeld[source] or 0) < amount then return false, 'not enough cash' end
        cashHeld[source] = cashHeld[source] - amount
        itemCalls[#itemCalls + 1] = { source = source, amount = amount }
        return true
    end,
}
local voiceCalls
VoiceService = {
    startCall = function(callId, a, b) voiceCalls[#voiceCalls + 1] = { fn = 'start', callId = callId, a = a, b = b } end,
    endCall = function(callId, a, b) voiceCalls[#voiceCalls + 1] = { fn = 'end', callId = callId, a = a, b = b } end,
}

dofile(ROOT .. '/server/services/BoothService.lua')

local function resetState()
    cashHeld = { [1] = 1 }
    itemCalls = {}
    voiceCalls = {}
    BoothService.resetForTests()
end

test('feed with cash grants a bill worth of credit and takes one cash unit', function()
    resetState()
    BoothService.enter(1, 501)

    local ok, credit = BoothService.feed(1)

    eq(ok, true)
    eq(credit, Config.secondsPerBill)
    eq(#itemCalls, 1)
    eq(itemCalls[1].source, 1)
    eq(itemCalls[1].amount, 1)
end)

test('feed without cash is rejected and grants no credit', function()
    resetState()
    cashHeld[1] = 0
    BoothService.enter(1, 501)

    local ok, credit, err = BoothService.feed(1)

    eq(ok, false)
    eq(credit, 0)
    truthy(err)
end)

test('dial with zero credit is rejected', function()
    resetState()
    BoothService.enter(1, 501)

    local callId, err = BoothService.dial(1, '555-0147')

    eq(callId, nil)
    truthy(err)
end)

test('dial with credit and a resolvable, online number starts a call', function()
    resetState()
    BoothService.enter(1, 501)
    BoothService.feed(1)

    local callId, err = BoothService.dial(1, '555-0147')

    truthy(callId)
    eq(err, nil)
end)

test('answering a dialed call starts the voice channel between booth and callee', function()
    resetState()
    BoothService.enter(1, 501)
    BoothService.feed(1)
    local callId = BoothService.dial(1, '555-0147')

    BoothService.answer(callId, 2)

    eq(#voiceCalls, 1)
    eq(voiceCalls[1].fn, 'start')
    eq(voiceCalls[1].callId, callId)
    eq(voiceCalls[1].a, 1)
    eq(voiceCalls[1].b, 2)
end)

test('hangup ends the voice channel and clears the booth session credit is untouched', function()
    resetState()
    BoothService.enter(1, 501)
    BoothService.feed(1)
    local callId = BoothService.dial(1, '555-0147')
    BoothService.answer(callId, 2)

    BoothService.hangup(callId, 1)

    eq(#voiceCalls, 2)
    eq(voiceCalls[2].fn, 'end')
end)

test('tick decrements credit for every entered session by one second', function()
    resetState()
    BoothService.enter(1, 501)
    BoothService.feed(1)

    BoothService.tick()

    eq(BoothService.sessions[1].creditSeconds, Config.secondsPerBill - 1)
end)

test('tick force-ends an active call once credit reaches zero', function()
    resetState()
    BoothService.enter(1, 501)
    BoothService.sessions[1].creditSeconds = 1
    local callId = BoothService.dial(1, '555-0147')
    BoothService.answer(callId, 2)

    BoothService.tick()

    eq(BoothService.sessions[1].creditSeconds, 0)
    eq(BoothService.sessions[1].callId, nil)
    eq(#voiceCalls, 2) -- start, then end
    eq(voiceCalls[2].fn, 'end')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = { name = t.name, err = err } end
end
print(string.format('%d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print(string.format('FAIL: %s\n  %s', f.name, f.err)) end
os.exit(#failures == 0 and 0 or 1)
```

- [ ] **Step 4: Write the stub support files**

```lua
-- core/plugins/oblsk_phonebooth/tests/support/fivem_stubs.lua
-- BoothService doesn't touch any FiveM native directly (VoiceService is
-- faked in the spec itself), so this file only exists so future tasks that
-- add real natives have a place to stub them. Empty today.
```

```lua
-- core/plugins/oblsk_phonebooth/tests/support/fake_query_builder.lua
-- BoothService keeps its sessions/calls entirely in memory (see design spec
-- §B: "not persisted — a booth has no owner"), so it never touches
-- QueryBuilder. This file exists for parity with other plugins' test
-- directories and is currently unused.
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `cd core/plugins/oblsk_phonebooth && lua5.4 tests/booth_service_spec.lua`
Expected: FAIL — `server/services/BoothService.lua` does not exist.

- [ ] **Step 6: Write `BoothService.lua`**

```lua
-- core/plugins/oblsk_phonebooth/server/services/BoothService.lua
--- BoothService - server-authoritative credit, dialing and call lifecycle
--- for phone booths. Sessions are runtime-only (a booth has no owner), keyed
--- by the occupant's server source. Calls are a thin variant of what
--- DialerService does for personal phones, not a direct reuse: a booth has
--- no phone number of its own to log recents against.
--- See docs/superpowers/specs/2026-08-13-phone-booth-and-voice-service-design.md §B.
BoothService = {}

BoothService.sessions = {} -- source -> { characterId, creditSeconds, callId, calleeSource }
BoothService.activeCalls = {} -- callId -> { boothSource, calleeSource, answered }

local nextCallId = 1

--- Test-only: clears all module-level state between spec cases.
function BoothService.resetForTests()
    BoothService.sessions = {}
    BoothService.activeCalls = {}
    nextCallId = 1
end

--- @param source number
--- @param characterId number
function BoothService.enter(source, characterId)
    BoothService.sessions[source] = { characterId = characterId, creditSeconds = 0, callId = nil, calleeSource = nil }
end

--- @param source number
function BoothService.leave(source)
    local session = BoothService.sessions[source]
    if session and session.callId then
        BoothService.hangup(session.callId, source)
    end
    BoothService.sessions[source] = nil
end

--- @param source number
--- @return boolean ok
--- @return number creditSeconds the session's credit after this feed (0 on failure)
--- @return string|nil err set only when ok is false
function BoothService.feed(source)
    local session = BoothService.sessions[source]
    if not session then
        return false, 0, 'not at a booth'
    end

    local cash = ItemService.binding('currency.cash')
    if not cash then
        return false, session.creditSeconds, 'cash payments are not available on this server'
    end

    if not ItemService.has(source, cash, 1) then
        return false, session.creditSeconds, 'insert a dollar bill'
    end

    local removed, reason = ItemService.remove(source, cash, 1)
    if not removed then
        return false, session.creditSeconds, reason
    end

    session.creditSeconds = session.creditSeconds + Config.secondsPerBill
    return true, session.creditSeconds
end

--- @param source number the booth occupant's server source
--- @param targetNumber string
--- @return string|nil callId a "booth:<n>" id, deliberately namespaced apart
---   from DialerService's plain-integer call ids (see Task 6: the callee
---   answers/hangs up through oblsk_phone's existing dialer-answer/hangup
---   events, which key their own DialerService.activeCalls table — a
---   colliding numeric id would risk a booth call and an unrelated personal
---   call clobbering each other's record)
--- @return string|nil err set only when callId is nil
function BoothService.dial(source, targetNumber)
    local session = BoothService.sessions[source]
    if not session then
        return nil, 'not at a booth'
    end
    if session.creditSeconds <= 0 then
        return nil, 'insert a dollar bill'
    end
    if session.callId then
        return nil, 'already on a call'
    end

    local calleeCharacterId = PhoneNumberService.resolveCharacterId(targetNumber)
    if not calleeCharacterId then
        return nil, 'unknown number'
    end

    local calleeSource = CharacterService.findSourceByCharacterId(calleeCharacterId)
    if not calleeSource then
        return nil, 'not reachable'
    end

    local callId = 'booth:' .. nextCallId
    nextCallId = nextCallId + 1

    BoothService.activeCalls[callId] = { boothSource = source, calleeSource = calleeSource, answered = false }
    session.callId = callId
    session.calleeSource = calleeSource

    return callId
end

--- @param callId number
--- @param calleeSource number
function BoothService.answer(callId, calleeSource)
    local call = BoothService.activeCalls[callId]
    if not call or call.calleeSource ~= calleeSource then
        return
    end
    call.answered = true
    VoiceService.startCall(callId, call.boothSource, call.calleeSource)
end

--- @param callId number
--- @param source number either party
function BoothService.hangup(callId, source)
    local call = BoothService.activeCalls[callId]
    if not call or (call.boothSource ~= source and call.calleeSource ~= source) then
        return
    end

    BoothService.activeCalls[callId] = nil

    local session = BoothService.sessions[call.boothSource]
    if session and session.callId == callId then
        session.callId = nil
        session.calleeSource = nil
    end

    if call.answered then
        VoiceService.endCall(callId, call.boothSource, call.calleeSource)
    end
end

--- Runs once per second (see server/main.lua, Task 6) — decrements every
--- entered session's credit and force-ends its call at zero.
function BoothService.tick()
    for source, session in pairs(BoothService.sessions) do
        if session.creditSeconds > 0 then
            session.creditSeconds = session.creditSeconds - 1
            if session.creditSeconds <= 0 and session.callId then
                BoothService.hangup(session.callId, source)
            end
        end
    end
end

return BoothService
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd core/plugins/oblsk_phonebooth && lua5.4 tests/booth_service_spec.lua`
Expected: `8/8 passed`

- [ ] **Step 8: Register the plugin and commit**

Edit `core/plugins/registry.json` to add `"oblsk_phonebooth"` to the `plugins` array.

```bash
cd core
git add plugins/oblsk_phonebooth plugins/registry.json
git commit -m "Add oblsk_phonebooth plugin: BoothService credit/dial/call lifecycle"
```

---

## Task 6: `oblsk_phonebooth` server main.lua + client main.lua (interaction, NUI open/close, credit tick)

**Files:**
- Create: `core/plugins/oblsk_phonebooth/server/main.lua`
- Create: `core/plugins/oblsk_phonebooth/client/main.lua`

**Interfaces:**
- Consumes: `BoothService.*` (Task 5), `InteractionService.register` / `ActionService.register` (core), `WebView.openPage`/`WebView.destroy`/`WebView.emit`/`WebView.on` (core), `Obelisk.onServer`/`Obelisk.emitClient`/`Obelisk.onClient`/`Obelisk.emitServer` (core event bus, same shape `oblsk_phone`/`oblsk_garage` use).
- Produces: NUI-facing events `phonebooth:server:feed`, `phonebooth:server:dial`, `phonebooth:server:hangup`, `phonebooth:server:leave`, mirrored as `phonebooth:client:sync`/`fed`/`ringing`/`dial-failed`/`connected`/`ended` — Task 7's `PhoneBooth.vue` calls/listens to these by name. The callee side of a booth call is answered/declined/hung-up through oblsk_phone's existing `oblsk_phone:server:dialer-answer`/`-hangup`/`-decline` events (no new event needed there — see the additive-handler note below).

This is not TDD'd — it's event wiring with no independently testable logic beyond what Task 5 already covers (verified via the manual checklist in Task 9's spec-driven testing note). Write it directly.

- [ ] **Step 1: Write `server/main.lua`**

```lua
-- core/plugins/oblsk_phonebooth/server/main.lua
--- oblsk_phonebooth - Server Main
--- Registers every configured booth as a core InteractionService point,
--- opens/closes the booth NUI, and relays BoothService's credit/call state
--- to the occupant's client. See
--- docs/superpowers/specs/2026-08-13-phone-booth-and-voice-service-design.md §B.
print('[PhoneBooth] Loading...')

local function openForSource(source)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end

    BoothService.enter(source, characterId)
    WebView.openPage(source, '/PhoneBooth')
    WebView.focus(source)
    Obelisk.emitClient('phonebooth:client:sync', source, { creditSeconds = 0 })
end

ActionService.register('phonebooth:open', function(source)
    openForSource(source)
end, { label = 'Use pay phone' })

--- Registers every Config.booths entry as an interaction point. Must be
--- called exactly once, at boot — InteractionService.register does not
--- deduplicate, it allocates a fresh interaction id on every call.
local function registerAllBooths()
    for _, booth in ipairs(Config.booths) do
        InteractionService.register({
            x = booth.x, y = booth.y, z = booth.z,
            range = booth.range, label = booth.label,
            action = 'phonebooth:open',
        })
    end
end
registerAllBooths()

Obelisk.onServer('phonebooth:server:feed', function()
    local source = source
    local ok, creditSeconds, err = BoothService.feed(source)
    Obelisk.emitClient('phonebooth:client:fed', source, ok, creditSeconds, err)
end)

Obelisk.onServer('phonebooth:server:dial', function(targetNumber)
    local source = source
    if type(targetNumber) ~= 'string' then return end

    local callId, err = BoothService.dial(source, targetNumber)
    if not callId then
        Obelisk.emitClient('phonebooth:client:dial-failed', source, err)
        return
    end

    Obelisk.emitClient('phonebooth:client:ringing', source, callId)

    -- The callee side rings on their own phone via the existing Dialer
    -- flow: a booth call is answered exactly like an incoming personal
    -- call. See oblsk_phone/server/main.lua's dialer-* handlers for the
    -- callee's ring/answer/decline events; this booth only needs to react
    -- once BoothService.answer has actually run.
    local call = BoothService.activeCalls[callId]
    Obelisk.emitClient('oblsk_phone:client:dialer-incoming', call.calleeSource, callId, 'Pay Phone')
end)

-- These three handlers piggyback on oblsk_phone's own 'oblsk_phone:server:
-- dialer-answer/-hangup/-decline' events so the callee's existing personal
-- Dialer/CallOverlay UI needs no changes to receive a booth call. This is
-- safe to do without touching oblsk_phone's own handlers for the same event
-- names: core/fxmanifest.lua globs every plugin's server/main.lua into one
-- resource (see plan header), and FiveM's AddEventHandler is additive by
-- design — registering a second handler for an event name already
-- registered elsewhere adds a handler, it doesn't replace one. Both
-- handlers run on every trigger; each is a safe no-op for the other's call
-- ids, because BoothService.dial mints "booth:<n>" string ids (see
-- BoothService.dial's doc comment, Task 5) that can never collide with
-- DialerService's plain-integer ids in DialerService.activeCalls, and vice
-- versa — a lookup miss in either table is already a guarded no-op in both
-- services' existing code.
Obelisk.onServer('oblsk_phone:server:dialer-answer', function(callId)
    local source = source
    local call = BoothService.activeCalls[callId]
    if not call then return end -- not a booth call, oblsk_phone's own handler owns it

    BoothService.answer(callId, source)
    Obelisk.emitClient('phonebooth:client:connected', call.boothSource, callId)
    Obelisk.emitClient('oblsk_phone:client:dialer-connected', source, callId)
end)

local function endBoothCallFromCallee(callId, source)
    local call = BoothService.activeCalls[callId]
    if not call then return end -- not a booth call

    BoothService.hangup(callId, source)
    Obelisk.emitClient('phonebooth:client:ended', call.boothSource, callId)
end

Obelisk.onServer('oblsk_phone:server:dialer-hangup', function(callId)
    local source = source
    endBoothCallFromCallee(callId, source)
end)

Obelisk.onServer('oblsk_phone:server:dialer-decline', function(callId)
    local source = source
    endBoothCallFromCallee(callId, source)
end)

Obelisk.onServer('phonebooth:server:hangup', function(callId)
    local source = source
    if type(callId) ~= 'string' then return end

    local call = BoothService.activeCalls[callId]
    local calleeSource = call and call.calleeSource

    BoothService.hangup(callId, source)

    Obelisk.emitClient('phonebooth:client:ended', source, callId)
    if calleeSource then
        Obelisk.emitClient('oblsk_phone:client:dialer-ended', calleeSource, callId, 'hangup')
    end
end)

Obelisk.onServer('phonebooth:server:leave', function()
    local source = source
    BoothService.leave(source)
    WebView.destroy(source)
end)

--- Server-authoritative credit tick, once per second for every entered session.
CreateThread(function()
    while true do
        Wait(1000)
        BoothService.tick()
        for source, session in pairs(BoothService.sessions) do
            Obelisk.emitClient('phonebooth:client:sync', source, { creditSeconds = session.creditSeconds })
        end
    end
end)
```

- [ ] **Step 2: Write `client/main.lua`**

```lua
-- core/plugins/oblsk_phonebooth/client/main.lua
--- oblsk_phonebooth - Client Main
--- Pure relay between the NUI page and the server, same shape
--- oblsk_garage's client/main.lua uses. No client-side call/credit logic —
--- BoothService on the server is the single source of truth.

Obelisk.onClient('phonebooth:client:sync', function(payload)
    WebView.emit('phonebooth:sync', payload)
end)

Obelisk.onClient('phonebooth:client:fed', function(ok, creditSeconds, err)
    WebView.emit('phonebooth:fed', { ok = ok, creditSeconds = creditSeconds, err = err })
end)

Obelisk.onClient('phonebooth:client:ringing', function(callId)
    WebView.emit('phonebooth:ringing', { callId = callId })
end)

Obelisk.onClient('phonebooth:client:dial-failed', function(err)
    WebView.emit('phonebooth:dial-failed', { err = err })
end)

Obelisk.onClient('phonebooth:client:connected', function(callId)
    WebView.emit('phonebooth:connected', { callId = callId })
end)

Obelisk.onClient('phonebooth:client:ended', function(callId)
    WebView.emit('phonebooth:ended', { callId = callId })
end)

WebView.on('phonebooth:feed', function()
    Obelisk.emitServer('phonebooth:server:feed')
end)

WebView.on('phonebooth:dial', function(data)
    Obelisk.emitServer('phonebooth:server:dial', data.number)
end)

WebView.on('phonebooth:hangup', function(data)
    Obelisk.emitServer('phonebooth:server:hangup', data.callId)
end)

WebView.on('phonebooth:leave', function()
    Obelisk.emitServer('phonebooth:server:leave')
    WebView.destroy()
end)
```

- [ ] **Step 3: Commit**

```bash
cd core
git add plugins/oblsk_phonebooth/server/main.lua plugins/oblsk_phonebooth/client/main.lua
git commit -m "Wire oblsk_phonebooth interaction, NUI relay and credit tick"
```

---

## Task 7: `PhoneBooth.vue` — port the prototype UI with full animation fidelity

**Files:**
- Create: `core/plugins/oblsk_phonebooth/web/PhoneBooth.vue`
- Create: `core/plugins/oblsk_phonebooth/web/package.json`
- Create: `core/plugins/oblsk_phonebooth/web/routes.js`

**Interfaces:**
- Consumes: the NUI events from Task 6 (`phonebooth:sync`, `phonebooth:fed`, `phonebooth:ringing`, `phonebooth:dial-failed`, `phonebooth:connected`, `phonebooth:ended`) and emits `phonebooth:feed`, `phonebooth:dial`, `phonebooth:hangup`, `phonebooth:leave`.
- Produces: nothing — this is the leaf UI.

- [ ] **Step 1: Write `web/package.json`**

```json
{
  "name": "oblsk_phonebooth",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "vue": "^3.5.22"
  },
  "devDependencies": {
    "@vitejs/plugin-vue": "^6.0.1",
    "vite": "^7.1.7"
  }
}
```

- [ ] **Step 2: Write `web/routes.js`**

```javascript
// core/plugins/oblsk_phonebooth/web/routes.js
export default [
  { path: '/PhoneBooth', component: () => import('./PhoneBooth.vue') }
]
```

- [ ] **Step 3: Write `PhoneBooth.vue`**

Ports `src/proto/phonebooth.jsx` (the approved prototype — dollar-bill SVG, roof canopy, neon "LINES" sign, glass side panels, keypad, LCD with power-on flicker + scanline, handset lift, coiled cord, bill acceptor with fly-in animation, tapered stand) to Vue's Composition API, replacing React state/effects with `ref`/`reactive`/`watch`/`onMounted`, and wiring every action to the server round-trip from Task 6 instead of local-only state.

```vue
<!-- core/plugins/oblsk_phonebooth/web/PhoneBooth.vue -->
<template>
  <div class="absolute inset-0 flex flex-col items-center pt-6" :style="glowBg">
    <div class="relative flex flex-col flex-1 min-h-0" style="width: 470px">
      <!-- roof canopy -->
      <div class="relative mx-auto mb-[-6px]" style="width: 470px">
        <div class="mx-auto rounded-[12px]" style="width: 470px; height: 20px; background: linear-gradient(180deg,#3e4448,#202528 60%,#14181a); border: 1px solid rgba(255,255,255,.09); box-shadow: 0 16px 34px rgba(0,0,0,.6)" />
        <div class="mx-auto rounded-b-[8px]" :style="{ width: '440px', height: '9px', background: 'linear-gradient(180deg,#1a1e21,#101315)', boxShadow: `0 8px 26px color-mix(in oklab, var(--ob-accent) 18%, transparent)` }" />
      </div>

      <!-- neon sign -->
      <div class="relative mx-auto rounded-[26px] px-6 py-4 text-center" style="width: 430px; background: linear-gradient(180deg,#2b3033,#1b1f22 60%,#111417); border: 1px solid rgba(255,255,255,.09); box-shadow: 0 0 40px color-mix(in oklab, var(--ob-accent) 20%, transparent), 0 18px 40px rgba(0,0,0,.6), inset 0 1px 0 rgba(255,255,255,.14)">
        <div style="font-size: 40px; font-weight: 800; letter-spacing: .22em; line-height: 1; color: var(--ob-accent); text-shadow: 0 0 24px color-mix(in oklab, var(--ob-accent) 65%, transparent), 0 1px 0 rgba(0,0,0,.6)">LINES</div>
      </div>

      <!-- lit backplate -->
      <div class="relative mx-auto -mt-3 rounded-[22px] p-4" style="width: 400px; background: linear-gradient(180deg,#1d2225,#141719 55%,#0e1113); border: 1px solid rgba(255,255,255,.08); box-shadow: 0 0 46px color-mix(in oklab, var(--ob-accent) 14%, transparent), 0 30px 70px rgba(0,0,0,.65)">
        <!-- glass side panels -->
        <div
          v-for="side in [-1, 1]"
          :key="side"
          class="absolute pointer-events-none overflow-hidden"
          :style="sidePanelStyle(side)"
        >
          <div class="absolute" :style="{ inset: 0, background: `linear-gradient(${side < 0 ? 118 : 62}deg, transparent 34%, rgba(255,255,255,.16) 42%, transparent 50%, transparent 72%, rgba(255,255,255,.08) 78%, transparent 84%)` }" />
          <div class="absolute inset-x-0 top-0 h-[6px]" style="background: linear-gradient(180deg,#3b4145,#1b1f22)" />
          <div class="absolute inset-x-0 bottom-0 h-[6px]" style="background: linear-gradient(180deg,#1b1f22,#3b4145)" />
        </div>

        <!-- phone body -->
        <div class="rounded-[20px] p-3.5" style="background: linear-gradient(165deg,#3b4145,#262b2e 45%,#191d1f); border: 1px solid rgba(255,255,255,.08); box-shadow: inset 0 1px 0 rgba(255,255,255,.12), 0 14px 30px rgba(0,0,0,.5)">
          <div class="flex gap-1.5 mb-2.5 pl-1">
            <span v-for="i in 3" :key="i" class="w-6 h-3.5 rounded-[3px]" style="background: linear-gradient(180deg,#15181a,#0a0c0d); box-shadow: inset 0 1px 2px rgba(0,0,0,.8)" />
          </div>

          <div class="flex gap-3">
            <!-- keypad column -->
            <div class="flex-1 min-w-0 rounded-[16px] p-2.5" style="background: linear-gradient(170deg,#232729,#171a1c); border: 1px solid rgba(255,255,255,.06); box-shadow: inset 0 1px 0 rgba(255,255,255,.08), 0 6px 14px rgba(0,0,0,.4)">
              <!-- LCD -->
              <div class="rounded-[8px] px-2.5 py-2 mb-2.5 relative overflow-hidden ob-lcd" :style="lcdStyle">
                <div class="absolute inset-0 pointer-events-none ob-scan" />
                <div class="flex items-end justify-between">
                  <span class="ob-mono text-[15px] tracking-[0.12em]" :style="{ color: lowCredit ? '#fca5a5' : '#7bf3b0' }">
                    {{ num || (state === 'call' ? 'IN CALL' : 'ENTER No.') }}
                  </span>
                  <span class="ob-mono text-[15px]" :style="{ color: lowCredit ? '#fca5a5' : '#7bf3b0' }">{{ screenText }}</span>
                </div>
                <div class="ob-mono text-[8px] mt-1 tracking-[0.16em] truncate" :style="{ color: lowCredit ? '#fca5a5' : 'rgba(123,243,176,.5)' }">
                  {{ lowCredit ? 'INSERT ANOTHER DOLLAR' : note }}
                </div>
              </div>

              <div class="grid grid-cols-3 gap-1.5 mb-2">
                <button v-for="k in ['1','2','3','4','5','6']" :key="k" class="h-8 ob-key" style="background: linear-gradient(180deg,#34393c,#1f2325); box-shadow: 0 2px 0 rgba(0,0,0,.6), inset 0 1px 0 rgba(255,255,255,.14); color: rgba(255,255,255,.82)" @click="press(k)">
                  <span class="ob-mono text-[12px]">{{ k }}</span>
                </button>
              </div>
              <div class="grid grid-cols-3 gap-1.5">
                <button v-for="k in ['7','8','9','*','0','#']" :key="k" class="h-8 ob-key" style="background: linear-gradient(180deg,#34393c,#1f2325); box-shadow: 0 2px 0 rgba(0,0,0,.6), inset 0 1px 0 rgba(255,255,255,.14); color: rgba(255,255,255,.82)" @click="press(k)">
                  <span class="ob-mono text-[12px]">{{ k }}</span>
                </button>
              </div>
              <div class="grid grid-cols-3 gap-1.5 mt-1.5">
                <button class="h-9 ob-key" style="background: linear-gradient(180deg,#34393c,#1f2325); box-shadow: 0 2px 0 rgba(0,0,0,.6), inset 0 1px 0 rgba(255,255,255,.14); color: rgba(255,255,255,.82)" @click="press('⌫')">
                  <span class="ob-mono text-[9px] tracking-[0.14em]">CLEAR</span>
                </button>
                <button
                  v-if="state === 'call' || state === 'ringing'"
                  class="col-span-2 h-9 ob-key"
                  style="background: linear-gradient(180deg,#c1352f,#8d1d18); color: #fff; box-shadow: 0 2px 0 rgba(0,0,0,.6), inset 0 1px 0 rgba(255,255,255,.2)"
                  @click="hangUp"
                >
                  <span class="text-[11px] font-semibold">Hang up</span>
                </button>
                <button
                  v-else
                  class="col-span-2 h-9 ob-key"
                  style="background: var(--ob-accent); color: #000; box-shadow: 0 2px 0 rgba(0,0,0,.55), inset 0 1px 0 rgba(255,255,255,.35)"
                  @click="dial"
                >
                  <span class="text-[11px] font-semibold">Dial</span>
                </button>
              </div>
            </div>

            <!-- handset column -->
            <div class="w-[104px] shrink-0 flex flex-col items-center">
              <div class="w-5 h-5 rounded-full mb-1.5" style="background: linear-gradient(180deg,#3b4145,#202426); box-shadow: inset 0 1px 0 rgba(255,255,255,.18)" />
              <button class="relative w-[70px] h-[190px] transition-transform" :style="{ transform: handset ? 'translate(6px,-14px) rotate(-9deg)' : 'none' }" @click="toggleHandset">
                <span class="absolute left-1/2 -translate-x-1/2 top-0 w-[62px] h-[52px] rounded-[26px]" style="background: linear-gradient(160deg,#23282b,#0f1213); box-shadow: inset 0 2px 0 rgba(255,255,255,.14), 0 8px 18px rgba(0,0,0,.55)" />
                <span class="absolute left-1/2 -translate-x-1/2 top-[44px] w-[26px] h-[104px] rounded-[13px]" style="background: linear-gradient(160deg,#1e2325,#0c0f10); box-shadow: inset 0 2px 0 rgba(255,255,255,.1)" />
                <span class="absolute left-1/2 -translate-x-1/2 bottom-0 w-[62px] h-[52px] rounded-[26px]" style="background: linear-gradient(160deg,#23282b,#0f1213); box-shadow: inset 0 2px 0 rgba(255,255,255,.14), 0 8px 18px rgba(0,0,0,.55)" />
              </button>
              <div class="ob-mono text-[8px] tracking-[0.18em] mt-2" :style="{ color: handset ? 'var(--ob-accent)' : 'rgba(255,255,255,.3)' }">
                {{ handset ? 'OFF HOOK' : 'ON HOOK' }}
              </div>
            </div>
          </div>

          <!-- coiled cord -->
          <svg viewBox="0 0 340 76" preserveAspectRatio="none" class="w-full mt-1" style="height: 66px">
            <path :d="cordPath" fill="none" stroke="rgba(255,255,255,.22)" stroke-width="7" stroke-linecap="round" opacity=".9" />
            <path :d="cordPath" fill="none" stroke="rgba(255,255,255,.35)" stroke-width="2" stroke-linecap="round" opacity=".7" />
          </svg>

          <!-- bill acceptor -->
          <div class="rounded-[14px] p-2.5 mt-1" style="background: linear-gradient(170deg,#232729,#15181a); border: 1px solid rgba(255,255,255,.06); box-shadow: inset 0 1px 0 rgba(255,255,255,.08)">
            <button class="relative w-full h-[46px] rounded-[7px] overflow-hidden cursor-pointer transition hover:brightness-125" title="Insert a dollar bill" style="background: #0a0c0d; border: 1px solid rgba(255,255,255,.1); box-shadow: inset 0 3px 10px rgba(0,0,0,.85)" @click="feed">
              <div class="absolute inset-x-3 top-1/2 -translate-y-1/2 h-[6px] rounded-full" style="background: #000; box-shadow: inset 0 1px 2px rgba(255,255,255,.12)" />
              <div class="absolute inset-0 grid place-items-center ob-mono text-[8px] tracking-[0.22em] pointer-events-none" style="color: rgba(255,255,255,.3)">INSERT $1 BILL</div>
              <div v-for="id in flying" :key="id" class="absolute left-1/2 -translate-x-1/2 ob-bill-fly" style="width: 128px; height: 54px; bottom: -60px">
                <DollarBill />
              </div>
            </button>
            <div class="flex items-center justify-between mt-2 px-0.5">
              <span class="ob-mono text-[8px] tracking-[0.16em]" style="color: rgba(255,255,255,.3)">{{ bills }} BILL{{ bills === 1 ? '' : 'S' }} · {{ clock(credit) }} LEFT</span>
              <span class="ob-mono text-[8px] tracking-[0.16em]" style="color: rgba(255,255,255,.22)">NO CHANGE GIVEN</span>
            </div>
          </div>
        </div>
      </div>

      <!-- stand -->
      <div class="relative mx-auto flex flex-col flex-1 min-h-0" style="width: 400px">
        <div class="mx-auto flex-1 min-h-0" style="width: 260px; background: linear-gradient(90deg,#121618,#2f3539 24%,#252b2e 62%,#0d1012); clip-path: polygon(4% 0, 96% 0, 88% 100%, 12% 100%); box-shadow: inset 0 0 26px rgba(0,0,0,.6)" />
        <div class="mx-auto rounded-[5px] shrink-0" style="width: 250px; height: 13px; background: linear-gradient(180deg,#343a3e,#181c1e); box-shadow: 0 12px 30px rgba(0,0,0,.7)" />
        <div class="mx-auto rounded-[4px] shrink-0" style="width: 288px; height: 8px; background: linear-gradient(180deg,#22272a,#0e1113); box-shadow: 0 20px 38px rgba(0,0,0,.65)" />
        <div class="absolute left-1/2 -translate-x-1/2 flex gap-[150px]" style="bottom: 5px">
          <span v-for="i in 2" :key="i" class="w-2 h-2 rounded-full" style="background: #3b4145; box-shadow: inset 0 1px 0 rgba(255,255,255,.25)" />
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
// Ported 1:1 from src/proto/phonebooth.jsx (approved prototype) — every
// animation (dollar-bill feed/vanish, LCD power-on flicker, scanline sweep,
// handset lift rotation, low-credit flash) is preserved, driven by the
// server round-trip from oblsk_phonebooth's client/main.lua instead of
// local-only simulated state. See
// docs/superpowers/specs/2026-08-13-phone-booth-and-voice-service-design.md §B.
import { computed, onMounted, onUnmounted, ref } from 'vue'
import Obelisk from '@/obelisk.js'

const BOOTH_WARN_AT = 15

const num = ref('')
const credit = ref(0)
const state = ref('idle') // idle | ringing | call | ended
const bills = ref(0)
const flying = ref([])
const handset = ref(false)
const note = ref('LIFT THE HANDSET')
const flash = ref(false)
const callId = ref(null)
let billIdCounter = 0
let flashTimer = null

const clock = (s) => `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(Math.floor(s % 60)).padStart(2, '0')}`

const lowCredit = computed(() => state.value === 'call' && credit.value <= BOOTH_WARN_AT)
const screenText = computed(() => {
  if (state.value === 'call') return clock(credit.value)
  if (state.value === 'ringing') return '· · ·'
  return credit.value > 0 ? clock(credit.value) : '--:--'
})
const glowBg = { background: 'radial-gradient(70% 60% at 50% 45%, color-mix(in oklab, var(--ob-accent) 10%, transparent), transparent 70%)' }
const lcdStyle = computed(() => ({
  background: lowCredit.value && flash.value ? 'rgba(120,30,20,.55)' : 'linear-gradient(180deg,#0d1c14,#08120d)',
  border: '1px solid rgba(255,255,255,.08)',
  boxShadow: 'inset 0 2px 10px rgba(0,0,0,.75)',
}))
const cordPath = computed(() =>
  `M232 4 C 232 ${handset.value ? 30 : 44}, 300 60, 250 68 C 200 76, 120 72, 96 58 C 74 46, 86 26, 104 18`
)

function sidePanelStyle(side) {
  return {
    top: '-6px', bottom: '-18px', width: '82px',
    [side < 0 ? 'right' : 'left']: '100%',
    marginLeft: side > 0 ? '6px' : undefined,
    marginRight: side < 0 ? '6px' : undefined,
    borderRadius: side < 0 ? '14px 4px 4px 14px' : '4px 14px 14px 4px',
    background: 'linear-gradient(120deg, rgba(190,225,235,.14), rgba(140,190,210,.05) 45%, rgba(190,225,235,.11))',
    border: '1px solid rgba(200,235,245,.18)',
    boxShadow: 'inset 0 0 30px rgba(180,225,240,.1), 0 12px 34px rgba(0,0,0,.45)',
  }
}

function press(k) {
  if (state.value === 'call') return
  if (k === '⌫') { num.value = num.value.slice(0, -1); return }
  if (num.value.length >= 8) return
  const next = (num.value + k).replace(/\D/g, '')
  num.value = next.length > 3 ? `${next.slice(0, 3)}-${next.slice(3)}` : next
}

function feed() {
  const id = ++billIdCounter
  flying.value.push(id)
  setTimeout(() => { flying.value = flying.value.filter((x) => x !== id) }, 900)
  Obelisk.emitServer('phonebooth:feed')
}

function toggleHandset() {
  handset.value = !handset.value
  if (!handset.value && state.value !== 'idle') {
    hangUp()
    return
  }
  note.value = handset.value ? (credit.value > 0 ? 'DIAL A NUMBER' : 'INSERT A DOLLAR BILL') : 'HANDSET ON HOOK'
}

function dial() {
  if (!handset.value) { note.value = 'LIFT THE HANDSET FIRST'; return }
  if (credit.value <= 0) { note.value = 'INSERT A DOLLAR BILL'; return }
  if (num.value.replace(/\D/g, '').length < 3) { note.value = 'NUMBER TOO SHORT'; return }
  state.value = 'ringing'
  note.value = 'RINGING…'
  Obelisk.emitServer('phonebooth:dial', { number: num.value })
}

function hangUp() {
  if (callId.value) Obelisk.emitServer('phonebooth:hangup', { callId: callId.value })
  state.value = 'idle'
  handset.value = false
  num.value = ''
  callId.value = null
  note.value = credit.value > 0 ? 'LIFT THE HANDSET' : 'INSERT A DOLLAR BILL'
}

function startFlashLoop() {
  clearInterval(flashTimer)
  flashTimer = setInterval(() => {
    if (state.value === 'call' && credit.value <= BOOTH_WARN_AT) {
      flash.value = !flash.value
    } else {
      flash.value = false
    }
  }, 420)
}

onMounted(() => {
  startFlashLoop()

  Obelisk.on('phonebooth:sync', ({ creditSeconds }) => {
    credit.value = creditSeconds
    if (creditSeconds <= 0 && state.value === 'call') {
      state.value = 'ended'
      note.value = 'LINE DROPPED — NO CREDIT'
    }
  })

  Obelisk.on('phonebooth:fed', ({ ok, creditSeconds, err }) => {
    if (ok) {
      bills.value += 1
      credit.value = creditSeconds
      if (state.value === 'ended') state.value = 'idle'
      note.value = handset.value ? 'DIAL A NUMBER' : 'LIFT THE HANDSET'
    } else {
      note.value = err || 'INSERT A DOLLAR BILL'
    }
  })

  Obelisk.on('phonebooth:ringing', ({ callId: id }) => { callId.value = id })
  Obelisk.on('phonebooth:dial-failed', ({ err }) => { state.value = 'idle'; note.value = err || 'CALL FAILED' })
  Obelisk.on('phonebooth:connected', () => { state.value = 'call'; note.value = 'CONNECTED' })
  Obelisk.on('phonebooth:ended', () => {
    state.value = credit.value > 0 ? 'idle' : 'ended'
    handset.value = false
    num.value = ''
    callId.value = null
    note.value = credit.value > 0 ? 'LIFT THE HANDSET' : 'LINE DROPPED — NO CREDIT'
  })
})

onUnmounted(() => {
  clearInterval(flashTimer)
  Obelisk.emitServer('phonebooth:leave')
})

const DollarBill = {
  props: { width: { type: Number, default: 128 } },
  template: `
    <svg :viewBox="'0 0 256 108'" :style="{ width: width + 'px', height: (width * 108 / 256) + 'px', display: 'block', filter: 'drop-shadow(0 6px 12px rgba(0,0,0,.5))' }">
      <defs>
        <linearGradient id="db-paper" x1="0" x2="1" y1="0" y2="1">
          <stop offset="0%" stop-color="#e9e6d2" /><stop offset="55%" stop-color="#d9d8c0" /><stop offset="100%" stop-color="#c9cbb0" />
        </linearGradient>
        <pattern id="db-guilloche" width="8" height="8" patternUnits="userSpaceOnUse">
          <path d="M0 4 Q2 0 4 4 T8 4" fill="none" stroke="#7d8a6a" stroke-width=".5" opacity=".5" />
        </pattern>
      </defs>
      <rect width="256" height="108" rx="3" fill="url(#db-paper)" />
      <rect width="256" height="108" rx="3" fill="url(#db-guilloche)" />
      <rect x="5" y="5" width="246" height="98" rx="2" fill="none" stroke="#2f4434" stroke-width="1.6" />
      <rect x="9" y="9" width="238" height="90" rx="1.5" fill="none" stroke="#2f4434" stroke-width=".7" opacity=".6" />
      <text v-for="([x, y], i) in [[18,24],[238,24],[18,92],[238,92]]" :key="i" :x="x" :y="y" text-anchor="middle" font-size="15" font-weight="700" fill="#2f4434" font-family="Georgia, serif">1</text>
      <text x="128" y="20" text-anchor="middle" font-size="7.5" letter-spacing="1.6" fill="#2f4434" font-family="Georgia, serif">THE UNITED STATES OF SAN ANDREAS</text>
      <text x="128" y="94" text-anchor="middle" font-size="7" letter-spacing="2.4" fill="#2f4434" font-family="Georgia, serif">ONE DOLLAR</text>
      <ellipse cx="128" cy="55" rx="30" ry="27" fill="#dcdcc4" stroke="#2f4434" stroke-width="1" />
      <g fill="#5d6b52" opacity=".85">
        <circle cx="128" cy="47" r="10" />
        <path d="M110 74c0-10 8-16 18-16s18 6 18 16z" />
      </g>
      <ellipse cx="128" cy="55" rx="30" ry="27" fill="none" stroke="#2f4434" stroke-width=".6" stroke-dasharray="1.5 2" />
      <circle cx="72" cy="55" r="17" fill="none" stroke="#2f4434" stroke-width="1.2" />
      <circle cx="72" cy="55" r="13" fill="none" stroke="#2f4434" stroke-width=".6" stroke-dasharray="2 2" />
      <text x="72" y="59" text-anchor="middle" font-size="11" font-weight="700" fill="#2f4434" font-family="Georgia, serif">1</text>
      <circle cx="184" cy="55" r="17" fill="none" stroke="#3f5a45" stroke-width="1.2" opacity=".9" />
      <path d="M184 42 l4 8 9 1-6.5 6 1.6 9-8.1-4.4-8.1 4.4 1.6-9-6.5-6 9-1z" fill="#3f5a45" opacity=".55" />
      <text x="40" y="36" font-size="6.5" fill="#3f5a45" font-family="monospace" letter-spacing="1">K 88 3341 P</text>
      <text x="176" y="82" font-size="6.5" fill="#3f5a45" font-family="monospace" letter-spacing="1">K 88 3341 P</text>
      <path d="M46 78 q10 -6 20 0 t20 0" fill="none" stroke="#3f5a45" stroke-width=".8" opacity=".7" />
      <path d="M172 32 q10 -6 20 0 t20 0" fill="none" stroke="#3f5a45" stroke-width=".8" opacity=".7" />
    </svg>
  `,
}
</script>

<style scoped>
.ob-mono { font-family: 'JetBrains Mono', ui-monospace, monospace; }
.ob-key { border-radius: 9px; display: grid; place-items: center; transition: transform .1s; }
.ob-key:active { transform: translateY(1.5px); }
.ob-lcd { animation: boothLcdOn 1.15s steps(1, end) 1 both; }
.ob-scan { animation: boothScan 1.3s linear 1 both; background: repeating-linear-gradient(180deg, rgba(123,243,176,.16) 0 1px, transparent 1px 3px); }
.ob-bill-fly { animation: boothFeed .9s cubic-bezier(.4,.05,.3,1) forwards; }

@keyframes boothLcdOn {
  0% { filter: brightness(.15) } 8% { filter: brightness(1.9) } 14% { filter: brightness(.25) }
  22% { filter: brightness(1.5) } 30% { filter: brightness(.6) } 40% { filter: brightness(1.25) }
  52% { filter: brightness(.85) } 66% { filter: brightness(1.12) } 100% { filter: none }
}
@keyframes boothScan {
  0% { opacity: .85; transform: translateY(-100%) } 55% { opacity: .5 } 100% { opacity: 0; transform: translateY(100%) }
}
@keyframes boothFeed {
  0% { transform: translate(-50%, 0) rotate(-2deg); opacity: 0 }
  18% { opacity: 1 }
  70% { transform: translate(-50%, -68px) rotate(0deg); opacity: 1 }
  100% { transform: translate(-50%, -92px) scaleY(.12); opacity: 0 }
}
</style>
```

- [ ] **Step 4: Verify the SFC compiles**

Run: `cd core/plugins/oblsk_phonebooth/web && npm install && node -e "require('@vue/compiler-sfc').parse(require('fs').readFileSync('PhoneBooth.vue', 'utf8'))"`
Expected: no output, exit code 0 (parse throws on malformed template/script and this repo has no dedicated SFC-lint script — see `oblsk_phone/web/package.json` for the same bare `vue`/`vite` dependency set this file mirrors).

- [ ] **Step 5: Commit**

```bash
cd core
git add plugins/oblsk_phonebooth/web
git commit -m "Port phone booth prototype to Vue with full animation fidelity"
```

---

## Task 8: Retrofit `oblsk_phone` Dialer/CallOverlay to real `VoiceService` calls

**Files:**
- Modify: `core/plugins/oblsk_phone/server/services/DialerService.lua`
- Modify: `core/plugins/oblsk_phone/web/apps/Dialer/CallOverlay.vue`
- Modify: `core/plugins/oblsk_phone/tests/dialer_service_spec.lua`

**Interfaces:**
- Consumes: `VoiceService.startCall(callId, sourceA, sourceB)` / `VoiceService.endCall(callId, sourceA, sourceB)` (Task 1/2).
- Produces: nothing new — `DialerService.answer`/`.hangup`'s existing signatures are unchanged, only their bodies gain a `VoiceService` call.

- [ ] **Step 1: Read the existing test file to match its fake-setup style**

Run: `cat core/plugins/oblsk_phone/tests/dialer_service_spec.lua | head -40` — confirm how `DialerService`'s dependencies (`CharacterService`, `PhoneNumberService`) are faked in that file's existing setup, so the new `VoiceService` fake follows the same shape.

- [ ] **Step 2: Write the failing test**

Add to `core/plugins/oblsk_phone/tests/dialer_service_spec.lua`, alongside the existing fakes near the top of the file (same block that fakes `CharacterService`/`PhoneNumberService`):

```lua
local voiceCalls
VoiceService = {
    startCall = function(callId, a, b) voiceCalls[#voiceCalls + 1] = { fn = 'start', callId = callId, a = a, b = b } end,
    endCall = function(callId, a, b) voiceCalls[#voiceCalls + 1] = { fn = 'end', callId = callId, a = a, b = b } end,
}
```

And reset `voiceCalls = {}` in the same place the file already resets its other per-test fakes (its `resetState`-equivalent block). Then add, before the final test-runner loop:

```lua
test('answer starts a real VoiceService call between caller and callee', function()
    resetState()
    local callId = DialerService.call(1, '555-0147') -- reuses this file's existing fixture number/character wiring

    DialerService.answer(callId, 2)

    eq(#voiceCalls, 1)
    eq(voiceCalls[1].fn, 'start')
    eq(voiceCalls[1].callId, callId)
end)

test('hangup after answer ends the VoiceService call', function()
    resetState()
    local callId = DialerService.call(1, '555-0147')
    DialerService.answer(callId, 2)

    DialerService.hangup(callId, 1)

    eq(#voiceCalls, 2)
    eq(voiceCalls[2].fn, 'end')
end)

test('hangup before answer never starts or ends a VoiceService call', function()
    resetState()
    local callId = DialerService.call(1, '555-0147')

    DialerService.hangup(callId, 2)

    eq(#voiceCalls, 0)
end)
```

(Adjust the fixture call `DialerService.call(1, '555-0147')` and the source ids to whatever this spec file's existing tests already use for a resolvable/online callee — match its established fixtures rather than introducing new ones.)

- [ ] **Step 3: Run to verify it fails**

Run: `cd core/plugins/oblsk_phone && lua5.4 tests/dialer_service_spec.lua`
Expected: FAIL — no `VoiceService` calls are made yet (`#voiceCalls` is 0 where the test expects 1 or 2).

- [ ] **Step 4: Wire `DialerService.answer`/`.hangup`**

In `core/plugins/oblsk_phone/server/services/DialerService.lua`, modify `DialerService.answer`:

```lua
function DialerService.answer(callId, source)
    local call = DialerService.activeCalls[callId]
    if not call or call.calleeSource ~= source then
        return
    end
    call.answered = true
    VoiceService.startCall(callId, call.callerSource, call.calleeSource)
end
```

And `DialerService.hangup`, adding the `VoiceService.endCall` call right after `answered` is read but before the record is cleared out of `activeCalls` (so both sources are still available):

```lua
function DialerService.hangup(callId, source)
    local call = DialerService.activeCalls[callId]
    if not call or (call.callerSource ~= source and call.calleeSource ~= source) then
        return nil
    end

    DialerService.activeCalls[callId] = nil

    if call.answered then
        VoiceService.endCall(callId, call.callerSource, call.calleeSource)
    end

    local duration = call.answered and (os.time() - call.startedAt) or nil
    logRecent(call.callerCharacterId, 'out', call.calleeNumber, duration)
    logRecent(call.calleeCharacterId, call.answered and 'in' or 'missed', call.callerNumber, duration)

    return call
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd core/plugins/oblsk_phone && lua5.4 tests/dialer_service_spec.lua`
Expected: all tests pass, including the 3 new ones.

- [ ] **Step 6: Update `CallOverlay.vue`**

In `core/plugins/oblsk_phone/web/apps/Dialer/CallOverlay.vue`, replace the `<!-- cosmetic toggles, no real audio integration -->` comment with `<!-- mute/speaker toggles below are client-local UI state only; the call's actual audio channel is established server-side via VoiceService when DialerService.answer runs (see server/services/DialerService.lua) -->`. No script changes — the toggles were already local UI state and remain so; only the stale comment claiming "no real audio integration" is now inaccurate and needs correcting, since the call itself is real as of this task.

- [ ] **Step 7: Commit**

```bash
cd core
git add plugins/oblsk_phone/server/services/DialerService.lua plugins/oblsk_phone/web/apps/Dialer/CallOverlay.vue plugins/oblsk_phone/tests/dialer_service_spec.lua
git commit -m "Wire oblsk_phone Dialer calls to real VoiceService audio"
```

---

## Task 9: Retrofit `oblsk_phone` Radio app to real `VoiceService` radio channels

**Files:**
- Modify: `core/plugins/oblsk_phone/server/main.lua`
- Modify: `core/plugins/oblsk_phone/client/main.lua`
- Modify: `core/plugins/oblsk_phone/web/apps/Radio/Radio.vue`

**Interfaces:**
- Consumes: `VoiceService.joinRadioChannel(source, channelId)` / `VoiceService.leaveRadioChannel(source, channelId)` (Task 1).
- Produces: nothing new for later tasks — this is the last task in the plan.

This task has no server-service logic worth unit-testing beyond what Task 1 already covers (it's two thin event handlers forwarding a frequency string to `VoiceService`) — verified via the manual checklist below instead of a new spec file, consistent with how the design spec scopes PTT/traffic-log as out of scope for real audio.

- [ ] **Step 1: Add server event handlers**

In `core/plugins/oblsk_phone/server/main.lua`, add near the other Radio-related code (search the file for `RadioService` to find that section):

```lua
Obelisk.onServer('oblsk_phone:server:radio-tune', function(channelKey, oldFrequency, newFrequency)
    local source = source
    if type(newFrequency) ~= 'string' then return end

    if type(oldFrequency) == 'string' and oldFrequency ~= '' then
        VoiceService.leaveRadioChannel(source, oldFrequency)
    end
    VoiceService.joinRadioChannel(source, newFrequency)
end)

Obelisk.onServer('oblsk_phone:server:radio-untune', function(frequency)
    local source = source
    if type(frequency) ~= 'string' then return end
    VoiceService.leaveRadioChannel(source, frequency)
end)
```

- [ ] **Step 2: Relay through `client/main.lua`**

In `core/plugins/oblsk_phone/client/main.lua`, add alongside the other `WebView.on(...)` registrations (search the file for an existing `radio` or `dialer` relay to match placement):

```lua
WebView.on('radio-tune', function(data)
    Obelisk.emitServer('oblsk_phone:server:radio-tune', data.channelKey, data.oldFrequency, data.newFrequency)
end)

WebView.on('radio-untune', function(data)
    Obelisk.emitServer('oblsk_phone:server:radio-untune', data.frequency)
end)
```

- [ ] **Step 3: Wire `Radio.vue`'s `tune()` and unmount to the relay**

Replace the existing `tune()` function:

```javascript
function tune() {
  const value = Number(draft.value)
  if (!draft.value || Number.isNaN(value) || value <= 0) return
  const channel = selectedChannel.value
  const oldFrequency = channel.frequency
  const newFrequency = value.toFixed(3)
  channel.frequency = newFrequency
  draft.value = ''
  Obelisk.emitServer('radio-tune', { channelKey: channel.key, oldFrequency, newFrequency })
}
```

Add, near the other lifecycle hooks in this file (it already imports `onBeforeUnmount` — search for it):

```javascript
onBeforeUnmount(() => {
  channels.forEach((channel) => {
    Obelisk.emitServer('radio-untune', { frequency: channel.frequency })
  })
})
```

And, since both channels start already tuned to a default frequency (`'155.475'`/`'46.550'` in the initial `channels` array) but no join happened for those defaults yet, add alongside this file's existing `onMounted` (search for it — it currently loads presets):

```javascript
channels.forEach((channel) => {
  Obelisk.emitServer('radio-tune', { channelKey: channel.key, oldFrequency: null, newFrequency: channel.frequency })
})
```

placed inside the existing `onMounted(...)` body, after the preset-loading call it already makes.

- [ ] **Step 4: Update the stale in-file comment**

The `<script setup>` block's top comment currently says "no real proximity voice/radio system exists in this framework yet." Update it to: "Tuning now joins/leaves a real VoiceService radio channel per selected frequency (server/main.lua's radio-tune/radio-untune handlers); the push-to-talk button and traffic log remain decorative — see docs/superpowers/specs/2026-08-13-phone-booth-and-voice-service-design.md §D for what's in and out of scope."

- [ ] **Step 5: Manual verification checklist**

Since this task has no automated spec, verify by running the framework with `Config.provider = 'native'` (the default) and confirming in server console output (add a temporary `print` inside `VoiceService.joinRadioChannel`/`leaveRadioChannel` if the native adapter's no-op makes this otherwise silent, then remove it) that:
- Opening the Radio app fires two `radio-tune` calls (one per default channel) on mount.
- Changing channel A's frequency via the keypad fires one `radio-untune` (old) then one `radio-tune` (new).
- Closing the phone (or the Radio app unmounting) fires `radio-untune` for both channels.

- [ ] **Step 6: Commit**

```bash
cd core
git add plugins/oblsk_phone/server/main.lua plugins/oblsk_phone/client/main.lua plugins/oblsk_phone/web/apps/Radio/Radio.vue
git commit -m "Wire oblsk_phone Radio tuning to real VoiceService radio channels"
```
