# Barber Shop Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `oblsk_barber`, a barber-chair shop plugin with real GTA V hair
data (83 male / 81 female styles, real thumbnails) reused from the
character-selection system, cash/card checkout, and a clipper-precision
minigame.

**Architecture:** `oblsk_character-selection/shared/appearance.lua`'s
`Appearance.HAIR_STYLES` (currently a 6-entry, gender-agnostic placeholder)
becomes gender-keyed with the full real catalog + thumbnails. Two new
exports on that plugin (`getHairStyles`, `applyAppearance`) let the new
`oblsk_barber` plugin — a separate FiveM resource — read the catalog and
apply it to a ped, the same cross-plugin pattern `oblsk_licenses` already
uses for `hasValidLicense`. `oblsk_barber` itself follows `oblsk_terminal`'s
shape: migrations + service + main.lua per side, ported Vue UI.

**Tech Stack:** Lua 5.4 (FXServer resources), Vue 3 SFCs, existing
QueryBuilder/Schema/BaseModel ORM, existing `ItemService`/`BankingService`
(cash/card charge), existing `CharacterAppearance` model (core module,
global to every resource).

**Spec:** `core/docs/superpowers/specs/2026-08-15-barber-plugin-design.md`

## Global Constraints

- Male hair: drawables 0-82 (83 styles). Female hair: drawables 0-80 (81
  styles). Source: wiki.rage.mp Male/Female Hair Styles pages.
- Thumbnails are bundled locally (not hotlinked) at
  `oblsk_character-selection/web/assets/hair/{male,female}/<drawable>.jpg`.
- `oblsk_barber` must not own a second copy of the hair catalog — it reads
  it via `exports['oblsk_character-selection']` only.
- Non-hair sections (hair color, highlight, beard, beard color, eyebrows,
  eyebrow color, chest hair, chest hair color, makeup, blush, lipstick)
  keep the design prototype's existing counts/prices — no wiki source was
  given for those.
- All new Lua services get a `tests/*_spec.lua` runnable via
  `lua5.4 <path> `, matching every existing plugin's test convention (no
  external test framework, custom `test`/`eq`/`truthy` runner as seen in
  `oblsk_character-selection/tests/appearance_spec.lua`).

---

## File Structure

**Modify (`oblsk_character-selection`):**
- `shared/appearance.lua` — gender-split `HAIR_STYLES`, updated
  `DEFAULT_APPEARANCE`/`resolvePresetAppearance` hair lookups
- `fxmanifest.lua` — add `exports {}` / `client_exports {}` blocks, add
  `web/assets/hair/**/*.jpg` to `files {}`
- `server/main.lua` — add `getHairStyles` export
- `client/main.lua` — add `applyAppearance` export
- `tests/appearance_spec.lua` — cases for gender-split hair lookup
- New: `web/assets/hair/male/<0-82>.jpg`, `web/assets/hair/female/<0-80>.jpg`

**Create (`oblsk_barber`, new plugin):**
```
oblsk_barber/
  fxmanifest.lua
  README.md
  shared/config.lua                        -- non-hair section prices/counts
  server/
    migrations.json
    migrations/2026_08_15_150000_create_barber_chairs_table.lua
    services/BarberService.lua
    main.lua
  client/
    main.lua
  web/
    Barber.vue
    BarberClipperGame.vue
    routes.js
    globalElements.js
  tests/
    barber_service_spec.lua
```

**Modify (framework-wide):**
- `plugins/registry.json` — add `"oblsk_barber"`

---

## Task 1: Real gender-split hair catalog + bundled thumbnails

**Files:**
- Modify: `plugins/oblsk_character-selection/shared/appearance.lua:234-242` (the `Appearance.HAIR_STYLES` block)
- Modify: `plugins/oblsk_character-selection/shared/appearance.lua:257-275` (`DEFAULT_APPEARANCE`)
- Modify: `plugins/oblsk_character-selection/shared/appearance.lua:297-389` (`resolvePresetAppearance`)
- Modify: `plugins/oblsk_character-selection/tests/appearance_spec.lua`
- Create: `plugins/oblsk_character-selection/web/assets/hair/male/0.jpg` … `82.jpg` (83 files)
- Create: `plugins/oblsk_character-selection/web/assets/hair/female/0.jpg` … `80.jpg` (81 files)

**Interfaces:**
- Produces: `Appearance.HAIR_STYLES.male` / `Appearance.HAIR_STYLES.female`, each an array of
  `{ label = string, drawable = number, thumb = string }`, 1-indexed (`[1]` = drawable 0), sorted
  by drawable ascending. `thumb` is the web-relative path
  `assets/hair/<gender>/<drawable>.jpg`.

- [ ] **Step 1: Copy the already-downloaded, already-verified thumbnails into the plugin**

The 164 images were already fetched from wiki.rage.mp and verified as real
240x240 JPEGs (not error pages) during design. Copy them in:

```bash
mkdir -p core/plugins/oblsk_character-selection/web/assets/hair/male
mkdir -p core/plugins/oblsk_character-selection/web/assets/hair/female
cp /tmp/claude-1000/-home-andi-Projects-obelisk-framework/232df421-57ce-4e76-95e9-d3841677ad24/scratchpad/hair/male/*.jpg \
   core/plugins/oblsk_character-selection/web/assets/hair/male/
cp /tmp/claude-1000/-home-andi-Projects-obelisk-framework/232df421-57ce-4e76-95e9-d3841677ad24/scratchpad/hair/female/*.jpg \
   core/plugins/oblsk_character-selection/web/assets/hair/female/
```

If that scratchpad path is gone (different machine/session), re-fetch first:

```bash
SP=/tmp/barber-hair-fetch && mkdir -p "$SP"
for g in Male Female; do
  curl -s -A "Mozilla/5.0" -L "https://wiki.rage.mp/wiki/${g}_Hair_Styles" -o "$SP/${g}.html"
done
SP="$SP" python3 - <<'EOF'
import re, os
SP = os.environ["SP"]
for gender, f in [('male', 'Male.html'), ('female', 'Female.html')]:
    html = open(f"{SP}/{f}").read()
    pairs = re.findall(r'title="Drawable: (\d+)"><img alt="Drawable: \d+" src="([^"]+)"', html)
    seen = {}
    for n, src in pairs:
        n = int(n)
        if n not in seen:
            seen[n] = src
    with open(f"{SP}/{gender}_hair.tsv", "w") as out:
        for n in sorted(seen):
            out.write(f"{n}\thttps://wiki.rage.mp{seen[n]}\n")
EOF
for g in male female; do
  mkdir -p "$SP/hair/$g"
  while IFS=$'\t' read -r n url; do
    hires=$(echo "$url" | sed 's#/120px-#/240px-#')
    curl -s -A "Mozilla/5.0" -L "$hires" -o "$SP/hair/$g/$n.jpg"
  done < "$SP/${g}_hair.tsv"
done
```

