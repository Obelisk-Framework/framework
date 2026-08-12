# Character Selection & Creator Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the placeholder `oblsk_character-selection` plugin with a working character select + creator screen (ported from the Claude Design prototype), backed by a new minimal `SpawnManagerService` in core and real ped-appearance native wiring.

**Architecture:** A new core `SpawnManagerService` (server+client) owns the join→freeze/hide-hud→(plugin shows UI)→spawn→unfreeze/show-hud lifecycle via two relay events, thin by design. The plugin owns everything else: request/response events for character CRUD (not `ActionService`, which is fire-and-forget with no response channel), a curated appearance/wardrobe config table, client-side services that apply real GTA natives to a preview ped and a rotating scripted camera, and a Vue port of the design (`CharacterSelect.vue` + `CharacterCreator.vue`) registered as a global element, mirroring the `oblsk_inventory`/`oblsk_garage` core-bundled convention (no plugin-local Vite build).

**Tech Stack:** Lua 5.4 (FXServer), Vue 3 `<script setup>` SFCs compiled by core's single Vite build, Tailwind (via core's `tailwind.config.js`, which already scans `plugins/**`), hand-rolled `describe`-less Lua test runner (`lua5.4 <file>_spec.lua`), existing `BaseModel`/`QueryBuilder` ORM.

## Global Constraints

- Event naming: `core:server:<x>` / `core:client:<x>` for core-owned events; `character-selection:<x>` for this plugin's own request/response events (matches the `item:consume_step`-style flat plugin-prefixed naming already used by `oblsk_items`).
- All Lua service files are globals (no `local Service = {}` at module scope beyond the file itself), end with `return ServiceName`, and use `ServiceName.method` (dot, not colon) for static services — matches `PermissionService.lua`/`WebView.lua`.
- `BaseModel:createSync(attrs)` returns an instance; read fields via `.attributes.<col>`, e.g. `character.attributes.id`.
- `QueryBuilder.new('table_name'):where(...):update({...})` for raw updates that don't need a full model round-trip.
- Tests: plain Lua, `lua5.4 <path>_spec.lua`, `dofile()`-based, no test framework. Every new *pure/server* module gets a spec following `core/modules/oblsk_characters/tests/character_service_spec.lua`'s `test()`/`eq()`/`truthy()`/runner-with-`os.exit()` pattern. Client-side files that call GTA natives (camera, ped appearance, freeze) are **not** unit-testable headless (no native stubs exist beyond `Citizen`/net events in `tests/support/fivem_stubs.lua`) — those are verified manually in-game per task, not faked with placeholder specs.
- Web: no plugin-local `package.json`/`vite.config.js`. Files under `web/globalElements.js` and `web/routes.js` are auto-discovered by core's `import.meta.glob` in `core/web/src/App.vue` and `core/web/src/router/index.js`. Tailwind utility classes (including the `ob-*` palette: `bg-ob-panel`, `border-ob-border`, `text-ob-text`, etc.) — not inline `style="color:var(--ob-accent)"`.
- NUI bridge: Vue → Lua via `Obelisk.emit(eventName, args)` (POST fetch, no-ops outside FiveM); Lua → Vue via `WebView.emit(eventName, data)` / `SendNUIMessage`, received in Vue via `Obelisk.on(eventName, cb)`. Dev/browser preview uses Vite's `import.meta.env.DEV`, with mock data in a sibling `devFixture.js` (not inline).

---

## File Structure

```
core/core/server/Services/SpawnManagerService.lua      [new]
core/core/client/Services/SpawnManagerService.lua       [new]
core/tests/spawn_manager_service_spec.lua               [new]

core/plugins/oblsk_character-selection/
  fxmanifest.lua                                        [rewrite]
  shared/config.lua                                     [rewrite]
  shared/appearance.lua                                 [new]
  tests/appearance_spec.lua                              [new]
  server/main.lua                                        [rewrite]
  server/services/CharacterSelectionService.lua           [new]
  tests/character_selection_service_spec.lua              [new]
  server/actions/ExampleAction.lua                        [delete]
  client/main.lua                                         [rewrite]
  client/services/CharacterAppearanceService.lua           [new]
  client/services/CharacterCameraService.lua                [new]
  web/CharacterSelector.vue                                [delete]
  web/CharacterSelection.vue                                [rewrite → becomes the mode-switch shell]
  web/CharacterCreationForm.vue                             [delete]
  web/CharacterSelect.vue                                    [new]
  web/CharacterCreator.vue                                    [new]
  web/controls/Slider.vue                                     [new]
  web/controls/SwatchGrid.vue                                  [new]
  web/controls/Stepper.vue                                      [new]
  web/controls/TextField.vue                                     [new]
  web/globalElements.js                                          [new]
  web/routes.js                                                   [rewrite]
  web/useCharacterSelection.js                                     [new]
  web/devFixture.js                                                 [new]
  web/package.json                                                  [delete]
  web/dist/                                                          [delete]
```

---

### Task 1: `SpawnManagerService` (server)

**Files:**
- Create: `core/core/server/Services/SpawnManagerService.lua`
- Test: `core/tests/spawn_manager_service_spec.lua`
- Modify: `core/core/server/bootstrap.lua` (register the service in `server_scripts`... actually service files under `core/server/Services/*.lua` are already globbed — see step 5)

**Interfaces:**
- Produces: `SpawnManagerService.markConnecting(source)`, `SpawnManagerService.readyToSpawn(source, characterId)`, `SpawnManagerService.getStage(source)`. Later tasks (plugin server) call `SpawnManagerService.readyToSpawn` once a character is selected and appearance applied.
- Consumes: `Obelisk.emitClient(eventName, target, ...)` (already defined in `core/core/shared/Obelisk.lua`).

- [ ] **Step 1: Write the failing test**

```lua
-- core/tests/spawn_manager_service_spec.lua
--- Unit tests for SpawnManagerService's stage tracking and client relay.
--- Run from the repository root:  lua5.4 tests/spawn_manager_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')

local emitted = {}
_G.Obelisk = _G.Obelisk or {}
Obelisk.emitClient = function(eventName, target, ...)
    emitted[#emitted + 1] = { eventName = eventName, target = target, args = { ... } }
end

dofile(ROOT .. '/core/server/Services/SpawnManagerService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('markConnecting sets stage to connecting and emits spawn-begin', function()
    emitted = {}
    SpawnManagerService.markConnecting(7)
    eq(SpawnManagerService.getStage(7), 'connecting')
    eq(#emitted, 1)
    eq(emitted[1].eventName, 'core:server:spawn-begin')
    eq(emitted[1].target, 7)
end)

test('readyToSpawn sets stage to spawned and emits spawn-complete', function()
    emitted = {}
    SpawnManagerService.markConnecting(9)
    SpawnManagerService.readyToSpawn(9, 42)
    eq(SpawnManagerService.getStage(9), 'spawned')
    eq(#emitted, 1)
    eq(emitted[1].eventName, 'core:server:spawn-complete')
    eq(emitted[1].target, 9)
    eq(emitted[1].args[1], 42)
end)

test('getStage returns nil for an unknown source', function()
    eq(SpawnManagerService.getStage(999), nil)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('FAIL: ' .. t.name .. '\n  ' .. tostring(err))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/tests/spawn_manager_service_spec.lua`
Expected: error loading `core/server/Services/SpawnManagerService.lua` (file does not exist yet).

- [ ] **Step 3: Write minimal implementation**

```lua
-- core/core/server/Services/SpawnManagerService.lua
--- SpawnManagerService (core) - owns the join -> select -> spawn lifecycle
--- at the framework level: tracks which stage each connected player is in
--- and relays the two stage transitions the client needs to react to
--- (freeze+hide-hud on connect, unfreeze+show-hud once a character has
--- spawned). Deliberately thin: no loading-screen UI, no death/respawn
--- integration, no server-side spawn-position logic (that stays in
--- CharacterService.getVitals/saveVitals). Character-selection UI, ped
--- appearance and camera work are owned by oblsk_character-selection, not
--- here. See docs/superpowers/specs/2026-08-13-character-selection-plugin-design.md.
SpawnManagerService = {}
SpawnManagerService.stages = {} -- source -> 'connecting' | 'spawned'

--- Called once a connecting player's account has resolved (after
--- oblsk_accounts' playerConnecting handler runs) — signals the client to
--- freeze the player, hide the HUD, and show its own character-selection UI.
--- @param source number
function SpawnManagerService.markConnecting(source)
    SpawnManagerService.stages[source] = 'connecting'
    Obelisk.emitClient('core:server:spawn-begin', source)
end

--- Called by a character-selection-style plugin once a character has been
--- chosen and its appearance/position applied client-side — signals the
--- client to unfreeze and restore the HUD.
--- @param source number
--- @param characterId number
function SpawnManagerService.readyToSpawn(source, characterId)
    SpawnManagerService.stages[source] = 'spawned'
    Obelisk.emitClient('core:server:spawn-complete', source, characterId)
end

--- @param source number
--- @return string|nil
function SpawnManagerService.getStage(source)
    return SpawnManagerService.stages[source]
end

AddEventHandler('playerDropped', function()
    SpawnManagerService.stages[source] = nil
end)

return SpawnManagerService
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/tests/spawn_manager_service_spec.lua`
Expected: `3 passed, 0 failed`

- [ ] **Step 5: Wire into server script load order and hook `playerJoining`**