- [ ] **Step 2: Verify the copy — 83 male files, 81 female files, all real JPEGs**

```bash
ls core/plugins/oblsk_character-selection/web/assets/hair/male | wc -l    # expect 83
ls core/plugins/oblsk_character-selection/web/assets/hair/female | wc -l  # expect 81
file core/plugins/oblsk_character-selection/web/assets/hair/male/0.jpg core/plugins/oblsk_character-selection/web/assets/hair/female/0.jpg
```

Expected: both counts match, `file` reports `JPEG image data` for both (not
`HTML document` — that would mean the wiki returned an error page).

- [ ] **Step 3: Fix the two existing tests that hardcode the old flat 6-entry shape**

`plugins/oblsk_character-selection/tests/appearance_spec.lua` has two
assertions that only make sense against the old flat `HAIR_STYLES` array
and will break once it's gender-keyed. Fix both now, before adding new
tests:

At line 68, change:
```lua
    eq(#Appearance.HAIR_STYLES, 6)
```
to two lines (drop the shared `SKIN_TONES/EYE_COLORS/HAIR_COLORS` combo
line's `HAIR_STYLES` clause, add the real counts):
```lua
    eq(#Appearance.HAIR_STYLES.male, 83)
    eq(#Appearance.HAIR_STYLES.female, 81)
```
Also update that test's name string above it — it currently reads
`'color/skin/hair-style tables each have exactly 8/8/8/6 presets'`; change
`8/8/8/6` to `8/8/8`, since the hair-style count is no longer a fixed
single number.

At line 154 (inside `test('resolvePresetAppearance turns 0-based UI indices
into native ids', ...)`, which calls `Appearance.resolvePresetAppearance('female', ...)`), change:
```lua
    eq(resolved.hairStyle, Appearance.HAIR_STYLES[1].drawable)
```
to:
```lua
    eq(resolved.hairStyle, Appearance.HAIR_STYLES.female[1].drawable)
```

Also fix `plugins/oblsk_character-selection/tests/character_selection_service_spec.lua:111`
(inside `test('createCharacter resolves preset indices to native ids and
derives ped_model from gender', ...)`, which creates a `gender = 'female'`
character), change:
```lua
        eq(stored.hairStyle, Appearance.HAIR_STYLES[4].drawable)
```
to:
```lua
        eq(stored.hairStyle, Appearance.HAIR_STYLES.female[4].drawable)
```

`plugins/oblsk_character-selection/web/appearancePresets.js`'s own
`HAIR_STYLES` (used only by `CharacterCreator.vue`'s UI options, a
hand-curated 6-entry JS array fully decoupled from the Lua table) is
intentionally left untouched — it's out of this plugin's scope (only the
barber shop needs the full real catalog) and nothing about widening the
Lua side breaks it, since the creator only ever sends indices 0-5, still a
valid subset of the new 0-82/0-80 range.

- [ ] **Step 4: Write the new failing tests for gender-split HAIR_STYLES**

Add to `plugins/oblsk_character-selection/tests/appearance_spec.lua`, near
the existing wardrobe-slot test:

```lua
test('HAIR_STYLES is gender-split with the real GTA V drawable ranges', function()
    truthy(type(Appearance.HAIR_STYLES.male) == 'table', 'HAIR_STYLES.male missing')
    truthy(type(Appearance.HAIR_STYLES.female) == 'table', 'HAIR_STYLES.female missing')
    eq(#Appearance.HAIR_STYLES.male, 83, 'male hair style count')
    eq(#Appearance.HAIR_STYLES.female, 81, 'female hair style count')

    for _, gender in ipairs({ 'male', 'female' }) do
        local list = Appearance.HAIR_STYLES[gender]
        for i, entry in ipairs(list) do
            eq(entry.drawable, i - 1, gender .. ' hair entry ' .. i .. ' drawable must equal its 0-based index')
            truthy(type(entry.label) == 'string' and #entry.label > 0, gender .. ' hair entry ' .. i .. ' missing label')
            truthy(type(entry.thumb) == 'string' and entry.thumb:find(gender .. '/' .. entry.drawable .. '.jpg', 1, true) ~= nil,
                gender .. ' hair entry ' .. i .. ' thumb path must reference its own drawable')
        end
    end
end)

test('DEFAULT_APPEARANCE picks the first hair style for the given gender', function()
    local maleDefault = Appearance.DEFAULT_APPEARANCE('male')
    local femaleDefault = Appearance.DEFAULT_APPEARANCE('female')
    eq(maleDefault.hairStyle, Appearance.HAIR_STYLES.male[1].drawable)
    eq(femaleDefault.hairStyle, Appearance.HAIR_STYLES.female[1].drawable)
end)

test('resolvePresetAppearance resolves hairStyleIndex against the right gender list', function()
    local resolved = Appearance.resolvePresetAppearance('female', { hairStyleIndex = 5 })
    eq(resolved.hairStyle, Appearance.HAIR_STYLES.female[6].drawable)

    local resolvedMale = Appearance.resolvePresetAppearance('male', { hairStyleIndex = 5 })
    eq(resolvedMale.hairStyle, Appearance.HAIR_STYLES.male[6].drawable)
end)
```

- [ ] **Step 5: Run the test file to confirm it fails**

Run: `lua5.4 core/plugins/oblsk_character-selection/tests/appearance_spec.lua`
Expected: FAIL — `HAIR_STYLES.male missing` (current `HAIR_STYLES` is a flat
6-entry array, not gender-keyed).

- [ ] **Step 6: Generate and paste in the real gender-split HAIR_STYLES table**

Replace the current block at `shared/appearance.lua:234-242`:

```lua
--- Component 2 (hair) drawable per style.
Appearance.HAIR_STYLES = {
    { label = 'Close shave',  drawable = 0 },
    { label = 'Buzzcut',      drawable = 1 },
    { label = 'Slicked back', drawable = 2 },
    { label = 'Messy long',   drawable = 3 },
    { label = 'Ponytail',     drawable = 4 },
    { label = 'Mohawk',       drawable = 5 },
}
```

with a generated block. Run this to print the replacement Lua (reads the
same tsv files from Step 1; regenerate them first if missing):

```bash
SP=/tmp/claude-1000/-home-andi-Projects-obelisk-framework/232df421-57ce-4e76-95e9-d3841677ad24/scratchpad
SP="$SP" python3 - <<'EOF' > /tmp/hair_styles_block.lua
import os
SP = os.environ["SP"]
print("--- Component 2 (hair) drawable per style. Gender-split -- the male and")
print("--- female freemode models don't share a drawable table (component 2's")
print("--- meaning differs per model), same as WARDROBE above. Labels are")
print("--- numbered (the wiki source doesn't name individual cuts), same")
print("--- 'no fake names' convention as makeupOptions() below.")
print("Appearance.HAIR_STYLES = {")
for gender in ('male', 'female'):
    print(f"    {gender} = {{")
    with open(f"{SP}/{gender}_hair.tsv") as f:
        for line in f:
            n, _url = line.strip().split('\t')
            n = int(n)
            print(f"        {{ label = 'Style {n + 1}', drawable = {n}, thumb = 'assets/hair/{gender}/{n}.jpg' }},")
    print("    },")
print("}")
EOF
cat /tmp/hair_styles_block.lua
```

Paste the printed block in place of the old `Appearance.HAIR_STYLES`
definition (keep it at the same location in the file, right before the
`--- @param gender string 'male' | 'female'` comment above
`Appearance.DEFAULT_APPEARANCE`).

- [ ] **Step 7: Update the two call sites to be gender-scoped**

In `Appearance.DEFAULT_APPEARANCE(gender)`, change:

```lua
        hairStyle = Appearance.HAIR_STYLES[1].drawable,
```
to:
```lua
        hairStyle = Appearance.HAIR_STYLES[gender][1].drawable,
```

In `Appearance.resolvePresetAppearance(gender, raw)`, change:

```lua
    local hairStyle = raw.hairStyleIndex and Appearance.HAIR_STYLES[raw.hairStyleIndex + 1]
```
to:
```lua
    local hairStyle = raw.hairStyleIndex and Appearance.HAIR_STYLES[gender][raw.hairStyleIndex + 1]
```

(`gender` is already normalized to `'male'`/`'female'` a few lines above
this in the existing function — no other change needed there.)

- [ ] **Step 8: Run the test file to confirm it passes**

Run: `lua5.4 core/plugins/oblsk_character-selection/tests/appearance_spec.lua`
Expected: PASS, all tests including the 3 new ones.

- [ ] **Step 9: Commit**

```bash
cd core
git add plugins/oblsk_character-selection/shared/appearance.lua \
        plugins/oblsk_character-selection/tests/appearance_spec.lua \
        plugins/oblsk_character-selection/web/assets/hair
git commit -m "feat(character-selection): real gender-split GTA V hair catalog with thumbnails"
```

---

## Task 2: Cross-plugin exports for the hair catalog and ped apply

**Files:**
- Modify: `plugins/oblsk_character-selection/fxmanifest.lua`
- Modify: `plugins/oblsk_character-selection/server/main.lua`
- Modify: `plugins/oblsk_character-selection/client/main.lua`

**Interfaces:**
- Consumes: `Appearance.HAIR_STYLES` (Task 1), `CharacterAppearanceService.apply` (existing,
  `client/services/CharacterAppearanceService.lua:11`)
- Produces: server export `getHairStyles(gender) -> table[]` (same shape as
  `Appearance.HAIR_STYLES[gender]`); client export
  `applyAppearance(ped, appearance, gender)` (thin wrapper, no return value)

- [ ] **Step 1: Declare both exports in the manifest**

In `plugins/oblsk_character-selection/fxmanifest.lua`, add after the
`dependencies` block:

```lua
exports {
    'getHairStyles'
}

client_exports {
    'applyAppearance'
}
```

- [ ] **Step 2: Add the server export**

At the end of `plugins/oblsk_character-selection/server/main.lua`, before
the final `print('[oblsk_character-selection] Loaded successfully!')` line:

```lua
--- @param gender string 'male' | 'female'
--- @return table[] Appearance.HAIR_STYLES[gender], or the male list if gender is neither
exports('getHairStyles', function(gender)
    gender = gender == 'female' and 'female' or 'male'
    return Appearance.HAIR_STYLES[gender]
end)
```

- [ ] **Step 3: Add the client export**

At the end of `plugins/oblsk_character-selection/client/main.lua`, before
the final `print('[oblsk_character-selection] Client loaded successfully!')`
line:

```lua
--- @param ped number
--- @param appearance table shaped per Appearance.DEFAULT_APPEARANCE
--- @param gender string 'male' | 'female'
exports('applyAppearance', function(ped, appearance, gender)
    CharacterAppearanceService.apply(ped, appearance, gender)
end)
```

- [ ] **Step 4: Manual verification (no automated test — cross-resource exports aren't callable outside a running FXServer)**

Start the dev server, open the character creator, confirm it still spawns
and previews correctly (exports don't change any existing behavior — they
only add new callable entry points). Note in the PR/commit body that
`getHairStyles`/`applyAppearance` will be exercised for real once
`oblsk_barber` (Task 6) calls them.

- [ ] **Step 5: Commit**

```bash
cd core
git add plugins/oblsk_character-selection/fxmanifest.lua \
        plugins/oblsk_character-selection/server/main.lua \
        plugins/oblsk_character-selection/client/main.lua
git commit -m "feat(character-selection): export getHairStyles/applyAppearance for cross-plugin reuse"
```

---

## Task 3: oblsk_barber plugin scaffold + barber_chairs migration

**Files:**
- Create: `plugins/oblsk_barber/fxmanifest.lua`
- Create: `plugins/oblsk_barber/shared/config.lua`
- Create: `plugins/oblsk_barber/server/migrations.json`
- Create: `plugins/oblsk_barber/server/migrations/2026_08_15_150000_create_barber_chairs_table.lua`
- Test: `plugins/oblsk_barber/tests/barber_chairs_migration_spec.lua`

**Interfaces:**
- Produces: `barber_chairs` table (`id`, `name`, `interaction_id` FK →
  `interactions`, timestamps), `Config.Sections` (array of
  `{ id, label, kind, count, price }` for every non-hair section, copied
  from the design's `BB_SECTIONS` minus the `hair` entry, which now comes
  from `getHairStyles` instead of a static count).

- [ ] **Step 1: fxmanifest**

```lua
fx_version 'cerulean'
games { 'gta5' }

name 'Barber'
author ''
version '1.0.0'

dependencies {
    'obelisk',
    'oblsk_character-selection'
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

files {
    'web/*.vue',
    'web/routes.js',
    'web/globalElements.js',
}
```

- [ ] **Step 2: shared/config.lua**

```lua
Config = {}

-- Non-hair sections: hair itself comes from
-- exports['oblsk_character-selection']:getHairStyles(gender) (see
-- client/main.lua), real per-gender counts. Everything below keeps the
-- design prototype's original counts/prices -- no external data source was
-- given for these catalogs.
Config.Sections = {
    { id = 'haircol',  label = 'Hair Color',        kind = 'colour', count = 24, price = 55 },
    { id = 'hl',       label = 'Hair Highlight',     kind = 'colour', count = 24, price = 40 },
    { id = 'beard',    label = 'Beard',              kind = 'style',  count = 28, price = 70 },
    { id = 'beardcol', label = 'Beard Color',        kind = 'colour', count = 24, price = 35 },
    { id = 'brows',    label = 'Eyebrows',           kind = 'style',  count = 34, price = 40 },
    { id = 'browcol',  label = 'Eyebrow Color',      kind = 'colour', count = 24, price = 30 },
    { id = 'chest',    label = 'Chest Hair',         kind = 'style',  count = 16, price = 50 },
    { id = 'chestcol', label = 'Chest Hair Color',   kind = 'colour', count = 24, price = 30 },
    { id = 'makeup',   label = 'Makeup',             kind = 'style',  count = 14, price = 65 },
    { id = 'blush',    label = 'Blusher',            kind = 'colour', count = 12, price = 30 },
    { id = 'lipstick', label = 'Lipstick',           kind = 'colour', count = 12, price = 30 },
}

-- Price for the hair (style) section, since it no longer carries its own
-- `count` here (real per-gender counts come from getHairStyles).
Config.HairPrice = 95

return Config
```

- [ ] **Step 3: migrations.json**

```json
{
  "migrations": [
    "2026_08_15_150000_create_barber_chairs_table"
  ]
}
```

- [ ] **Step 4: Write the migration**

```lua
--- Migration: Create barber_chairs table
--- One row per physical barber chair, same interaction-FK shape as
--- cardealer_shops/tuner_shops.
return {
    up = function()
        Schema.create('barber_chairs', function(table)
            table:id()
            table:string('name', 100)
            table:foreignId('interaction_id'):constrained('interactions'):onDelete('CASCADE')
            table:timestamps()

            table:unique('interaction_id')
        end)

        print('[Migration] Created barber_chairs table')
    end,

    down = function()
        Schema.drop('barber_chairs')
        print('[Migration] Dropped barber_chairs table')
    end
}
```

- [ ] **Step 5: Write the migration test (exact same harness shape as `oblsk_shop/tests/shops_migration_spec.lua`: load the real ORM chain, capture the SQL `Database.querySync` receives, assert on substrings — this codebase has no fake-schema introspection helper, so migration tests check the generated SQL text, not a column registry)**

```lua
-- plugins/oblsk_barber/tests/barber_chairs_migration_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_barber/tests/barber_chairs_migration_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/Schema.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function contains(haystack, needle, msg)
    if not haystack:lower():find(needle:lower(), 1, true) then
        error((msg or 'expected substring not found') .. '\n  looking for: ' .. needle .. '\n  in: ' .. haystack, 2)
    end
end

local function captureStatements(fn)
    local statements = {}
    local original = Database.querySync
    Database.querySync = function(sql, params)
        table.insert(statements, sql)
        return {}
    end
    fn()
    Database.querySync = original
    return statements
end

test('barber_chairs migration creates the table with an interaction_id FK', function()
    local migration = dofile(scriptDir .. '../server/migrations/2026_08_15_150000_create_barber_chairs_table.lua')
    local statements = captureStatements(migration.up)
    local sql = table.concat(statements, '\n')
    contains(sql, 'barber_chairs')
    contains(sql, 'interaction_id')
    contains(sql, 'name')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        table.insert(failures, { name = t.name, err = err })
        print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 6: Run it, confirm PASS**

Run: `lua5.4 core/plugins/oblsk_barber/tests/barber_chairs_migration_spec.lua`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd core
git add plugins/oblsk_barber
git commit -m "feat(barber): scaffold plugin, barber_chairs migration"
```

---

## Task 4: BarberService — pricing, charge, appearance persistence

**Files:**
- Create: `plugins/oblsk_barber/server/services/BarberService.lua`
- Test: `plugins/oblsk_barber/tests/barber_service_spec.lua`

**Interfaces:**
- Consumes: `Config.Sections`, `Config.HairPrice` (Task 3); `ItemService.binding`/`has`/`remove`,
  `BankingService.charge` (existing, same signatures `ShopService.purchase` uses); `CharacterAppearance`
  model (existing, `core/modules/oblsk_characters/server/models/CharacterAppearance.lua`, global to
  every resource); `CharacterService.getActiveCharacterId(source)` (existing)
- Produces: `BarberService.priceFor(sectionId)`, `BarberService.total(touchedSectionIds)`,
  `BarberService.charge(source, touchedSectionIds, method, cardId)`,
  `BarberService.applyAndPersist(source, gender, appearanceChanges)`

- [ ] **Step 1: Write the failing tests**

`applyAndPersist` reads/writes the real `CharacterAppearance` model (for its
JSON-cast `data` column, same reasoning `CharacterSelectionService` documents
at `server/services/CharacterSelectionService.lua:10-15`), so this spec needs
the same full ORM + model load order
`character_selection_service_spec.lua` uses, plus `TerminalService`-style
fake `ItemService`/`BankingService`/`CharacterService` stubs for the charge
half:

```lua
-- plugins/oblsk_barber/tests/barber_service_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_barber/tests/barber_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'
local CHAR_MODULE = scriptDir .. '../../../modules/oblsk_characters'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/shared/Obelisk.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/Schema.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(ROOT .. '/core/server/Services/PermissionService.lua')
dofile(ROOT .. '/core/server/Traits/HasPermissions.lua')
dofile(CHAR_MODULE .. '/server/models/Character.lua')
dofile(CHAR_MODULE .. '/server/models/CharacterAppearance.lua')

local makeFakeQueryBuilderModule = dofile(CHAR_MODULE .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../shared/config.lua')

-- ItemService/BankingService/CharacterService stubs, same shape
-- terminal_service_spec.lua uses.
ITEM_HAS_CASH = true
ItemService = {}
function ItemService.binding(key)
    if key == 'currency.cash' then return { id = 1 } end
    return nil
end
function ItemService.has(source, item, amount) return ITEM_HAS_CASH end
function ItemService.remove(source, item, amount) return ITEM_HAS_CASH, ITEM_HAS_CASH and nil or 'Not enough cash' end

BANKING_CHARGE_RESULT = { ok = true }
BankingService = {}
function BankingService.charge(source, cardId, amount, description)
    return BANKING_CHARGE_RESULT.ok, BANKING_CHARGE_RESULT.reason
end

CharacterService = {}
function CharacterService.getActiveCharacterId(source)
    if source == 1 then return 100 end
    return nil
end

dofile(scriptDir .. '../server/services/BarberService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s', msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected a truthy value', 2) end end

local function withFakeDb(fn)
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule({
        character_appearances = { { id = 1, character_id = 100, ped_model = 'mp_m_freemode_01', data = json.encode({ hairStyle = 0 }) } },
    })
    ITEM_HAS_CASH = true
    BANKING_CHARGE_RESULT = { ok = true }
    local ok, err = pcall(fn)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('priceFor returns the configured price for hair and for a non-hair section', function()
    eq(BarberService.priceFor('hair'), Config.HairPrice)
    eq(BarberService.priceFor('beard'), 70)
end)

test('priceFor returns nil for an unknown section id', function()
    eq(BarberService.priceFor('not-a-section'), nil)
end)

test('total sums only the touched sections, ignoring unknown ids', function()
    local total = BarberService.total({ 'hair', 'beard', 'not-a-section' })
    eq(total, Config.HairPrice + 70)
end)

test('total is 0 for an empty selection', function()
    eq(BarberService.total({}), 0)
end)

test('charge rejects an empty selection', function()
    withFakeDb(function()
        local ok, reason = BarberService.charge(1, {}, 'cash', nil)
        eq(ok, false)
        eq(reason, 'Nothing to charge')
    end)
end)

test('charge succeeds via cash and removes the right amount', function()
    withFakeDb(function()
        local ok, total = BarberService.charge(1, { 'hair', 'beard' }, 'cash', nil)
        eq(ok, true)
        eq(total, Config.HairPrice + 70)
    end)
end)

test('charge fails via cash when the player does not have enough', function()
    withFakeDb(function()
        ITEM_HAS_CASH = false
        local ok, reason = BarberService.charge(1, { 'hair' }, 'cash', nil)
        eq(ok, false)
        eq(reason, 'Not enough cash')
    end)
end)

test('charge succeeds via card', function()
    withFakeDb(function()
        local ok, total = BarberService.charge(1, { 'hair' }, 'card', 42)
        eq(ok, true)
        eq(total, Config.HairPrice)
    end)
end)

test('charge fails via card when BankingService.charge declines', function()
    withFakeDb(function()
        BANKING_CHARGE_RESULT = { ok = false, reason = 'Card declined' }
        local ok, reason = BarberService.charge(1, { 'hair' }, 'card', 42)
        eq(ok, false)
        eq(reason, 'Card declined')
    end)
end)

test('charge rejects an unknown payment method', function()
    withFakeDb(function()
        local ok, reason = BarberService.charge(1, { 'hair' }, 'crypto', nil)
        eq(ok, false)
        eq(reason, 'Unknown payment method')
    end)
end)

test('applyAndPersist merges the given keys into the existing appearance row', function()
    withFakeDb(function()
        local ok, resolved = BarberService.applyAndPersist(1, 'male', { hairStyle = 12, hairColor = 3 })
        eq(ok, true)
        eq(resolved.hairStyle, 12)
        eq(resolved.hairColor, 3)
    end)
end)

test('applyAndPersist fails when the source has no active character', function()
    withFakeDb(function()
        local ok, reason = BarberService.applyAndPersist(999, 'male', { hairStyle = 12 })
        eq(ok, false)
        eq(reason, 'No active character')
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        table.insert(failures, { name = t.name, err = err })
        print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: Run to confirm it fails**

Run: `lua5.4 core/plugins/oblsk_barber/tests/barber_service_spec.lua`
Expected: FAIL — `BarberService` is nil (file doesn't exist yet).

- [ ] **Step 3: Implement BarberService.lua**

```lua
--- BarberService - pricing, charge, and appearance-persistence logic for
--- oblsk_barber. Split from server/main.lua so it's testable headless, same
--- convention as ShopService/TerminalService.
BarberService = {}

--- @param sectionId string
--- @return number|nil price, nil if sectionId is neither 'hair' nor a Config.Sections entry
function BarberService.priceFor(sectionId)
    if sectionId == 'hair' then
        return Config.HairPrice
    end
    for _, section in ipairs(Config.Sections) do
        if section.id == sectionId then
            return section.price
        end
    end
    return nil
end

--- @param touchedSectionIds string[]
--- @return number total, unknown ids contribute 0
function BarberService.total(touchedSectionIds)
    local total = 0
    for _, id in ipairs(touchedSectionIds) do
        total = total + (BarberService.priceFor(id) or 0)
    end
    return total
end

--- @param source number
--- @param touchedSectionIds string[]
--- @param method string 'cash'|'card'
--- @param cardId number|nil required when method == 'card'
--- @return boolean ok
--- @return number|string totalOrReason total charged on success, reason string on failure
function BarberService.charge(source, touchedSectionIds, method, cardId)
    local total = BarberService.total(touchedSectionIds)
    if total <= 0 then
        return false, 'Nothing to charge'
    end

    if method == 'cash' then
        local cash = ItemService.binding('currency.cash')
        if not cash then
            return false, 'Cash purchases are not available on this server'
        end
        local cashAmount = math.floor(total + 0.5)
        if not ItemService.has(source, cash, cashAmount) then
            return false, 'Not enough cash'
        end
        local removed, removeReason = ItemService.remove(source, cash, cashAmount)
        if not removed then
            return false, removeReason
        end
    elseif method == 'card' then
        local charged, chargeReason = BankingService.charge(source, cardId, total, 'Barber shop')
        if not charged then
            return false, chargeReason
        end
    else
        return false, 'Unknown payment method'
    end

    return true, total
end

--- Merges the given appearance keys into the active character's
--- character_appearances.data row and returns the fully resolved appearance
--- so the caller can also apply it to the live ped.
--- @param source number
--- @param gender string 'male' | 'female'
--- @param appearanceChanges table partial appearance keys to merge, e.g.
---   { hairStyle = 4, hairColor = 2, hairHighlight = 2 }
--- @return boolean ok
--- @return table|string resolvedAppearanceOrReason
function BarberService.applyAndPersist(source, gender, appearanceChanges)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return false, 'No active character'
    end

    local row = CharacterAppearance:where('character_id', characterId):firstSync()
    if not row then
        return false, 'No appearance row for this character'
    end
    local appearanceModel = CharacterAppearance:newFromQuery(row)

    local data = appearanceModel.attributes.data or {}
    for key, value in pairs(appearanceChanges) do
        data[key] = value
    end
    appearanceModel.attributes.data = data
    appearanceModel:saveSync()

    return true, data
end

return BarberService
```

- [ ] **Step 4: Run to confirm all tests pass**

Run: `lua5.4 core/plugins/oblsk_barber/tests/barber_service_spec.lua`
Expected: PASS, all 12 tests.

- [ ] **Step 5: Commit**

```bash
cd core
git add plugins/oblsk_barber/server/services/BarberService.lua plugins/oblsk_barber/tests/barber_service_spec.lua
git commit -m "feat(barber): BarberService pricing, charge, and appearance persistence"
```

---

## Task 5: server/main.lua — interaction registration + event wiring

**Files:**
- Create: `plugins/oblsk_barber/server/main.lua`

**Interfaces:**
- Consumes: `BarberService.charge`, `BarberService.applyAndPersist` (Task 4);
  `InteractionService.register`, `ActionService.register`, `WebView.openPage`, `WebView.focus`,
  `Obelisk.onServer`/`emitClient`, `QueryBuilder`, `NotificationService.notify` (all existing,
  same shape as `oblsk_cardealer/server/main.lua`)
- Produces: server events `barber:client:charge` (in), `barber:server:chargeResult` (out)

- [ ] **Step 1: Implement**

```lua
--- Barber Plugin - Server Main
print('[Barber] Loading...')

local function openForSource(source, chairId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end

    WebView.openPage(source, '/Barber')
    WebView.focus(source)
    Obelisk.emitClient('barber:server:sync', source, { chairId = chairId, sections = Config.Sections, hairPrice = Config.HairPrice })
end

ActionService.register('barber:open', function(source, data)
    local chairId = data and data.interaction and data.interaction.options and data.interaction.options.chairId
    if not chairId then return end
    openForSource(source, chairId)
end, { label = 'Sit in the chair' })

--- Registers every barber chair's interaction point.
--- Must be called exactly once, at boot — InteractionService.register does
--- NOT deduplicate, it allocates a fresh interaction id on every call.
local function registerAllChairs()
    local chairs = QueryBuilder.new('barber_chairs'):getSync()
    for _, chair in ipairs(chairs) do
        local interaction = QueryBuilder.new('interactions'):where('id', chair.interaction_id):firstSync()
        if interaction then
            InteractionService.register({
                x = interaction.x, y = interaction.y, z = interaction.z,
                range = interaction.range, label = interaction.label or chair.name,
                action = 'barber:open',
                options = { chairId = chair.id },
            })
        end
    end
end

local function notifyFailure(source, reason)
    NotificationService.notify(source, {
        type = 'error',
        title = 'Barber',
        description = reason or 'Could not complete the cut',
    })
end

--- @param touchedSectionIds string[]
--- @param method string 'cash'|'card'
--- @param cardId number|nil
--- @param gender string
--- @param appearanceChanges table
Obelisk.onServer('barber:client:charge', function(touchedSectionIds, method, cardId, gender, appearanceChanges)
    local source = source
    local ok, totalOrReason = BarberService.charge(source, touchedSectionIds, method, cardId)
    if not ok then
        notifyFailure(source, totalOrReason)
        Obelisk.emitClient('barber:server:chargeResult', source, { ok = false })
        return
    end

    local persisted, resolvedOrReason = BarberService.applyAndPersist(source, gender, appearanceChanges)
    if not persisted then
        notifyFailure(source, resolvedOrReason)
        Obelisk.emitClient('barber:server:chargeResult', source, { ok = false })
        return
    end

    Obelisk.emitClient('barber:server:chargeResult', source, { ok = true, total = totalOrReason, appearance = resolvedOrReason })
end)

--- Owned/no-charge cut: skips BarberService.charge, still persists.
Obelisk.onServer('barber:client:applyFree', function(gender, appearanceChanges)
    local source = source
    local persisted, resolvedOrReason = BarberService.applyAndPersist(source, gender, appearanceChanges)
    if not persisted then
        notifyFailure(source, resolvedOrReason)
        Obelisk.emitClient('barber:server:chargeResult', source, { ok = false })
        return
    end
    Obelisk.emitClient('barber:server:chargeResult', source, { ok = true, total = 0, appearance = resolvedOrReason })
end)

registerAllChairs()

print('[Barber] Loaded successfully!')
```

- [ ] **Step 2: Manual verification (no automated test — InteractionService/WebView/Obelisk are FXServer-only globals, same posture as every other plugin's main.lua)**

Insert a test `barber_chairs` row + matching `interactions` row (or via
whatever admin/seed tool the rest of the framework uses for placing
interactions — check `oblsk_cardealer`'s README/seeder for the exact
convention), start the dev server, confirm the world prompt appears at that
location and interacting opens the `/Barber` page.

- [ ] **Step 3: Commit**

```bash
cd core
git add plugins/oblsk_barber/server/main.lua
git commit -m "feat(barber): interaction registration and charge event wiring"
```

---

## Task 6: client/main.lua — catalog fetch, live preview, purchase relay

**Files:**
- Create: `plugins/oblsk_barber/client/main.lua`

**Interfaces:**
- Consumes: `exports['oblsk_character-selection']:getHairStyles(gender)`,
  `exports['oblsk_character-selection']:applyAppearance(ped, appearance, gender)` (Task 2);
  `WebView.on`/`emit`/`emitServer`, `Obelisk.onClient` (existing)
- Produces: NUI events `barber:sync` (hair catalog + sections), `barber:chargeResult` (relay)

- [ ] **Step 1: Implement**

```lua
-- plugins/oblsk_barber/client/main.lua
--- Barber Plugin - Client Main
print('[Barber] Client loading...')

local currentGender = 'male'
local currentChairId = nil

--- @return string 'male' | 'female' — best-effort guess from the player's
---   current ped model; oblsk_character-selection doesn't expose the
---   active character's stored gender directly, so this reads it off the
---   live ped the same way CharacterAppearanceService callers already do.
local function currentPlayerGender()
    local model = GetEntityModel(PlayerPedId())
    return model == GetHashKey('mp_f_freemode_01') and 'female' or 'male'
end

Obelisk.onClient('barber:server:sync', function(data)
    currentChairId = data.chairId
    currentGender = currentPlayerGender()
    local hairStyles = exports['oblsk_character-selection']:getHairStyles(currentGender)
    WebView.emit('barber:sync', {
        chairId = data.chairId,
        gender = currentGender,
        hairStyles = hairStyles,
        sections = data.sections,
        hairPrice = data.hairPrice,
    })
end)

Obelisk.onClient('barber:server:chargeResult', function(result)
    WebView.emit('barber:chargeResult', result)
end)

--- Live preview as the player picks a style in the UI, before paying.
--- @param data table { appearance table partial keys }
WebView.on('barber:preview', function(data)
    local ped = PlayerPedId()
    local Appearance = exports['oblsk_character-selection']
    -- getHairStyles above already gave the UI real drawables/labels; the UI
    -- sends back a full appearance-shaped partial (native-valued, not
    -- preset indices) so this can apply it directly without re-resolving.
    local current = data.appearance or {}
    exports['oblsk_character-selection']:applyAppearance(ped, current, currentGender)
end)

WebView.on('barber:charge', function(data)
    WebView.emitServer('barber:client:charge', data.touchedSectionIds, data.method, data.cardId, currentGender, data.appearanceChanges)
end)

WebView.on('barber:applyFree', function(data)
    WebView.emitServer('barber:client:applyFree', currentGender, data.appearanceChanges)
end)

print('[Barber] Client loaded successfully!')
```

- [ ] **Step 2: Manual verification (no automated test — GTA natives and `exports[...]` cross-resource calls aren't stubbed headless, same posture as `CharacterAppearanceService`)**

With Task 5's test chair in place, open the barber NUI, confirm the browser
console shows `barber:sync` firing with a `hairStyles` array of the correct
length for the player's gender (83 for a male ped, 81 for a female ped).

- [ ] **Step 3: Commit**

```bash
cd core
git add plugins/oblsk_barber/client/main.lua
git commit -m "feat(barber): client catalog fetch, live preview, purchase relay"
```

---

## Task 7: Barber.vue — port the design UI with real hair thumbnails

**Files:**
- Create: `plugins/oblsk_barber/web/Barber.vue`

**Interfaces:**
- Consumes: `Obelisk.on('barber:sync', ...)`, `Obelisk.on('barber:chargeResult', ...)`,
  `Obelisk.emit('barber:preview'/'barber:charge'/'barber:applyFree', ...)`,
  `inject('obelisk:payment')` (existing global picker, same as `TerminalPay.vue`)
- Produces: the barber shop screen

- [ ] **Step 1: Port `BarberUI` from the design (`src/proto/barber.jsx`, already fetched) to a Vue 3 SFC**

Follow the same JSX→Vue porting convention every prior plugin in this
session used (`ref`/`reactive` for the JSX `useState` calls, `<script setup>`,
Tailwind classes carried over as-is since the design already uses Tailwind
CDN utility classes matching this project's build). Two required
deviations from the design source:

1. **Hair section**: replace the abstract `<BbTile>` SVG grid for the
   `hair` section with real thumbnails. The section's tile button becomes:

```vue
<button
  v-for="style in hairStyles"
  :key="style.drawable"
  @click="pickHair(style)"
  class="relative rounded-[5px] p-1 transition"
  :style="{
    background: picks.hair === style.drawable ? 'color-mix(in oklab, var(--ob-accent) 12%, #0a0d0c)' : '#0a0d0c',
    border: `1px solid ${picks.hair === style.drawable ? 'var(--ob-accent)' : 'rgba(255,255,255,.09)'}`,
    height: '92px',
  }"
>
  <img :src="`assets/hair/${gender}/${style.drawable}.jpg`" :alt="style.label" class="w-full h-full object-cover rounded-[4px]" />
  <span
    class="absolute bottom-1 right-1.5 ob-mono text-[10px]"
    :style="{ color: picks.hair === style.drawable ? 'var(--ob-accent)' : 'rgba(255,255,255,.55)' }"
  >{{ style.drawable }}</span>
</button>
```

   with `hairStyles` and `gender` populated from the `barber:sync` payload
   (Task 6), and `pickHair(style)` setting `picks.hair = style.drawable`,
   marking `touched.hair = true`, and emitting `barber:preview` with
   `{ appearance: { hairStyle: style.drawable } }`.

2. **Payment**: drop the design's inline card-picker markup (the
   `CARDS.map(...)` block and its hover-preview tooltips) entirely. Keep
   the CASH/CARD method buttons, but wire CARD to the shared picker:

```js
import { inject } from 'vue'
const payment = inject('obelisk:payment')

async function payByCard() {
  const result = await payment.requestPayment({ amount: total.value, description: 'Barber shop' })
  if (!result.ok) return
  emitCharge('card', result.cardId)
}

function payByCash() {
  emitCharge('cash', null)
}

function emitCharge(method, cardId) {
  Obelisk.emit('barber:charge', {
    touchedSectionIds: Object.keys(touched.value),
    method,
    cardId,
    appearanceChanges: appearanceChangesFromTouched(),
  })
}
```

   (`appearanceChangesFromTouched()` builds the partial appearance object
   from whichever sections were touched — `hairStyle` from `picks.hair`,
   `hairColor`/`hairHighlight` from the hair-color/highlight sections'
   picked swatch index mapped through the same curated `Appearance.HAIR_COLORS`
   shape the character creator uses, etc. — same mapping the design's
   `cols`/`picks` state already tracks, just serialized before emitting
   instead of applied to native ped calls directly, since that now happens
   server-round-trip via Task 5/6.)

All other sections (color grids, beard/brows/etc, the footer "Pay"/"Cut it"
button, the receipt sheet, `owned`/`SHOP MODE` toggle, ESC-to-leave hint)
port over unchanged from the design.

- [ ] **Step 2: Manual verification (Vue SFCs aren't unit-tested in this codebase — every prior plugin verified visually; see `run` skill)**

Run the project's dev server / NUI preview (check for an existing
`pages/barber.html`-equivalent local preview harness, or run the real
FXServer dev flow), open the barber screen for both a male and a female
character, confirm:
- the hair grid shows real photos (not blank/broken images) for both
  genders, with the correct counts (83 / 81)
- clicking a hair tile live-previews on the player ped
- CASH pays immediately; CARD opens the existing card picker and completes
  a charge
- the receipt sheet shows after a successful cut

- [ ] **Step 3: Commit**

```bash
cd core
git add plugins/oblsk_barber/web/Barber.vue
git commit -m "feat(barber): port BarberUI with real hair thumbnails and shared payment picker"
```

---

## Task 8: BarberClipperGame.vue — port the minigame

**Files:**
- Create: `plugins/oblsk_barber/web/BarberClipperGame.vue`
- Modify: `plugins/oblsk_barber/web/Barber.vue` (mount the minigame between "Pay" and the charge event)

**Interfaces:**
- Consumes: nothing external (self-contained, same as the design's `BbClipperGame`)
- Produces: emits `done({ q, grade, mult })` / `cancel()` to the parent

- [ ] **Step 1: Port `BbClipperGame` (`src/proto/barber-game.jsx`, already fetched) 1:1 to a Vue 3 SFC**

Same porting convention as Task 7 — `requestAnimationFrame` loop becomes a
`ref` updated in an `onMounted` RAF loop, cleaned up in `onBeforeUnmount`;
`useState` becomes `ref`; keydown listener (`Space`/`Enter` to lock)
attaches in `onMounted`/detaches in `onBeforeUnmount`. Props: `label`,
`price`, `free`. Emits: `done` (payload `{ q, grade, mult }`), `cancel`.

- [ ] **Step 2: Wire it into Barber.vue's flow**

Where the design calls `setGame({ label, price })` after "Pay"/"Cut it" is
pressed (before the charge event fires), mount
`<BarberClipperGame v-if="game" ... @done="onGameDone" @cancel="game = null" />`,
and move the actual `barber:charge`/`barber:applyFree` emit from Task 7's
`payByCard`/`payByCash` into `onGameDone`, applying the minigame's `mult`
to the charged price (mirroring the design's `Math.round(game.price * res.mult)`
discount-for-a-bad-cut behavior) — for the multi-section case here, apply
`mult` to the running total the same way, not per-section.

- [ ] **Step 3: Manual verification**

Trigger a cut, confirm the clipper minigame appears, run all three passes,
confirm a bad result discounts the charged total and a good result charges
in full.

- [ ] **Step 4: Commit**

```bash
cd core
git add plugins/oblsk_barber/web/BarberClipperGame.vue plugins/oblsk_barber/web/Barber.vue
git commit -m "feat(barber): port clipper-precision minigame"
```

---

## Task 9: Wire into the framework — routes, registry, README

**Files:**
- Create: `plugins/oblsk_barber/web/routes.js`
- Create: `plugins/oblsk_barber/web/globalElements.js`
- Create: `plugins/oblsk_barber/README.md`
- Modify: `plugins/registry.json`

**Interfaces:** none new — this task only registers what Tasks 1-8 built.

- [ ] **Step 1: routes.js**

```js
// plugins/oblsk_barber/web/routes.js
export default [
  {
    path: '/Barber',
    name: 'Barber',
    component: () => import('./Barber.vue')
  }
]
```

- [ ] **Step 2: globalElements.js**

```js
// plugins/oblsk_barber/web/globalElements.js
export default []
```

(Barber has no always-mounted headless component like `TerminalPay.vue` —
it's opened directly via `WebView.openPage('/Barber')`, not targeted by
another player, so an empty array is correct. If this project's build
tooling errors on an empty `globalElements.js`, check
`oblsk_cardealer/web/globalElements.js` for how a plugin with no global
elements actually declares that and match it exactly instead.)

- [ ] **Step 3: README.md**

```markdown
# oblsk_barber

Barber-chair shop plugin: hair/hair color/highlight/beard/beard
color/eyebrows/eyebrow color/chest hair/chest hair color/makeup/blush/
lipstick, paid cash or card, gated behind a clipper-precision minigame.

Hair style data (83 male / 81 female GTA V drawables, with thumbnails) is
owned by `oblsk_character-selection` (`shared/appearance.lua`'s
`Appearance.HAIR_STYLES`) and consumed here via its `getHairStyles`/
`applyAppearance` exports — this plugin depends on
`oblsk_character-selection` (see `fxmanifest.lua`) and does not keep its
own copy of the hair catalog.

See `docs/superpowers/specs/2026-08-15-barber-plugin-design.md` for the
full design.

## Placing a chair

Insert an `interactions` row at the desired coords, then a `barber_chairs`
row referencing it via `interaction_id` (see `server/migrations/
2026_08_15_150000_create_barber_chairs_table.lua`). Chairs register their
world prompt on server boot (`registerAllChairs()` in `server/main.lua`).
```

- [ ] **Step 4: Register the plugin**

In `plugins/registry.json`, add `"oblsk_barber"` to the `plugins` array
(alphabetical position doesn't matter — the existing list isn't sorted;
match wherever the array is, e.g. right after `"oblsk_banking"`).

- [ ] **Step 5: Commit**

```bash
cd core
git add plugins/oblsk_barber/web/routes.js plugins/oblsk_barber/web/globalElements.js \
        plugins/oblsk_barber/README.md plugins/registry.json
git commit -m "feat(barber): register plugin, routes, README"
```

---

## Task 10: Whole-plugin verification pass

**Files:** none (verification only)

- [ ] **Step 1: Run every new/changed Lua test file**

```bash
lua5.4 core/plugins/oblsk_character-selection/tests/appearance_spec.lua
lua5.4 core/plugins/oblsk_barber/tests/barber_chairs_migration_spec.lua
lua5.4 core/plugins/oblsk_barber/tests/barber_service_spec.lua
```

Expected: all PASS.

- [ ] **Step 2: Lua syntax check every new/modified file**

```bash
for f in $(git -C core diff --name-only HEAD~9 -- '*.lua'); do
  luac5.4 -p "core/$f" || echo "SYNTAX ERROR: $f"
done
```

(Adjust `HEAD~9` if the commit count from Tasks 1-9 differs from 9 — count
actual commits made and use that.)

- [ ] **Step 3: Full manual playtest**

Start the dev server (see the `run` skill if one is configured for this
project), place a test barber chair, and walk through: open shop as a male
character, pick a real hair style, preview updates live, pay cash, confirm
persistence by relogging; repeat as a female character to confirm the
81-style female catalog loads; confirm a card payment and a below-70%
clipper result (discount applied) each work once.

- [ ] **Step 4: Update the design spec's "Known limitations" section if anything changed during implementation**

If any deviation from the spec was needed (e.g. the fake-schema/fake-query
helper paths guessed in Tasks 3/4 turned out different, or the minigame
discount math needed adjusting for the multi-section total), add a short
note to `core/docs/superpowers/specs/2026-08-15-barber-plugin-design.md`'s
limitations section and commit it.

```bash
cd core
git add docs/superpowers/specs/2026-08-15-barber-plugin-design.md
git commit -m "docs(barber): note implementation deviations from the design spec" --allow-empty
```