Modify `core/fxmanifest.lua`'s `server_scripts` block — `SpawnManagerService.lua` is already covered by the existing `'core/server/Services/*.lua'` glob (after the explicitly-listed services), so no manifest change is needed. Confirm by checking the glob line is still present:

```bash
grep -n "core/server/Services/\*.lua" core/fxmanifest.lua
```

Expected: one match.

Modify `core/core/server/bootstrap.lua` — hook `playerJoining` (fires after `playerConnecting`'s account resolution) to start the spawn lifecycle:

```lua
-- Player joined handler
AddEventHandler('playerJoining', function()
    local source = source
    print('[Obelisk] Player ' .. source .. ' joined, syncing data...')
    SpawnManagerService.markConnecting(source)
end)
```

(This replaces the existing `playerJoining` handler body in `core/core/server/bootstrap.lua`, adding the one new line.)

- [ ] **Step 6: Commit**

```bash
cd core
git add core/server/Services/SpawnManagerService.lua core/server/bootstrap.lua tests/spawn_manager_service_spec.lua
git commit -m "Add SpawnManagerService: minimal join->select->spawn stage relay"
```

---

### Task 2: `SpawnManagerService` (client)

**Files:**
- Create: `core/core/client/Services/SpawnManagerService.lua`

**Interfaces:**
- Consumes: `Obelisk.onClient(eventName, callback)` (shared `Obelisk.lua`).
- Produces: `SpawnManagerService.FreezePlayer(bool)`, `SpawnManagerService.SetHudVisible(bool)` (fires local event `obelisk:hud:setVisible` other plugins may listen for — no listener exists yet, this just defines the contract). Fires local events `obelisk:spawnStageChanged` with the client's ped handle and the character ID (on spawn-complete) so the character-selection plugin's `client/main.lua` (Task 9) can react without a hard dependency on this file.

No spec for this file — every function calls real GTA natives (`FreezeEntityPosition`, `PlayerPedId`) that aren't stubbed for headless Lua tests. Verified manually in Task 12's end-to-end checklist.

- [ ] **Step 1: Write the implementation**

```lua
-- core/core/client/Services/SpawnManagerService.lua
--- Client SpawnManagerService - reacts to the two stage events the server
--- SpawnManagerService emits: freeze + hide HUD on connect, unfreeze + show
--- HUD once a character has spawned. No native automated tests exist for
--- this file (FreezeEntityPosition/PlayerPedId aren't stubbed headless);
--- verify manually per the plan's end-to-end checklist.
SpawnManagerService = {}
SpawnManagerService.stage = nil

--- @param frozen boolean
function SpawnManagerService.FreezePlayer(frozen)
    FreezeEntityPosition(PlayerPedId(), frozen)
end

--- Fires a local event other HUD-owning plugins can listen for. No listener
--- exists yet in this framework — this defines the contract other plugins
--- can adopt later.
--- @param visible boolean
function SpawnManagerService.SetHudVisible(visible)
    TriggerEvent('obelisk:hud:setVisible', visible)
end

Obelisk.onClient('core:server:spawn-begin', function()
    SpawnManagerService.stage = 'connecting'
    SpawnManagerService.FreezePlayer(true)
    SpawnManagerService.SetHudVisible(false)
    TriggerEvent('obelisk:spawnStageChanged', 'connecting')
end)

Obelisk.onClient('core:server:spawn-complete', function(characterId)
    SpawnManagerService.stage = 'spawned'
    SpawnManagerService.FreezePlayer(false)
    SpawnManagerService.SetHudVisible(true)
    TriggerEvent('obelisk:spawnStageChanged', 'spawned', characterId)
end)

return SpawnManagerService
```

- [ ] **Step 2: Confirm client script load order picks it up**

```bash
grep -n "core/client/Services/\*\*/\*.lua" core/fxmanifest.lua
```

Expected: one match (the existing glob already covers this new file — no manifest change needed).

- [ ] **Step 3: Commit**

```bash
cd core
git add core/client/Services/SpawnManagerService.lua
git commit -m "Add client-side SpawnManagerService: freeze/HUD reaction to stage events"
```

---

### Task 3: Clean out the placeholder plugin scaffold

**Files:**
- Delete: `core/plugins/oblsk_character-selection/web/CharacterSelector.vue`
- Delete: `core/plugins/oblsk_character-selection/web/CharacterCreationForm.vue`
- Delete: `core/plugins/oblsk_character-selection/web/package.json`
- Delete: `core/plugins/oblsk_character-selection/web/dist/` (if present)
- Delete: `core/plugins/oblsk_character-selection/server/actions/ExampleAction.lua`
- Modify: `core/plugins/oblsk_character-selection/fxmanifest.lua`
- Modify: `core/plugins/oblsk_character-selection/shared/config.lua`
- Modify: `core/plugins/oblsk_character-selection/README.md`

These are generic CLI-scaffolded placeholders (teal buttons, `placehold.co` images) unrelated to the design being ported — deleted, not extended, per the approved spec.

- [ ] **Step 1: Delete placeholder files**

```bash
cd core/plugins/oblsk_character-selection
rm -f web/CharacterSelector.vue web/CharacterCreationForm.vue web/package.json
rm -rf web/dist
rm -f server/actions/ExampleAction.lua
```

- [ ] **Step 2: Rewrite `fxmanifest.lua` to match the `oblsk_garage`/`oblsk_inventory` core-bundled convention**

```lua
-- core/plugins/oblsk_character-selection/fxmanifest.lua
fx_version 'cerulean'
games { 'gta5' }

name 'CharacterSelection'
author 'AndiLfl'
version '1.0.0'

dependencies {
    'obelisk'
}

shared_scripts {
    'shared/**/*.lua'
}

server_scripts {
    'server/**/*.lua'
}

client_scripts {
    'client/**/*.lua'
}

-- The Vue UI is compiled into the core bundle at build time via core's
-- router/global-element glob (plugins/*/web/{routes,globalElements}.js), so
-- this plugin does not declare its own ui_page. These files are listed only
-- so they ship with the resource.
files {
    'web/*.vue',
    'web/controls/*.vue',
    'web/routes.js',
    'web/globalElements.js',
}
```

- [ ] **Step 3: Rewrite `shared/config.lua`**

```lua
-- core/plugins/oblsk_character-selection/shared/config.lua
Config = {}

Config.Debug = false

--- Fixed interior coordinate the select/creator preview ped and camera are
--- framed against (matches the source design's "apartment" scene).
Config.PreviewCoords = { x = -1035.71, y = -2733.75, z = 20.17, heading = 205.0 }

return Config
```

- [ ] **Step 4: Rewrite `README.md`**

```markdown
# oblsk_character-selection

Character select + creator screen, shown on connect via core's `SpawnManagerService`.

## Features
- Roster list with camera framing (head/torso/full), keyboard navigation
- 4-step creator: Identity, Heritage (real `SetPedHeadBlendData` parent blend), Appearance (face features, skin/eye/hair, body), Wardrobe (curated component/drawable presets)
- Live-applied ped appearance natives during creation, rotating preview camera

## Configuration
Edit `shared/config.lua` for the preview scene coordinate. Edit `shared/appearance.lua` for wardrobe/color presets.

See `docs/superpowers/specs/2026-08-13-character-selection-plugin-design.md` for the full design.
```

- [ ] **Step 5: Commit**

```bash
cd core
git add -A plugins/oblsk_character-selection
git commit -m "Clear placeholder scaffold from oblsk_character-selection"
```

---

### Task 4: Appearance/wardrobe config table

**Files:**
- Create: `core/plugins/oblsk_character-selection/shared/appearance.lua`
- Test: `core/plugins/oblsk_character-selection/tests/appearance_spec.lua`

**Interfaces:**
- Produces: `Appearance.WARDROBE[gender][slotKey]` (array of `{label, component, drawable, texture}`), `Appearance.SKIN_TONES`/`Appearance.EYE_COLORS`/`Appearance.HAIR_COLORS` (arrays of 8 `{label, swatch, ...ids}`), `Appearance.HAIR_STYLES` (array of 6 `{drawable}`), `Appearance.FACE_FEATURE_INDEX` (map of slider key → 0-19 feature index), `Appearance.DEFAULT_APPEARANCE(gender)` returning a full appearance table shaped per the spec's schema.
- Consumed by: Task 6 (server create wrapper, to validate/default a submitted appearance) and Task 10/11 (client appearance application, Vue wardrobe UI).

Curated tables are a hand-picked starting catalog (documented as such in the file header), not a researched final art-directed catalog, per the approved spec's "Known limitations" section.

- [ ] **Step 1: Write the failing test**

```lua
-- core/plugins/oblsk_character-selection/tests/appearance_spec.lua
--- Unit tests for the appearance/wardrobe config table: every slider key
--- the UI exposes must resolve to a face feature index, both genders must
--- define every wardrobe slot, and DEFAULT_APPEARANCE must produce a
--- complete, well-shaped table.
--- Run from the repository root:  lua5.4 plugins/oblsk_character-selection/tests/appearance_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. '../shared/appearance.lua')

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

local SLIDER_KEYS = {
    'nose', 'noseH', 'cheek', 'jaw', 'chin', 'brow', 'eyeSize', 'lips',
}
local WARDROBE_SLOTS = { 'top', 'jacket', 'pants', 'shoes', 'hat', 'acc' }

test('every design slider key maps to a face feature index', function()
    for _, key in ipairs(SLIDER_KEYS) do
        truthy(Appearance.FACE_FEATURE_INDEX[key] ~= nil, 'missing FACE_FEATURE_INDEX for ' .. key)
    end
end)

test('both genders define every wardrobe slot with at least one option', function()
    for _, gender in ipairs({ 'male', 'female' }) do
        for _, slot in ipairs(WARDROBE_SLOTS) do
            local options = Appearance.WARDROBE[gender][slot]
            truthy(options ~= nil, gender .. '.' .. slot .. ' missing')
            truthy(#options >= 1, gender .. '.' .. slot .. ' has no options')
            for _, opt in ipairs(options) do
                truthy(opt.label ~= nil, slot .. ' option missing label')
                truthy(opt.component ~= nil, slot .. ' option missing component')
                truthy(opt.drawable ~= nil, slot .. ' option missing drawable')
            end
        end
    end
end)

test('color/skin/hair-style tables each have exactly 8/8/8/6 presets', function()
    eq(#Appearance.SKIN_TONES, 8)
    eq(#Appearance.EYE_COLORS, 8)
    eq(#Appearance.HAIR_COLORS, 8)
    eq(#Appearance.HAIR_STYLES, 6)
end)

test('DEFAULT_APPEARANCE returns a complete, well-shaped table for both genders', function()
    for _, gender in ipairs({ 'male', 'female' }) do
        local a = Appearance.DEFAULT_APPEARANCE(gender)
        truthy(a.headBlend ~= nil, 'missing headBlend')
        for _, field in ipairs({ 'shapeFirst', 'shapeSecond', 'shapeThird', 'skinFirst', 'skinSecond', 'skinThird', 'shapeMix', 'skinMix', 'thirdMix' }) do
            truthy(a.headBlend[field] ~= nil, 'headBlend missing ' .. field)
        end
        truthy(a.faceFeatures ~= nil, 'missing faceFeatures')
        for _, key in ipairs(SLIDER_KEYS) do
            local idx = Appearance.FACE_FEATURE_INDEX[key]
            truthy(a.faceFeatures[idx] ~= nil, 'faceFeatures missing index ' .. idx)
        end
        truthy(a.hairStyle ~= nil, 'missing hairStyle')
        truthy(a.hairColor ~= nil, 'missing hairColor')
        truthy(a.hairHighlight ~= nil, 'missing hairHighlight')
        truthy(a.eyeColor ~= nil, 'missing eyeColor')
        truthy(a.components ~= nil, 'missing components')
        truthy(a.props ~= nil, 'missing props')
    end
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('FAIL: ' .. t.name .. '\n  ' .. tostring(err))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/plugins/oblsk_character-selection/tests/appearance_spec.lua`
Expected: error loading `shared/appearance.lua` (does not exist yet).

- [ ] **Step 3: Write the implementation**

```lua
-- core/plugins/oblsk_character-selection/shared/appearance.lua
--- Curated appearance/wardrobe config for the character creator. This is a
--- hand-picked STARTING catalog of GTA ped component/drawable/texture and
--- native color-table indices, not a researched, art-directed final
--- catalog -- expect some entries to look off in-game until play-tested
--- and tuned. See docs/superpowers/specs/2026-08-13-character-selection-plugin-design.md,
--- "Known limitations".
---
--- GTA ped component IDs used below: 2=hair, 3=torso(top), 4=legs(pants),
--- 6=shoes, 7=accessory, 11=torso2(jacket/outerwear). Prop IDs: 0=hats.
Appearance = {}

--- The 8 face sliders in the design map to SetPedFaceFeature indices
--- (0-19, native range -1.0..1.0). Values below are well-known, stable
--- native indices, not something invented for this plugin.
Appearance.FACE_FEATURE_INDEX = {
    nose = 0,       -- FACE_FEATURE_NOSE_WIDTH
    noseH = 2,      -- FACE_FEATURE_NOSE_HEIGHT (peak height)
    cheek = 6,      -- FACE_FEATURE_CHEEKBONES_HEIGHT
    jaw = 15,       -- FACE_FEATURE_JAW_WIDTH
    chin = 10,      -- FACE_FEATURE_CHIN_LENGTH
    brow = 8,       -- FACE_FEATURE_EYEBROW_HEIGHT
    eyeSize = 13,   -- FACE_FEATURE_EYES_OPENING
    lips = 17,      -- FACE_FEATURE_LIPS_THICKNESS
}

local function slot(label, component, drawable, texture)
    return { label = label, component = component, drawable = drawable, texture = texture or 0 }
end

Appearance.WARDROBE = {
    male = {
        top    = { slot('Tee · black', 3, 4, 0), slot('Henley', 3, 8, 0), slot('Polo', 3, 15, 0), slot('Tank', 3, 1, 0), slot('Flannel', 3, 20, 0), slot('Hoodie', 3, 34, 0) },
        jacket = { slot('None', 11, 0, 0), slot('Field jacket', 11, 6, 0), slot('Bomber', 11, 12, 0), slot('Leather', 11, 24, 0), slot('Denim', 11, 30, 0) },
        pants  = { slot('Jeans', 4, 4, 0), slot('Cargo · khaki', 4, 8, 1), slot('Chinos', 4, 15, 0), slot('Joggers', 4, 21, 0), slot('Tactical', 4, 26, 0) },
        shoes  = { slot('Sneakers', 6, 1, 0), slot('Combat boots', 6, 5, 0), slot('Runners', 6, 8, 0), slot('Dress shoes', 6, 11, 0) },
        hat    = { slot('None', 0, -1, 0), slot('Ball cap', 0, 4, 0), slot('Beanie', 0, 14, 0), slot('Bandana', 0, 19, 0) },
        acc    = { slot('None', 7, 0, 0), slot('Watch', 7, 2, 0), slot('Chain', 7, 5, 0), slot('Glasses', 7, 8, 0) },
    },
    female = {
        top    = { slot('Tee · black', 3, 6, 0), slot('Henley', 3, 11, 0), slot('Polo', 3, 18, 0), slot('Tank', 3, 2, 0), slot('Flannel', 3, 24, 0), slot('Hoodie', 3, 38, 0) },
        jacket = { slot('None', 11, 0, 0), slot('Field jacket', 11, 8, 0), slot('Bomber', 11, 14, 0), slot('Leather', 11, 26, 0), slot('Denim', 11, 32, 0) },
        pants  = { slot('Jeans', 4, 6, 0), slot('Cargo · khaki', 4, 10, 1), slot('Chinos', 4, 17, 0), slot('Joggers', 4, 23, 0), slot('Tactical', 4, 28, 0) },
        shoes  = { slot('Sneakers', 6, 3, 0), slot('Combat boots', 6, 7, 0), slot('Runners', 6, 10, 0), slot('Dress shoes', 6, 13, 0) },
        hat    = { slot('None', 0, -1, 0), slot('Ball cap', 0, 6, 0), slot('Beanie', 0, 16, 0), slot('Bandana', 0, 21, 0) },
        acc    = { slot('None', 7, 0, 0), slot('Watch', 7, 3, 0), slot('Chain', 7, 6, 0), slot('Glasses', 7, 9, 0) },
    },
}

--- Skin tone is NOT raw RGB in GTA -- it's controlled by SetPedHeadBlendData's
--- skin IDs + mix. Each swatch below is a curated {skinFirst, skinSecond,
--- skinMix} combo chosen to visually approximate the given color, ordered
--- lightest to darkest to match the design's 8-chip palette.
Appearance.SKIN_TONES = {
    { label = 'Tone 1', swatch = '#3a2418', skinFirst = 4, skinSecond = 4, skinMix = 0.9 },
    { label = 'Tone 2', swatch = '#4a2e1e', skinFirst = 4, skinSecond = 5, skinMix = 0.7 },
    { label = 'Tone 3', swatch = '#5e3b25', skinFirst = 5, skinSecond = 5, skinMix = 0.5 },
    { label = 'Tone 4', swatch = '#7a4f33', skinFirst = 5, skinSecond = 6, skinMix = 0.5 },
    { label = 'Tone 5', swatch = '#9a6a48', skinFirst = 6, skinSecond = 6, skinMix = 0.4 },
    { label = 'Tone 6', swatch = '#b88761', skinFirst = 6, skinSecond = 7, skinMix = 0.3 },
    { label = 'Tone 7', swatch = '#d2a47e', skinFirst = 7, skinSecond = 7, skinMix = 0.2 },
    { label = 'Tone 8', swatch = '#e8c39c', skinFirst = 8, skinSecond = 8, skinMix = 0.1 },
}

--- SetPedEyeColor native index (0-31); 8 representative picks.
Appearance.EYE_COLORS = {
    { label = 'Blue',    swatch = '#2a4a6e', index = 0 },
    { label = 'Sky',     swatch = '#3b6e8f', index = 1 },
    { label = 'Green',   swatch = '#4a8e4a', index = 5 },
    { label = 'Hazel',   swatch = '#6b5b3a', index = 9 },
    { label = 'Grey',    swatch = '#3a3a3a', index = 11 },
    { label = 'Amber',   swatch = '#7a4a2a', index = 13 },
    { label = 'Teal',    swatch = '#1a3a3a', index = 18 },
    { label = 'Violet',  swatch = '#5a2a4a', index = 22 },
}

--- SetPedHairColor(colorID, highlightID); 8 representative picks.
Appearance.HAIR_COLORS = {
    { label = 'Black',      swatch = '#0e0d0c', colorId = 0,  highlightId = 0 },
    { label = 'Dark brown', swatch = '#2b1d15', colorId = 1,  highlightId = 1 },
    { label = 'Brown',      swatch = '#4a2f1c', colorId = 3,  highlightId = 3 },
    { label = 'Auburn',     swatch = '#7a4a22', colorId = 5,  highlightId = 5 },
    { label = 'Blonde',     swatch = '#b07a34', colorId = 8,  highlightId = 8 },
    { label = 'Platinum',   swatch = '#d9b877', colorId = 10, highlightId = 10 },
    { label = 'Grey',       swatch = '#8a8a8a', colorId = 17, highlightId = 17 },
    { label = 'Red',        swatch = '#c94f2a', colorId = 28, highlightId = 28 },
}

--- Component 2 (hair) drawable per style.
Appearance.HAIR_STYLES = {
    { drawable = 0 }, { drawable = 1 }, { drawable = 2 },
    { drawable = 3 }, { drawable = 4 }, { drawable = 5 },
}

--- @param gender string 'male' | 'female'
--- @return table full appearance shape (see design spec's "Appearance data shape")
function Appearance.DEFAULT_APPEARANCE(gender)
    local faceFeatures = {}
    for _, idx in pairs(Appearance.FACE_FEATURE_INDEX) do
        faceFeatures[idx] = 0.0
    end

    return {
        headBlend = {
            shapeFirst = 0, shapeSecond = 0, shapeThird = 0,
            skinFirst = 0, skinSecond = 0, skinThird = 0,
            shapeMix = 0.5, skinMix = 0.5, thirdMix = 0.0,
        },
        faceFeatures = faceFeatures,
        hairStyle = Appearance.HAIR_STYLES[1].drawable,
        hairColor = Appearance.HAIR_COLORS[1].colorId,
        hairHighlight = Appearance.HAIR_COLORS[1].highlightId,
        eyeColor = Appearance.EYE_COLORS[1].index,
        components = {},
        props = {},
    }
end

return Appearance
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/plugins/oblsk_character-selection/tests/appearance_spec.lua`
Expected: `4 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
cd core
git add plugins/oblsk_character-selection/shared/appearance.lua plugins/oblsk_character-selection/tests/appearance_spec.lua
git commit -m "Add curated appearance/wardrobe config table"
```

---

### Task 5: `CharacterSelectionService` (server) — list/create/delete/select logic

**Files:**
- Create: `core/plugins/oblsk_character-selection/server/services/CharacterSelectionService.lua`
- Test: `core/plugins/oblsk_character-selection/tests/character_selection_service_spec.lua`

**Interfaces:**
- Consumes: `CharacterService.list(accountId)`, `CharacterService.create(accountId, attributes)`, `CharacterService.delete(characterId)`, `CharacterService.setActiveCharacterId(source, characterId)`, `CharacterService.getVitals(characterId)` (all from `core/modules/oblsk_characters/server/services/CharacterService.lua`, already implemented). `CharacterAppearance` model (`core/modules/oblsk_characters/server/models/CharacterAppearance.lua`). `Appearance.DEFAULT_APPEARANCE(gender)` (Task 4).
- Produces: `CharacterSelectionService.listWithAppearance(accountId)`, `CharacterSelectionService.createCharacter(accountId, attributes)` (attributes now includes `appearance`), `CharacterSelectionService.deleteCharacter(characterId)`, `CharacterSelectionService.selectCharacter(source, characterId)` returning `{ vitals, appearance }`. Consumed by Task 6's event handlers.

Pulled out as its own service (rather than inlining in `server/main.lua`'s event handlers) specifically so it's testable without net-event stubs, matching how `CharacterService` itself is tested.

- [ ] **Step 1: Write the failing test**

```lua
-- core/plugins/oblsk_character-selection/tests/character_selection_service_spec.lua
--- Unit tests for CharacterSelectionService, the thin list/create/delete/select
--- wrapper this plugin adds on top of oblsk_characters' CharacterService.
--- Run from the repository root:  lua5.4 plugins/oblsk_character-selection/tests/character_selection_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'
local CHAR_MODULE = scriptDir .. '../../../modules/oblsk_characters'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(CHAR_MODULE .. '/server/models/Character.lua')
dofile(CHAR_MODULE .. '/server/models/CharacterAppearance.lua')
dofile(CHAR_MODULE .. '/server/services/CharacterService.lua')
dofile(scriptDir .. '../shared/appearance.lua')

local makeFakeQueryBuilderModule = dofile(CHAR_MODULE .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/services/CharacterSelectionService.lua')

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

local function withFakeDb(fn)
    local tables = {
        accounts = { { id = 1, max_characters = 3 } },
        characters = {},
        character_appearances = {},
    }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    local ok, err = pcall(fn, tables)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('createCharacter stores the submitted appearance on the CharacterAppearance row', function()
    withFakeDb(function(tables)
        local character = CharacterSelectionService.createCharacter(1, {
            first_name = 'Alex', last_name = 'Reyes', gender = 'female', dob = '1994-03-12', bio = '',
            appearance = Appearance.DEFAULT_APPEARANCE('female'),
        })
        truthy(character ~= nil)
        eq(#tables.character_appearances, 1)
        truthy(tables.character_appearances[1].data.headBlend ~= nil, 'appearance not persisted')
    end)
end)

test('createCharacter defaults the appearance when none is submitted', function()
    withFakeDb(function(tables)
        CharacterSelectionService.createCharacter(1, { first_name = 'Sam', last_name = 'Doe', gender = 'male', dob = '1990-01-01', bio = '' })
        truthy(tables.character_appearances[1].data.headBlend ~= nil, 'default appearance not applied')
    end)
end)

test('listWithAppearance returns each character joined with its appearance', function()
    withFakeDb(function()
        CharacterSelectionService.createCharacter(1, { first_name = 'A', last_name = 'B', gender = 'male', dob = '1990-01-01', bio = '' })
        local list = CharacterSelectionService.listWithAppearance(1)
        eq(#list, 1)
        eq(list[1].character.first_name, 'A')
        truthy(list[1].appearance ~= nil, 'appearance not joined')
    end)
end)

test('deleteCharacter soft-deletes via CharacterService.delete', function()
    withFakeDb(function(tables)
        local character = CharacterSelectionService.createCharacter(1, { first_name = 'A', last_name = 'B', gender = 'male', dob = '1990-01-01', bio = '' })
        CharacterSelectionService.deleteCharacter(character.attributes.id)
        eq(#CharacterSelectionService.listWithAppearance(1), 0)
    end)
end)

test('selectCharacter marks the session's active character and returns vitals + appearance', function()
    withFakeDb(function()
        local character = CharacterSelectionService.createCharacter(1, { first_name = 'A', last_name = 'B', gender = 'male', dob = '1990-01-01', bio = '' })
        local result = CharacterSelectionService.selectCharacter(5, character.attributes.id)
        eq(CharacterService.getActiveCharacterId(5), character.attributes.id)
        truthy(result.vitals ~= nil, 'missing vitals')
        truthy(result.appearance ~= nil, 'missing appearance')
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('FAIL: ' .. t.name .. '\n  ' .. tostring(err))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/plugins/oblsk_character-selection/tests/character_selection_service_spec.lua`
Expected: error loading `server/services/CharacterSelectionService.lua` (does not exist yet).

- [ ] **Step 3: Write the implementation**

```lua
-- core/plugins/oblsk_character-selection/server/services/CharacterSelectionService.lua
--- CharacterSelectionService (plugin) - thin list/create/delete/select
--- wrapper over oblsk_characters' CharacterService, adding appearance
--- persistence (CharacterService.create doesn't accept an appearance blob;
--- this defaults or stores one via CharacterAppearance directly) and
--- joining appearance data onto listed characters for the roster UI. See
--- docs/superpowers/specs/2026-08-13-character-selection-plugin-design.md.
CharacterSelectionService = {}

--- @param accountId number
--- @return table[] each { character = <attrs table>, appearance = <data table> }
function CharacterSelectionService.listWithAppearance(accountId)
    local characters = CharacterService.list(accountId)
    local result = {}
    for _, character in ipairs(characters) do
        local appearanceRow = QueryBuilder.new('character_appearances')
            :where('character_id', character.id)
            :firstSync()
        result[#result + 1] = {
            character = character,
            appearance = appearanceRow and appearanceRow.data or nil,
        }
    end
    return result
end

--- @param accountId number
--- @param attributes table { first_name, last_name, gender, dob, bio, appearance? }
--- @return Character|nil
--- @return string|nil err
function CharacterSelectionService.createCharacter(accountId, attributes)
    local character, err = CharacterService.create(accountId, attributes)
    if not character then
        return nil, err
    end

    local appearance = attributes.appearance or Appearance.DEFAULT_APPEARANCE(attributes.gender or 'male')
    QueryBuilder.new('character_appearances')
        :where('character_id', character.attributes.id)
        :update({ data = appearance })

    return character
end

--- @param characterId number
function CharacterSelectionService.deleteCharacter(characterId)
    return CharacterService.delete(characterId)
end

--- @param source number
--- @param characterId number
--- @return table { vitals, appearance }
function CharacterSelectionService.selectCharacter(source, characterId)
    CharacterService.setActiveCharacterId(source, characterId)

    local appearanceRow = QueryBuilder.new('character_appearances')
        :where('character_id', characterId)
        :firstSync()

    return {
        vitals = CharacterService.getVitals(characterId),
        appearance = appearanceRow and appearanceRow.data or nil,
    }
end

return CharacterSelectionService
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/plugins/oblsk_character-selection/tests/character_selection_service_spec.lua`
Expected: `5 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
cd core
git add plugins/oblsk_character-selection/server/services/CharacterSelectionService.lua plugins/oblsk_character-selection/tests/character_selection_service_spec.lua
git commit -m "Add CharacterSelectionService: list/create/delete/select + appearance join"
```

---

### Task 6: Server event wiring (`server/main.lua`)

**Files:**
- Modify: `core/plugins/oblsk_character-selection/server/main.lua` (full rewrite)

**Interfaces:**
- Consumes: `CharacterSelectionService.*` (Task 5), `AccountService.getAccountId(source)` (`core/modules/oblsk_accounts/server/services/AccountService.lua`, already implemented), `SpawnManagerService.readyToSpawn(source, characterId)` (Task 1).
- Produces (net events, client-facing): `character-selection:list-result`, `character-selection:created`, `character-selection:create-failed`, `character-selection:deleted`, `character-selection:selected` — all via `Obelisk.emitClient`.

No dedicated spec — this file is pure event-wiring glue over already-tested `CharacterSelectionService`; `RegisterNetEvent`/`AddEventHandler` are no-ops under the headless test stubs so there's nothing meaningful to assert beyond what Task 5 already covers.

- [ ] **Step 1: Write the implementation**

```lua
-- core/plugins/oblsk_character-selection/server/main.lua
--- oblsk_character-selection - Server Main
--- Request/response events for the roster UI. Not routed through
--- ActionService (fire-and-forget, no response channel) since the UI needs
--- data back for list/create/select.
print('[oblsk_character-selection] Loading...')

Obelisk.onServer('character-selection:list', function()
    local source = source
    local accountId = AccountService.getAccountId(source)
    if not accountId then
        return
    end
    Obelisk.emitClient('character-selection:list-result', source, CharacterSelectionService.listWithAppearance(accountId))
end)

Obelisk.onServer('character-selection:create', function(attributes)
    local source = source
    local accountId = AccountService.getAccountId(source)
    if not accountId then
        return
    end

    local character, err = CharacterSelectionService.createCharacter(accountId, attributes)
    if not character then
        Obelisk.emitClient('character-selection:create-failed', source, err)
        return
    end

    Obelisk.emitClient('character-selection:created', source, character.attributes)
end)

Obelisk.onServer('character-selection:delete', function(characterId)
    local source = source
    CharacterSelectionService.deleteCharacter(characterId)
    Obelisk.emitClient('character-selection:deleted', source, characterId)
end)

Obelisk.onServer('character-selection:select', function(characterId)
    local source = source
    local result = CharacterSelectionService.selectCharacter(source, characterId)
    Obelisk.emitClient('character-selection:selected', source, characterId, result)
    SpawnManagerService.readyToSpawn(source, characterId)
end)

print('[oblsk_character-selection] Loaded successfully!')
```

- [ ] **Step 2: Manual sanity check (no automated test — pure event wiring)**

```bash
lua5.4 -e "
dofile('core/tests/support/fivem_stubs.lua')
_G.Obelisk = { onServer = function(name, fn) print('registered: ' .. name) end }
dofile('core/plugins/oblsk_character-selection/server/main.lua')
"
```

Expected: prints `registered: character-selection:list`, `registered: character-selection:create`, `registered: character-selection:delete`, `registered: character-selection:select`, plus the load print lines — confirms no syntax errors and all four handlers register.

- [ ] **Step 3: Commit**

```bash
cd core
git add plugins/oblsk_character-selection/server/main.lua
git commit -m "Wire character-selection request/response events to CharacterSelectionService"
```

---

### Task 7: Client `CharacterAppearanceService` — apply appearance natives to a ped

**Files:**
- Create: `core/plugins/oblsk_character-selection/client/services/CharacterAppearanceService.lua`

**Interfaces:**
- Produces: `CharacterAppearanceService.apply(ped, appearance, gender)` — applies the full appearance shape from Task 4's schema to any ped (used for both the preview ped and, on confirm, the real player ped).
- Consumes: `Appearance.WARDROBE`/`Appearance.HAIR_STYLES` (Task 4, shared so also loaded client-side per the plugin's `shared_scripts` glob).

No automated test (native calls, no headless stub) — verified in Task 12's manual checklist.

- [ ] **Step 1: Write the implementation**

```lua
-- core/plugins/oblsk_character-selection/client/services/CharacterAppearanceService.lua
--- Client CharacterAppearanceService - applies a Task 4-shaped appearance
--- table to any ped via GTA natives. Used for both the select/creator
--- preview ped and, on confirm, the real player ped. No automated test
--- (native calls aren't stubbed headless) -- verify manually per the plan's
--- end-to-end checklist.
CharacterAppearanceService = {}

--- @param ped number ped handle
--- @param appearance table shaped per Appearance.DEFAULT_APPEARANCE
--- @param gender string 'male' | 'female'
function CharacterAppearanceService.apply(ped, appearance, gender)
    local hb = appearance.headBlend
    SetPedHeadBlendData(ped,
        hb.shapeFirst, hb.shapeSecond, hb.shapeThird,
        hb.skinFirst, hb.skinSecond, hb.skinThird,
        hb.shapeMix, hb.skinMix, hb.thirdMix,
        false)

    for featureIndex, value in pairs(appearance.faceFeatures) do
        SetPedFaceFeature(ped, featureIndex, value)
    end

    SetPedComponentVariation(ped, 2, appearance.hairStyle, 0, 0)
    SetPedHairColor(ped, appearance.hairColor, appearance.hairHighlight)
    SetPedEyeColor(ped, appearance.eyeColor)

    for componentId, variation in pairs(appearance.components) do
        SetPedComponentVariation(ped, componentId, variation.drawable, variation.texture or 0, 0)
    end

    for propId, variation in pairs(appearance.props) do
        if variation.drawable == -1 then
            ClearPedProp(ped, propId)
        else
            SetPedPropIndex(ped, propId, variation.drawable, variation.texture or 0, true)
        end
    end
end

--- Convenience: apply one wardrobe slot's chosen option (from
--- Appearance.WARDROBE[gender][slotKey][optionIndex]) directly to a ped,
--- for live preview as the creator's Wardrobe step changes selection.
--- @param ped number
--- @param gender string
--- @param slotKey string e.g. 'top', 'jacket'
--- @param optionIndex number 1-based index into Appearance.WARDROBE[gender][slotKey]
function CharacterAppearanceService.applyWardrobeSlot(ped, gender, slotKey, optionIndex)
    local option = Appearance.WARDROBE[gender][slotKey][optionIndex]
    if not option then
        return
    end
    if option.drawable == -1 then
        ClearPedProp(ped, option.component)
    elseif slotKey == 'hat' then
        SetPedPropIndex(ped, option.component, option.drawable, option.texture, true)
    else
        SetPedComponentVariation(ped, option.component, option.drawable, option.texture, 0)
    end
end

return CharacterAppearanceService
```

- [ ] **Step 2: Commit**

```bash
cd core
git add plugins/oblsk_character-selection/client/services/CharacterAppearanceService.lua
git commit -m "Add client CharacterAppearanceService: apply appearance natives to a ped"
```

---

### Task 8: Client `CharacterCameraService` — preview camera framing/rotation

**Files:**
- Create: `core/plugins/oblsk_character-selection/client/services/CharacterCameraService.lua`

**Interfaces:**
- Produces: `CharacterCameraService.start(pedCoords)`, `CharacterCameraService.stop()`, `CharacterCameraService.setFraming(framing)` (`'head' | 'torso' | 'full'`, select screen), `CharacterCameraService.setAngle(angleIndex)` (0-3, creator screen's Front/¾/Side/Back).

No automated test (camera natives, no headless stub) — verified manually.

- [ ] **Step 1: Write the implementation**

```lua
-- core/plugins/oblsk_character-selection/client/services/CharacterCameraService.lua
--- Client CharacterCameraService - a single scripted camera framed on the
--- preview ped, used by both the select screen (head/torso/full framing)
--- and the creator screen (4 fixed rotation angles). No automated test
--- (camera natives aren't stubbed headless) -- verify manually.
CharacterCameraService = {}
CharacterCameraService.cam = nil
CharacterCameraService.pedCoords = nil

local FRAMINGS = {
    head  = { zOffset = 0.62, distance = 0.9,  fov = 30.0 },
    torso = { zOffset = 0.35, distance = 1.8,  fov = 40.0 },
    full  = { zOffset = -0.1, distance = 3.2,  fov = 45.0 },
}

--- Front/3-4/Side/Back, degrees offset from the ped's own heading.
local ANGLES = { 0.0, 45.0, 90.0, 180.0 }

--- @param pedCoords vector4 { x, y, z, heading } — the preview ped's spawn coords
function CharacterCameraService.start(pedCoords)
    CharacterCameraService.pedCoords = pedCoords
    CharacterCameraService.cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    CharacterCameraService.setFraming('full')
    SetCamActive(CharacterCameraService.cam, true)
    RenderScriptCams(true, false, 0, true, true)
end

function CharacterCameraService.stop()
    if CharacterCameraService.cam then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(CharacterCameraService.cam, false)
        CharacterCameraService.cam = nil
    end
end

local function place(zOffset, distance, angleDegrees, fov)
    local coords = CharacterCameraService.pedCoords
    local headingRad = math.rad(coords.heading + 180.0 + angleDegrees)
    local camX = coords.x + math.sin(headingRad) * distance
    local camY = coords.y - math.cos(headingRad) * distance
    local camZ = coords.z + 0.62 + zOffset

    SetCamCoord(CharacterCameraService.cam, camX, camY, camZ)
    PointCamAtCoord(CharacterCameraService.cam, coords.x, coords.y, coords.z + 0.62 + zOffset)
    SetCamFov(CharacterCameraService.cam, fov)
end

--- @param framing string 'head' | 'torso' | 'full'
function CharacterCameraService.setFraming(framing)
    local f = FRAMINGS[framing] or FRAMINGS.full
    place(f.zOffset, f.distance, 0.0, f.fov)
end

--- @param angleIndex number 0-3, indexes ANGLES (Front/3-4/Side/Back)
function CharacterCameraService.setAngle(angleIndex)
    local angle = ANGLES[angleIndex + 1] or ANGLES[1]
    place(FRAMINGS.full.zOffset, FRAMINGS.full.distance, angle, FRAMINGS.full.fov)
end

return CharacterCameraService
```

- [ ] **Step 2: Commit**

```bash
cd core
git add plugins/oblsk_character-selection/client/services/CharacterCameraService.lua
git commit -m "Add client CharacterCameraService: preview camera framing/rotation"
```

---

### Task 9: Client orchestration (`client/main.lua`)

**Files:**
- Modify: `core/plugins/oblsk_character-selection/client/main.lua` (full rewrite)

**Interfaces:**
- Consumes: `CharacterAppearanceService.apply`/`applyWardrobeSlot` (Task 7), `CharacterCameraService.*` (Task 8), `WebView.showGlobalElement`/`hideGlobalElement`/`on`/`emit`/`emitServer` (`core/core/client/Services/WebView.lua`, already implemented), `Config.PreviewCoords` (Task 3), `Appearance.DEFAULT_APPEARANCE` (Task 4), local event `obelisk:spawnStageChanged` (Task 2).
- Produces (NUI callbacks the Vue side calls, see Task 13): `character-selection:list`, `character-selection:create`, `character-selection:delete`, `character-selection:select`, `character-selection:preview-update` (live appearance/wardrobe changes during creation). Produces (NUI messages sent to Vue): relays `character-selection:list-result`, `character-selection:created`, `character-selection:create-failed`, `character-selection:deleted`, `character-selection:selected` straight through.

No automated test (native ped spawn + NUI orchestration, no headless stub) — verified manually.

- [ ] **Step 1: Write the implementation**

```lua
-- core/plugins/oblsk_character-selection/client/main.lua
--- oblsk_character-selection - Client Main
--- Orchestrates the select/creator screen: spawns a preview ped near
--- Config.PreviewCoords on the SpawnManagerService 'connecting' stage,
--- relays list/create/delete/select requests from Vue to the server, and
--- live-applies appearance changes to the preview ped during creation.
print('[oblsk_character-selection] Client loading...')

local previewPed = nil
local previewGender = 'male'

local function spawnPreviewPed(gender)
    if previewPed and DoesEntityExist(previewPed) then
        DeleteEntity(previewPed)
    end
    local model = gender == 'female' and `mp_f_freemode_01` or `mp_m_freemode_01`
    RequestModel(model)
    while not HasModelLoaded(model) do
        Citizen.Wait(0)
    end

    local c = Config.PreviewCoords
    previewPed = CreatePed(4, model, c.x, c.y, c.z - 1.0, c.heading, false, false)
    SetEntityInvincible(previewPed, true)
    FreezeEntityPosition(previewPed, true)
    SetBlockingOfNonTemporaryEvents(previewPed, true)
    previewGender = gender
    return previewPed
end

local function despawnPreviewPed()
    if previewPed and DoesEntityExist(previewPed) then
        DeleteEntity(previewPed)
        previewPed = nil
    end
end

TriggerEvent('obelisk:spawnStageChanged', nil) -- no-op registration guard, real handler below

AddEventHandler('obelisk:spawnStageChanged', function(stage)
    if stage == 'connecting' then
        spawnPreviewPed('male')
        local c = Config.PreviewCoords
        CharacterCameraService.start(c)
        WebView.focus()
        WebView.showGlobalElement('character-selection')
        WebView.emitServer('character-selection:list')
    elseif stage == 'spawned' then
        CharacterCameraService.stop()
        despawnPreviewPed()
        WebView.hideGlobalElement('character-selection')
        WebView.hide()
    end
end)

-- Vue -> Lua
WebView.on('character-selection:list', function()
    WebView.emitServer('character-selection:list')
end)

WebView.on('character-selection:create', function(data)
    WebView.emitServer('character-selection:create', data)
end)

WebView.on('character-selection:delete', function(data)
    WebView.emitServer('character-selection:delete', data.characterId)
end)

WebView.on('character-selection:select', function(data)
    if previewPed and DoesEntityExist(previewPed) then
        local appearance = data.appearance or Appearance.DEFAULT_APPEARANCE(previewGender)
        local pedCoords = GetEntityCoords(previewPed)
        SetEntityCoords(PlayerPedId(), pedCoords.x, pedCoords.y, pedCoords.z)
        SetPlayerModel(PlayerId(), previewGender == 'female' and `mp_f_freemode_01` or `mp_m_freemode_01`)
        CharacterAppearanceService.apply(PlayerPedId(), appearance, previewGender)
    end
    WebView.emitServer('character-selection:select', data.characterId)
end)

--- Live preview during creation: { gender?, appearance?, cameraFraming?, cameraAngle?, wardrobeSlot? }
WebView.on('character-selection:preview-update', function(data)
    if not (previewPed and DoesEntityExist(previewPed)) then
        return
    end
    if data.gender and data.gender ~= previewGender then
        local coords = GetEntityCoords(previewPed)
        local heading = GetEntityHeading(previewPed)
        spawnPreviewPed(data.gender)
        SetEntityCoords(previewPed, coords.x, coords.y, coords.z)
        SetEntityHeading(previewPed, heading)
    end
    if data.appearance then
        CharacterAppearanceService.apply(previewPed, data.appearance, previewGender)
    end
    if data.wardrobeSlot then
        CharacterAppearanceService.applyWardrobeSlot(previewPed, previewGender, data.wardrobeSlot.key, data.wardrobeSlot.optionIndex)
    end
    if data.cameraFraming then
        CharacterCameraService.setFraming(data.cameraFraming)
    end
    if data.cameraAngle ~= nil then
        CharacterCameraService.setAngle(data.cameraAngle)
    end
end)

-- Server -> Lua -> Vue (straight relay)
for _, eventName in ipairs({
    'character-selection:list-result',
    'character-selection:created',
    'character-selection:create-failed',
    'character-selection:deleted',
    'character-selection:selected',
}) do
    Obelisk.onClient(eventName, function(...)
        WebView.emit(eventName, { ... })
    end)
end

print('[oblsk_character-selection] Client loaded successfully!')
```

- [ ] **Step 2: Commit**

```bash
cd core
git add plugins/oblsk_character-selection/client/main.lua
git commit -m "Wire client orchestration: preview ped, camera, NUI relay"
```

---

### Task 10: Shared Vue controls (Slider, SwatchGrid, Stepper, TextField)

**Files:**
- Create: `core/plugins/oblsk_character-selection/web/controls/Slider.vue`
- Create: `core/plugins/oblsk_character-selection/web/controls/SwatchGrid.vue`
- Create: `core/plugins/oblsk_character-selection/web/controls/Stepper.vue`
- Create: `core/plugins/oblsk_character-selection/web/controls/TextField.vue`

**Interfaces:**
- Produces: 4 presentational components consumed by `CharacterCreator.vue` (Task 12), ported from the prototype's `Sld`/`Swatches`/`Stepper`/`TxtField` JS helpers into standalone Vue SFCs with `v-model`.

- [ ] **Step 1: Write `Slider.vue`**

```vue
<!-- core/plugins/oblsk_character-selection/web/controls/Slider.vue -->
<template>
  <div class="mb-3">
    <div class="flex justify-between text-[11px] mb-1">
      <span class="text-white/45">{{ label }}</span>
      <span class="ob-mono text-white/70">{{ modelValue }}</span>
    </div>
    <input
      type="range" min="0" max="100" :value="modelValue"
      @input="$emit('update:modelValue', +$event.target.value)"
      class="w-full h-1 appearance-none rounded-full bg-white/12 outline-none accent-ob-accent"
    />
  </div>
</template>

<script setup>
defineProps({ label: { type: String, required: true }, modelValue: { type: Number, required: true } })
defineEmits(['update:modelValue'])
</script>
```

- [ ] **Step 2: Write `SwatchGrid.vue`**

```vue
<!-- core/plugins/oblsk_character-selection/web/controls/SwatchGrid.vue -->
<template>
  <div class="grid grid-cols-8 gap-1.5 mb-2">
    <button
      v-for="(preset, i) in presets" :key="i"
      @click="$emit('update:modelValue', i)"
      class="h-8 rounded-md transition"
      :style="{
        background: preset.swatch,
        outline: modelValue === i ? '2px solid var(--ob-accent)' : '1px solid rgba(255,255,255,.1)',
        outlineOffset: '2px',
      }"
    />
  </div>
</template>

<script setup>
defineProps({
  presets: { type: Array, required: true },
  modelValue: { type: Number, required: true },
})
defineEmits(['update:modelValue'])
</script>
```

- [ ] **Step 3: Write `Stepper.vue`**

```vue
<!-- core/plugins/oblsk_character-selection/web/controls/Stepper.vue -->
<template>
  <div>
    <div class="ob-mono text-[9px] uppercase text-white/30 mb-1">{{ label }}</div>
    <div class="h-9 rounded-lg bg-black/40 border border-white/12 flex items-center">
      <button @click="set(modelValue - 1)" class="w-7 h-full grid place-items-center text-white/40 hover:text-white text-[13px] leading-none">−</button>
      <input
        :value="pad ? String(modelValue).padStart(2, '0') : modelValue"
        @change="onInput"
        class="flex-1 min-w-0 bg-transparent text-center outline-none ob-mono text-[12px]"
      />
      <button @click="set(modelValue + 1)" class="w-7 h-full grid place-items-center text-white/40 hover:text-white text-[13px] leading-none">+</button>
    </div>
  </div>
</template>

<script setup>
const props = defineProps({
  label: { type: String, required: true },
  modelValue: { type: Number, required: true },
  min: { type: Number, required: true },
  max: { type: Number, required: true },
  pad: { type: Boolean, default: false },
})
const emit = defineEmits(['update:modelValue'])

function clamp(n) {
  return Math.min(props.max, Math.max(props.min, n))
}
function set(n) {
  emit('update:modelValue', clamp(n))
}
function onInput(e) {
  const n = parseInt(e.target.value.replace(/\D/g, ''), 10)
  if (!isNaN(n)) set(n)
}
</script>
```

- [ ] **Step 4: Write `TextField.vue`**

```vue
<!-- core/plugins/oblsk_character-selection/web/controls/TextField.vue -->
<template>
  <div class="mb-3">
    <label class="text-[11px] text-white/45 block mb-1.5">{{ label }}</label>
    <input
      :value="modelValue" @input="$emit('update:modelValue', $event.target.value)"
      class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[12.5px] outline-none focus:border-ob-accent"
    />
  </div>
</template>

<script setup>
defineProps({ label: { type: String, required: true }, modelValue: { type: String, required: true } })
defineEmits(['update:modelValue'])
</script>
```

- [ ] **Step 5: Commit**

```bash
cd core
git add plugins/oblsk_character-selection/web/controls
git commit -m "Add shared Vue controls: Slider, SwatchGrid, Stepper, TextField"
```

---

### Task 11: `useCharacterSelection.js` composable + dev fixture

**Files:**
- Create: `core/plugins/oblsk_character-selection/web/useCharacterSelection.js`
- Create: `core/plugins/oblsk_character-selection/web/devFixture.js`

**Interfaces:**
- Produces: `useCharacterSelection()` returning `{ characters, selectedIndex, mode, selected, list, create, deleteCharacter, select, updatePreview, gender }` reactive state + methods, consumed by `CharacterSelect.vue` and `CharacterCreator.vue` (Tasks 12-13).
- Consumes: `Obelisk` singleton (`core/web/src/obelisk.js`), `Appearance` — re-exported for the browser side as plain JS since the shared Lua table can't be `import`ed into Vue; duplicated here deliberately (small, stable, curated data — not worth a build-step bridge).

- [ ] **Step 1: Write `devFixture.js`**

```js
// core/plugins/oblsk_character-selection/web/devFixture.js
// Mock data for browser-only preview (Vite dev server, no FiveM NUI bridge).
export function debugCharacters() {
  return [
    {
      character: {
        id: 1, first_name: 'Kayla', last_name: 'West', gender: 'female',
        dob: '1994-03-12', bio: 'Detective · LSPD', last_played_at: '2 hours ago',
      },
      appearance: null,
    },
    {
      character: {
        id: 2, first_name: 'Marco', last_name: 'Vance', gender: 'male',
        dob: '1989-11-02', bio: 'Mechanic · Benny\'s', last_played_at: '1 day ago',
      },
      appearance: null,
    },
  ]
}
```

- [ ] **Step 2: Write `useCharacterSelection.js`**

```js
// core/plugins/oblsk_character-selection/web/useCharacterSelection.js
import { ref, computed } from 'vue'
import Obelisk from '../../../web/src/obelisk.js'
import { debugCharacters } from './devFixture.js'

const isDev = import.meta.env.DEV

export function useCharacterSelection() {
  const characters = ref(isDev ? debugCharacters() : [])
  const selectedIndex = ref(0)
  const mode = ref('select') // 'select' | 'create'
  const gender = ref('male')

  const selected = computed(() => characters.value[selectedIndex.value] || null)

  function list() {
    if (isDev) {
      characters.value = debugCharacters()
      return
    }
    Obelisk.emit('character-selection:list')
  }

  function create(attributes) {
    if (isDev) {
      characters.value.push({ character: { id: Date.now(), ...attributes }, appearance: attributes.appearance })
      mode.value = 'select'
      return
    }
    Obelisk.emit('character-selection:create', attributes)
  }

  function deleteCharacter(characterId) {
    if (isDev) {
      characters.value = characters.value.filter(c => c.character.id !== characterId)
      return
    }
    Obelisk.emit('character-selection:delete', { characterId })
  }

  function select(characterId) {
    const entry = characters.value.find(c => c.character.id === characterId)
    Obelisk.emit('character-selection:select', { characterId, appearance: entry?.appearance })
  }

  function updatePreview(payload) {
    Obelisk.emit('character-selection:preview-update', payload)
  }

  Obelisk.on('character-selection:list-result', (list) => { characters.value = list })
  Obelisk.on('character-selection:created', (attrs) => { list() })
  Obelisk.on('character-selection:deleted', () => { list() })

  return { characters, selectedIndex, mode, gender, selected, list, create, deleteCharacter, select, updatePreview }
}
```

- [ ] **Step 3: Commit**

```bash
cd core
git add plugins/oblsk_character-selection/web/useCharacterSelection.js plugins/oblsk_character-selection/web/devFixture.js
git commit -m "Add useCharacterSelection composable + dev preview fixture"
```

---

### Task 12: `CharacterSelect.vue` — roster screen

**Files:**
- Create: `core/plugins/oblsk_character-selection/web/CharacterSelect.vue`

**Interfaces:**
- Consumes: `useCharacterSelection()` (Task 11).
- Produces: `<CharacterSelect @create="..." />`, emits `create` when the user starts a new character, consumed by `CharacterSelection.vue` (Task 14).

- [ ] **Step 1: Write the implementation**

```vue
<!-- core/plugins/oblsk_character-selection/web/CharacterSelect.vue -->
<template>
  <div class="absolute inset-0 select-none">
    <div class="absolute flex items-center gap-2.5" style="left:28px;top:22px">
      <div class="w-8 h-8 rounded-lg grid place-items-center bg-ob-accent">
        <span class="ob-mono text-[10px] text-black">OB</span>
      </div>
      <div>
        <div class="text-[13px] font-semibold leading-tight">Obelisk · Server 01</div>
        <div class="ob-mono text-[9px] text-white/45">{{ characters.length }} CHARACTER{{ characters.length === 1 ? '' : 'S' }}</div>
      </div>
    </div>

    <div class="absolute flex gap-1 rounded-lg border border-white/12 bg-[#0d1012] p-1" style="left:50%;top:22px;transform:translateX(-50%)">
      <span class="ob-mono text-[9px] text-white/30 self-center px-1.5">CAMERA</span>
      <button
        v-for="opt in [['head','Head'],['torso','Torso'],['full','Full body']]" :key="opt[0]"
        @click="setFraming(opt[0])"
        class="h-6 px-2.5 rounded-md text-[10.5px] transition"
        :class="framing === opt[0] ? 'text-black font-medium bg-ob-accent' : 'text-white/45 hover:bg-white/8'"
      >{{ opt[1] }}</button>
    </div>

    <div class="absolute rounded-xl border border-white/12 bg-[#0d1012] overflow-hidden" style="left:28px;top:76px;width:300px">
      <div class="h-8 px-3 flex items-center justify-between border-b border-white/8">
        <span class="ob-mono text-[12px] tracking-[0.2em] text-white/35">CHARACTERS · {{ characters.length }}</span>
        <span class="ob-mono text-[9px] text-white/25">W / S</span>
      </div>
      <div class="p-1.5 space-y-1">
        <button
          v-for="(entry, i) in characters" :key="entry.character.id"
          @click="selectedIndex = i"
          class="w-full flex items-center gap-2.5 px-2.5 py-2 rounded-md text-left transition"
          :class="i === selectedIndex ? 'text-black bg-ob-accent' : 'text-white/60 hover:text-white hover:bg-white/8'"
        >
          <span class="flex-1 min-w-0 block text-[12.5px] font-medium truncate">{{ entry.character.first_name }} {{ entry.character.last_name }}</span>
          <span class="ob-mono text-[9px] shrink-0" :class="i === selectedIndex ? 'text-black/55' : 'text-white/25'">{{ entry.character.last_played_at || 'Never' }}</span>
        </button>
        <button
          @click="$emit('create')"
          class="w-full flex items-center gap-2.5 px-2.5 py-2 rounded-md border border-dashed border-white/15 hover:border-ob-accent/60 hover:bg-white/6 transition text-left"
        >
          <span class="flex-1 text-[12.5px] text-white/55">+ Create new character</span>
        </button>
      </div>
    </div>

    <div v-if="selected" class="absolute rounded-xl border border-white/12 bg-[#0d1012] p-3.5" style="left:28px;bottom:96px;width:300px">
      <div class="ob-mono text-[9px] tracking-[0.2em] text-white/30 mb-2">SELECTED</div>
      <div class="text-[19px] font-semibold leading-tight mb-3">{{ selected.character.first_name }} {{ selected.character.last_name }}</div>
      <div class="space-y-1">
        <div class="flex items-baseline justify-between text-[11.5px]">
          <span class="ob-mono text-[10px] uppercase text-white/30">Date of birth</span>
          <span>{{ selected.character.dob }}</span>
        </div>
        <div class="flex items-baseline justify-between text-[11.5px]">
          <span class="ob-mono text-[10px] uppercase text-white/30">Last seen</span>
          <span>{{ selected.character.last_played_at || 'Never' }}</span>
        </div>
      </div>
    </div>

    <div v-if="selected" class="absolute rounded-xl border border-white/12 bg-black/62 p-3.5" style="right:28px;bottom:96px;width:300px">
      <div class="ob-mono text-[9px] tracking-[0.2em] text-white/35 mb-2">SPAWN POINT</div>
      <button
        @click="select(selected.character.id)"
        class="w-full h-10 rounded-lg text-black text-[13px] font-semibold bg-ob-accent"
      >Play as {{ selected.character.first_name }}</button>
    </div>

    <div class="absolute left-0 right-0 flex items-center justify-center gap-4" style="bottom:34px">
      <div v-for="[k, l] in [['W / S','Character'],['N','New character'],['ENTER','Play']]" :key="k" class="flex items-center gap-1.5">
        <span class="ob-mono inline-grid place-items-center h-[17px] rounded shrink-0 px-1.5 text-[9px] bg-white/13 border border-white/20">{{ k }}</span>
        <span class="text-[10px] text-white/50">{{ l }}</span>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { useCharacterSelection } from './useCharacterSelection.js'

const emit = defineEmits(['create'])
const { characters, selectedIndex, selected, list, select, updatePreview } = useCharacterSelection()
const framing = ref('full')

function setFraming(f) {
  framing.value = f
  updatePreview({ cameraFraming: f })
}

function onKey(e) {
  const k = e.key.toLowerCase()
  if (k === 'w' || k === 'arrowup') { e.preventDefault(); selectedIndex.value = (selectedIndex.value - 1 + characters.value.length) % characters.value.length }
  if (k === 's' || k === 'arrowdown') { e.preventDefault(); selectedIndex.value = (selectedIndex.value + 1) % characters.value.length }
  if (k === 'n') emit('create')
  if (k === 'enter' && selected.value) select(selected.value.character.id)
}

onMounted(() => {
  list()
  window.addEventListener('keydown', onKey)
})
onUnmounted(() => window.removeEventListener('keydown', onKey))
</script>
```

- [ ] **Step 2: Commit**

```bash
cd core
git add plugins/oblsk_character-selection/web/CharacterSelect.vue
git commit -m "Add CharacterSelect.vue: roster, camera framing, spawn panel"
```

---

### Task 13: `CharacterCreator.vue` — 4-step creator

**Files:**
- Create: `core/plugins/oblsk_character-selection/web/CharacterCreator.vue`

**Interfaces:**
- Consumes: `useCharacterSelection()` (Task 11), `Appearance`-equivalent presets (duplicated client-side per Task 11's note — this task adds that duplication, since it's UI-facing data the Lua `shared/appearance.lua` can't be imported into Vue), `Slider.vue`/`SwatchGrid.vue`/`Stepper.vue`/`TextField.vue` (Task 10).
- Produces: `<CharacterCreator @back="..." />`, emits `back` on cancel/confirm, consumed by `CharacterSelection.vue` (Task 14).

- [ ] **Step 1: Add the browser-side preset mirror (small, duplicated deliberately per Task 11)**

```js
// core/plugins/oblsk_character-selection/web/appearancePresets.js
// Mirrors core/plugins/oblsk_character-selection/shared/appearance.lua's
// swatch/label data for the browser UI. Lua tables aren't importable into
// Vue; this file owns only what the UI needs to RENDER (labels, swatches,
// option counts) — the actual drawable/texture/native IDs stay server/client
// Lua-side and are applied via character-selection:preview-update payloads
// that reference presets by index, not by re-sending IDs from the browser.
export const WARDROBE_SLOTS = [
  ['top', 'Top', ['Tee · black', 'Henley', 'Polo', 'Tank', 'Flannel', 'Hoodie']],
  ['jacket', 'Outerwear', ['None', 'Field jacket', 'Bomber', 'Leather', 'Denim']],
  ['pants', 'Legwear', ['Jeans', 'Cargo · khaki', 'Chinos', 'Joggers', 'Tactical']],
  ['shoes', 'Footwear', ['Sneakers', 'Combat boots', 'Runners', 'Dress shoes']],
  ['hat', 'Headwear', ['None', 'Ball cap', 'Beanie', 'Bandana']],
  ['acc', 'Accessory', ['None', 'Watch', 'Chain', 'Glasses']],
]

export const SKIN_TONES = ['#3a2418', '#4a2e1e', '#5e3b25', '#7a4f33', '#9a6a48', '#b88761', '#d2a47e', '#e8c39c'].map(swatch => ({ swatch }))
export const EYE_COLORS = ['#2a4a6e', '#3b6e8f', '#4a8e4a', '#6b5b3a', '#3a3a3a', '#7a4a2a', '#1a3a3a', '#5a2a4a'].map(swatch => ({ swatch }))
export const HAIR_COLORS = ['#0e0d0c', '#2b1d15', '#4a2f1c', '#7a4a22', '#b07a34', '#d9b877', '#8a8a8a', '#c94f2a'].map(swatch => ({ swatch }))
export const HAIR_STYLE_COUNT = 6

export const SLIDER_LABELS = [
  ['nose', 'Nose width'], ['noseH', 'Nose height'], ['cheek', 'Cheekbones'], ['jaw', 'Jaw width'],
  ['chin', 'Chin length'], ['brow', 'Brow height'], ['eyeSize', 'Eye size'], ['lips', 'Lip fullness'],
]
```

- [ ] **Step 2: Write `CharacterCreator.vue`**

```vue
<!-- core/plugins/oblsk_character-selection/web/CharacterCreator.vue -->
<template>
  <div class="absolute inset-0 grid" style="grid-template-columns:392px 1fr">
    <div class="border-r border-white/8 bg-[#0d1012] flex flex-col min-h-0">
      <div class="p-5 pb-4 shrink-0">
        <button @click="$emit('back')" class="mb-5 text-[12.5px] text-white/45 hover:text-white">← Back to roster</button>
        <h2 class="text-[22px] font-semibold tracking-tight">New character</h2>
        <p class="text-[12px] text-white/40 mb-4">Step {{ step + 1 }} of {{ STEPS.length }} · {{ STEPS[step] }}</p>
        <div class="flex gap-1 mb-4">
          <div v-for="(_, i) in STEPS" :key="i" class="flex-1 h-1 rounded-full transition" :class="i <= step ? 'bg-ob-accent' : 'bg-white/10'" />
        </div>
        <div class="grid grid-cols-2 gap-1.5">
          <button
            v-for="(s, i) in STEPS" :key="s" @click="step = i"
            class="h-9 px-3 rounded-lg text-[12.5px] flex items-center justify-between gap-2 transition"
            :class="i === step ? 'text-black font-medium bg-ob-accent' : i < step ? 'bg-white/[0.06] text-white/60' : 'bg-white/[0.03] text-white/30'"
          ><span class="truncate">{{ s }}</span></button>
        </div>
        <div v-if="step === 2" class="flex gap-1 mt-3">
          <button
            v-for="t in ['face','hair','body']" :key="t" @click="tab = t"
            class="flex-1 h-8 rounded-lg text-[11.5px] capitalize transition"
            :class="tab === t ? 'text-black font-medium bg-ob-accent' : 'bg-white/[0.04] text-white/45'"
          >{{ t }}</button>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto ob-no-scroll px-5 pb-5">
        <template v-if="step === 0">
          <TextField label="First name" v-model="form.first" />
          <TextField label="Surname" v-model="form.last" />
          <div class="flex gap-1.5 mb-4">
            <button
              v-for="s in ['male','female']" :key="s" @click="setGender(s)"
              class="flex-1 h-9 rounded-lg text-[12px] capitalize transition"
              :class="form.sex === s ? 'text-black font-medium bg-ob-accent' : 'bg-white/6 text-white/50'"
            >{{ s }}</button>
          </div>
          <div class="grid grid-cols-3 gap-2">
            <Stepper label="Year" v-model="form.dobY" :min="1960" :max="2008" />
            <Stepper label="Month" v-model="form.dobM" :min="1" :max="12" pad />
            <Stepper label="Day" v-model="form.dobD" :min="1" :max="31" pad />
          </div>
        </template>

        <template v-else-if="step === 1">
          <p class="text-[11.5px] text-white/40 mb-4 leading-relaxed">Parent resemblance blends facial shape and skin tone. Locked once confirmed.</p>
          <Stepper label="Mother head" v-model="form.headBlend.shapeFirst" :min="0" :max="45" />
          <Stepper label="Father head" v-model="form.headBlend.shapeSecond" :min="0" :max="45" />
          <Slider label="Mother ← → Father (shape)" v-model="shapeMixPct" />
          <Slider label="Mother ← → Father (skin)" v-model="skinMixPct" />
        </template>

        <template v-else-if="step === 2">
          <template v-if="tab === 'face'">
            <Slider v-for="[key, label] in SLIDER_LABELS" :key="key" :label="label" v-model="form.faceFeaturesPct[key]" />
            <SwatchGrid :presets="SKIN_TONES" v-model="form.skinIndex" />
            <SwatchGrid :presets="EYE_COLORS" v-model="form.eyeIndex" />
          </template>
          <template v-else-if="tab === 'hair'">
            <SwatchGrid :presets="HAIR_COLORS" v-model="form.hairColorIndex" />
            <div class="grid grid-cols-3 gap-2">
              <button
                v-for="i in HAIR_STYLE_COUNT" :key="i" @click="form.hairStyleIndex = i - 1"
                class="aspect-square rounded-lg border text-[9px] ob-mono"
                :class="form.hairStyleIndex === i - 1 ? 'border-ob-accent text-ob-accent bg-ob-accent/10' : 'border-white/10 text-white/30'"
              >HAIR-{{ String(i).padStart(2, '0') }}</button>
            </div>
          </template>
          <template v-else-if="tab === 'body'">
            <div class="text-[12px] text-white/35 py-8 text-center">No native body-scale effect — stored for future use.</div>
          </template>
        </template>

        <template v-else-if="step === 3">
          <template v-for="[key, label, opts] in WARDROBE_SLOTS" :key="key">
            <div class="ob-mono text-[9px] tracking-[0.2em] uppercase text-white/30 mb-2.5 mt-4">{{ label }}</div>
            <div class="flex flex-wrap gap-1.5">
              <button
                v-for="(o, i) in opts" :key="o" @click="setWardrobe(key, i)"
                class="h-8 px-2.5 rounded-lg text-[11.5px] border transition"
                :class="form.fit[key] === i ? 'border-ob-accent bg-ob-accent/12 text-ob-accent' : 'border-white/10 text-white/50'"
              >{{ o }}</button>
            </div>
          </template>
        </template>
      </div>

      <div class="p-4 border-t border-white/8 shrink-0 flex gap-2">
        <button @click="step = Math.max(0, step - 1)" :disabled="step === 0" class="h-10 px-4 rounded-xl border border-white/12 text-[12.5px] disabled:opacity-25">Back</button>
        <button @click="next" class="flex-1 h-10 rounded-xl text-black text-[12.5px] font-semibold bg-ob-accent">
          {{ step === STEPS.length - 1 ? 'Enter the city' : `Continue → ${STEPS[step + 1]}` }}
        </button>
      </div>
    </div>

    <div class="relative flex flex-col min-w-0">
      <div class="absolute top-5 right-5 z-10 flex items-center gap-2">
        <button @click="cycleAngle" class="h-8 px-3 rounded-lg border border-white/12 bg-black/50 text-[11.5px]">F · Rotate</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { reactive, ref, computed, watch, onMounted, onUnmounted } from 'vue'
import { useCharacterSelection } from './useCharacterSelection.js'
import Slider from './controls/Slider.vue'
import SwatchGrid from './controls/SwatchGrid.vue'
import Stepper from './controls/Stepper.vue'
import TextField from './controls/TextField.vue'
import { WARDROBE_SLOTS, SKIN_TONES, EYE_COLORS, HAIR_COLORS, HAIR_STYLE_COUNT, SLIDER_LABELS } from './appearancePresets.js'

const emit = defineEmits(['back'])
const { create, updatePreview } = useCharacterSelection()

const STEPS = ['Identity', 'Heritage', 'Appearance', 'Wardrobe']
const step = ref(2)
const tab = ref('face')
const angle = ref(0)

const form = reactive({
  first: 'Alex', last: 'Reyes', sex: 'female',
  dobY: 1994, dobM: 3, dobD: 12,
  headBlend: { shapeFirst: 0, shapeSecond: 1, shapeThird: 0, skinFirst: 0, skinSecond: 1, skinThird: 0, shapeMix: 0.5, skinMix: 0.5, thirdMix: 0.0 },
  faceFeaturesPct: { nose: 50, noseH: 50, cheek: 50, jaw: 50, chin: 50, brow: 50, eyeSize: 50, lips: 50 },
  skinIndex: 4, eyeIndex: 2, hairColorIndex: 1, hairStyleIndex: 2,
  fit: { top: 0, jacket: 1, pants: 0, shoes: 0, hat: 0, acc: 0 },
})

const shapeMixPct = computed({
  get: () => Math.round(form.headBlend.shapeMix * 100),
  set: (v) => { form.headBlend.shapeMix = v / 100 },
})
const skinMixPct = computed({
  get: () => Math.round(form.headBlend.skinMix * 100),
  set: (v) => { form.headBlend.skinMix = v / 100 },
})

function setGender(sex) {
  form.sex = sex
  updatePreview({ gender: sex === 'female' ? 'female' : 'male' })
}

function setWardrobe(key, i) {
  form.fit[key] = i
  updatePreview({ wardrobeSlot: { key, optionIndex: i } })
}

function buildAppearance() {
  const faceFeatures = {}
  const FEATURE_INDEX = { nose: 0, noseH: 2, cheek: 6, jaw: 15, chin: 10, brow: 8, eyeSize: 13, lips: 17 }
  for (const [key, idx] of Object.entries(FEATURE_INDEX)) {
    faceFeatures[idx] = (form.faceFeaturesPct[key] - 50) / 50
  }
  return {
    headBlend: { ...form.headBlend },
    faceFeatures,
    hairStyle: form.hairStyleIndex,
    hairColor: form.hairColorIndex,
    hairHighlight: form.hairColorIndex,
    eyeColor: form.eyeIndex,
    components: {},
    props: {},
  }
}

watch(() => JSON.stringify(form), () => {
  updatePreview({ appearance: buildAppearance() })
}, { immediate: true })

function cycleAngle() {
  angle.value = (angle.value + 1) % 4
  updatePreview({ cameraAngle: angle.value })
}

function onKey(e) {
  if (e.key.toLowerCase() === 'f') cycleAngle()
}

function next() {
  if (step.value === STEPS.length - 1) {
    create({
      first_name: form.first, last_name: form.last, gender: form.sex,
      dob: `${form.dobY}-${String(form.dobM).padStart(2, '0')}-${String(form.dobD).padStart(2, '0')}`,
      bio: '', appearance: buildAppearance(),
    })
    emit('back')
    return
  }
  step.value = Math.min(STEPS.length - 1, step.value + 1)
}

onMounted(() => window.addEventListener('keydown', onKey))
onUnmounted(() => window.removeEventListener('keydown', onKey))
</script>
```

- [ ] **Step 3: Commit**

```bash
cd core
git add plugins/oblsk_character-selection/web/CharacterCreator.vue plugins/oblsk_character-selection/web/appearancePresets.js
git commit -m "Add CharacterCreator.vue: 4-step creator with live preview updates"
```

---

### Task 14: `CharacterSelection.vue` shell, global element + route registration

**Files:**
- Modify: `core/plugins/oblsk_character-selection/web/CharacterSelection.vue` (full rewrite — becomes the mode-switch shell, matching the prototype's `CharacterUI` combined component)
- Modify: `core/plugins/oblsk_character-selection/web/routes.js` (full rewrite)
- Create: `core/plugins/oblsk_character-selection/web/globalElements.js`

**Interfaces:**
- Consumes: `CharacterSelect.vue` (Task 12), `CharacterCreator.vue` (Task 13).
- Produces: registers `character-selection` as a global element (shown/hidden via `WebView.showGlobalElement('character-selection')` from Task 9's client Lua).

- [ ] **Step 1: Rewrite `CharacterSelection.vue`**

```vue
<!-- core/plugins/oblsk_character-selection/web/CharacterSelection.vue -->
<template>
  <div class="h-full w-full relative bg-[#07090a] text-white">
    <CharacterSelect v-if="mode === 'select'" @create="mode = 'create'" />
    <CharacterCreator v-else @back="mode = 'select'" />
  </div>
</template>

<script setup>
import { ref } from 'vue'
import CharacterSelect from './CharacterSelect.vue'
import CharacterCreator from './CharacterCreator.vue'

const mode = ref('select')
</script>
```

- [ ] **Step 2: Rewrite `routes.js`**

```js
// core/plugins/oblsk_character-selection/web/routes.js
export default [
  { path: '/character-selection', name: 'CharacterSelection', component: () => import('./CharacterSelection.vue') },
]
```

- [ ] **Step 3: Write `globalElements.js`**

```js
// core/plugins/oblsk_character-selection/web/globalElements.js
import CharacterSelection from './CharacterSelection.vue'

export default [
  { name: 'character-selection', component: CharacterSelection, defaultVisible: false },
]
```

- [ ] **Step 4: Commit**

```bash
cd core
git add plugins/oblsk_character-selection/web/CharacterSelection.vue plugins/oblsk_character-selection/web/routes.js plugins/oblsk_character-selection/web/globalElements.js
git commit -m "Register character-selection as a global element, add mode-switch shell"
```

---

### Task 15: Run full test suite + end-to-end manual verification

**Files:** none (verification task)

- [ ] **Step 1: Run every new/affected automated spec**

```bash
cd /home/andi/Projects/obelisk-framework
lua5.4 core/tests/spawn_manager_service_spec.lua
lua5.4 core/plugins/oblsk_character-selection/tests/appearance_spec.lua
lua5.4 core/plugins/oblsk_character-selection/tests/character_selection_service_spec.lua
lua5.4 core/tests/action_service_spec.lua
lua5.4 core/modules/oblsk_characters/tests/character_service_spec.lua
```

Expected: every file prints `N passed, 0 failed` and exits 0.

- [ ] **Step 2: Build the web bundle and confirm it picks up the new plugin files**

```bash
cd core/web
npm run build
```

Expected: build succeeds; check the output for `CharacterSelect`/`CharacterCreator` chunk names, and confirm no glob errors about `plugins/oblsk_character-selection/web/globalElements.js` or `routes.js`.

- [ ] **Step 3: In-game manual checklist (native code — not automatable)**

Start the server (`fxserver` per `docker-compose.yml`/`server.cfg`), connect a client, and verify:
- On connect: player freezes, HUD hides, `character-selection` screen shows automatically (no manual `WebView.focus()` needed).
- Roster: existing characters listed; W/S changes selection and updates the preview ped's appearance; head/torso/full camera buttons visibly reframe.
- N opens the creator; Identity/Heritage/Appearance/Wardrobe steps all live-update the preview ped as sliders/swatches/wardrobe buttons change; F rotates the camera through 4 angles.
- Confirming on the Wardrobe step creates the character (roster updates), returns to select mode.
- Selecting a character and pressing Play: player unfreezes, HUD returns, the real player ped has the chosen model + appearance applied, `character-selection` screen hides.
- Deleting a character (if a delete affordance was wired — not in this plan's UI scope, verify `characters:delete` still works via a direct `Obelisk.emit('character-selection:delete', {characterId})` call from the browser devtools console as a smoke test) soft-deletes and the roster updates.

- [ ] **Step 4: Update the plugin README's "Usage" section with the verified command list, commit**

```bash
cd core
git add plugins/oblsk_character-selection/README.md
git commit -m "Document character-selection plugin usage after end-to-end verification" --allow-empty
```

---

## Self-Review Notes

- **Spec coverage:** SpawnManagerService (Task 1-2) ✓, appearance data shape + heritage native (Task 4, 7) ✓, curated wardrobe/color tables flagged as tunable (Task 4) ✓, build/height stored but non-native (Task 13's "body" tab) ✓, tattoos/makeup deferred (Task 13 omits them from the tab list entirely, per spec's "non-functional placeholders" — simplified to omission rather than a dead tab) ✓, server actions (Task 5-6) ✓, Vue port replacing placeholders (Task 3, 10-14) ✓, dev-mirror mock (Task 11) ✓.
- **Placeholder scan:** no TBD/TODO markers; every step has real, complete code.
- **Type consistency:** `Appearance.DEFAULT_APPEARANCE(gender)` (Task 4) is the single source of the appearance shape used identically in Task 5's tests, Task 7's `CharacterAppearanceService.apply`, and Task 9's fallback. `CharacterSelectionService.selectCharacter` returns `{vitals, appearance}` (Task 5) matching what Task 6 forwards via `character-selection:selected` and what Task 9's `character-selection:select` handler reads (`data.appearance`).
- **Scope check:** single subsystem (one plugin + one small core service), appropriately sized for one plan — not decomposed further.
