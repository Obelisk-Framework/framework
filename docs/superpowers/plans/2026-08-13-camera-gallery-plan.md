# Camera + Gallery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add built-in Camera and Gallery apps to `oblsk_phone` — real photo/short-video capture via the `screencapture` resource, uploaded through the core storage service, organized into albums, with delete and "send to a Messages conversation."

**Architecture:** Camera and Gallery are built-in `oblsk_phone` apps (same pattern as Messages — own service, own migrations, own Vue component, registered in `PhoneAppRegistry.CATALOG`), not a separate plugin. `CameraService` drives `screencapture`'s server-side exports (`remoteUpload`/`startVideoCaptureUpload`), uploading straight to the core storage service's own HTTP endpoint using a server-minted, single-use token passed via a header (never exposed to the client). `GalleryService` owns albums/media CRUD and the Messages-attach action, reusing the existing `ShareSheet.vue` thread-picker component.

**Tech Stack:** Lua 5.4 (FXServer), Vue 3, hand-rolled `lua5.4 tests/*_spec.lua` test runner, this repo's `QueryBuilder`/`Schema` ORM.

**Spec:** `docs/superpowers/specs/2026-08-13-camera-gallery-design.md`

## Global Constraints

- No third-party Lua libraries — FXServer's Lua 5.4 sandbox only.
- Every character-owned row (`phone_albums`, `phone_media`) is scoped by `owner_character_id`, matching Messages' character-scoped ownership convention.
- `screencapture`'s server-side exports (`remoteUpload`, `startVideoCaptureUpload`, `stopVideoCapture`) are the only capture path used — never the client-side `requestScreenshotUpload` export, which `screencapture`'s own docs flag as exposing the upload token to the client.
- Upload auth travels via the `X-Storage-Token` header (server-minted, single-use, short-lived via `Storage.mintUploadToken`/`consumeUploadToken`), never a client-visible token.
- Quota: `phone_gallery_max_items` convar (default 200), enforced per-character across all albums.
- Video: hard-capped at 15 seconds server-side regardless of client behavior; a `screencapture` result with `status ~= 'success'` or `bytesReceived == 0` is treated as a failed capture, never a broken/empty `phone_media` row.
- Test files load stubs first via `dofile(scriptDir .. 'support/fivem_stubs.lua')` (or the phone plugin's own `tests/support/fake_query_builder.lua` for service-level tests), then `dofile` the source files under test, in dependency order — matching every existing spec in this repo.

---

### Task 1: Storage service extensions + screencapture dependency wiring

**Files:**
- Modify: `core/server/Services/StorageService.lua`
- Modify: `core/server/Services/storage/upload_handler.lua`
- Modify: `core/fxmanifest.lua`
- Modify: `<repo-root>/server.cfg.example`, `<repo-root>/server.cfg` (the top-level `obelisk-framework` repo, one level above this `core` worktree — a separate git repository from everything else in this task)
- Test: `tests/storage_service_spec.lua`, `tests/storage_upload_handler_spec.lua`

**Interfaces:**
- Produces: `Storage.uploadUrl()` → absolute URL string. This is the URL `CameraService` (Task 5) hands to `screencapture`'s server-side exports.

- [ ] **Step 1: Write the failing tests**

Append to `tests/storage_service_spec.lua` (before the final `for _, t in ipairs(tests) do` loop):

```lua
test('uploadUrl builds an absolute, resource-prefixed URL to the upload endpoint', function()
    local url = Storage.uploadUrl()
    truthy(url:find('http://127.0.0.1:', 1, true), 'expected an absolute http://127.0.0.1:<port> URL')
    truthy(url:find('/storage/upload', 1, true), 'expected the URL to end at /storage/upload')
end)
```

Append to `tests/storage_upload_handler_spec.lua` (before the final `for _, t in ipairs(tests) do` loop):

```lua
test('a valid token via the X-Storage-Token header uploads without a multipart token field', function()
    local token = Storage.mintUploadToken('phone-photos/header-test.jpg', 'image/jpeg')
    local boundary = 'HEADERTOKENBOUNDARY'
    -- Only a files[] part this time - no "token" field in the body at all,
    -- matching screencapture's remoteUpload, which sends exactly one file
    -- field plus custom headers (see docs/superpowers/specs/2026-08-13-
    -- camera-gallery-design.md).
    local body = table.concat({
        '--' .. boundary .. '\r\n',
        'Content-Disposition: form-data; name="files[]"; filename="shot.jpg"\r\n',
        'Content-Type: image/jpeg\r\n\r\n',
        'fake-jpeg-bytes' .. '\r\n',
        '--' .. boundary .. '--\r\n',
    })
    -- Reuses this file's existing fakeResponse() helper; the request table
    -- is built inline (rather than via fakeRequest()) since this test needs
    -- an extra x-storage-token header fakeRequest() doesn't accept.
    local req = {
        path = '/storage/upload',
        headers = {
            ['content-type'] = 'multipart/form-data; boundary=' .. boundary,
            ['x-storage-token'] = token,
        },
        setDataHandler = function(_self, cb) cb(body) end,
    }
    local res = fakeResponse()

    _registeredHttpHandler(req, res)

    eq(res.status, 200)
    truthy(res.body:find('/storage/phone%-photos/header%-test%.jpg'), 'response body should contain the stored url')
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua5.4 tests/storage_service_spec.lua` — expect `attempt to call a nil value (field 'uploadUrl')`.
Run: `lua5.4 tests/storage_upload_handler_spec.lua` — expect the new test's assertion to fail (403, not 200), since there's no header-token fallback yet.

- [ ] **Step 3: Add `Storage.uploadUrl()` to `StorageService.lua`**

Add this function to `core/server/Services/StorageService.lua`, after `Storage.url`:

```lua
--- Builds the absolute URL screencapture's server-side exports (or any
--- other out-of-process uploader) POST to. FXServer mounts a resource's
--- HTTP handler under /<resourceName>/..., and plugins/*/server/**/*.lua
--- loads into the same single resource as core (see fxmanifest.lua's
--- globs), so this resource's own name is always the right prefix no
--- matter which plugin calls this. storage_http_port must match whatever
--- port this server's endpoint_add_tcp/endpoint_add_udp lines in
--- server.cfg actually use (no other convar exposes this).
--- @return string url
function Storage.uploadUrl()
  local port = GetConvarInt('storage_http_port', 30120)
  return string.format('http://127.0.0.1:%d/%s/storage/upload', port, GetCurrentResourceName())
end
```

- [ ] **Step 4: Add the header-based token fallback to `upload_handler.lua`**

In `core/server/Services/storage/upload_handler.lua`, find:

```lua
    local parts = parseMultipart(body, boundary)
    local token = parts.token and parts.token.value
    local pending = token and Storage.consumeUploadToken(token)
```

Replace with:

```lua
    local parts = parseMultipart(body, boundary)
    -- screencapture's remoteUpload/startVideoCaptureUpload exports send
    -- exactly one file field plus custom headers - they cannot add a
    -- second multipart "token" field, so this endpoint also accepts the
    -- token via a header. The multipart-body field stays supported for any
    -- other caller.
    local token = (parts.token and parts.token.value) or req.headers['x-storage-token']
    local pending = token and Storage.consumeUploadToken(token)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `lua5.4 tests/storage_service_spec.lua` — expect `storage_service_spec: 7/7 passed`.
Run: `lua5.4 tests/storage_upload_handler_spec.lua` — expect `storage_upload_handler_spec: 8/8 passed`.

- [ ] **Step 6: Wire `screencapture` as a dependency and add config**

In `core/fxmanifest.lua`, find:

```lua
-- Dependencies
dependencies {
    '/server:5848',
    '/onesync'
}
```

Replace with:

```lua
-- Dependencies
dependencies {
    '/server:5848',
    '/onesync',
    'screencapture'
}
```

In `<repo-root>/server.cfg.example` (the top-level repo, NOT this `core` worktree), add after the existing `storage_s3_*` block:

```
# The port this server's own HTTP endpoint listens on - must match the
# port in endpoint_add_tcp/endpoint_add_udp above. Used by Storage.uploadUrl()
# so in-process resources (like screencapture's server-side upload exports)
# can POST back to this server's own /storage/upload endpoint.
set storage_http_port "30120"
```

And add `ensure screencapture` before `ensure core`:

```
ensure oblsk_connector
ensure screencapture
ensure core
```

Copy the same two edits (`storage_http_port` convar + `ensure screencapture` ordering) into `<repo-root>/server.cfg` (the real, gitignored config file).

- [ ] **Step 7: Run the full suite and commit**

Run: `npm test` — expect every spec to report a full pass count, exit code 0.

```bash
git add core/server/Services/StorageService.lua core/server/Services/storage/upload_handler.lua fxmanifest.lua tests/storage_service_spec.lua tests/storage_upload_handler_spec.lua
git commit -m "feat(storage): add uploadUrl() and header-based upload token, depend on screencapture"
```

The `server.cfg.example`/`server.cfg` edit lives in the top-level `obelisk-framework` repo, a separate git repository from this `core` worktree — commit it there separately:

```bash
git -C <repo-root> add server.cfg.example server.cfg
git -C <repo-root> commit -m "Add storage_http_port config and ensure screencapture for Camera+Gallery"
```

---

### Task 2: Migrations — albums, media, message attachments

**Files:**
- Create: `plugins/oblsk_phone/server/migrations/2026_08_13_120000_create_phone_albums_table.lua`
- Create: `plugins/oblsk_phone/server/migrations/2026_08_13_120001_create_phone_media_table.lua`
- Create: `plugins/oblsk_phone/server/migrations/2026_08_13_120002_add_media_to_phone_messages_table.lua`
- Modify: `plugins/oblsk_phone/server/migrations.json`
- Test: `plugins/oblsk_phone/tests/migrations_audit_spec.lua`

**Interfaces:**
- Produces: `phone_albums` table (`id`, `owner_character_id`, `name`, `is_default`, timestamps). `phone_media` table (`id`, `owner_character_id`, `album_id` FK → `phone_albums.id`, `kind`, `storage_key`, `url`, `duration_seconds` nullable, `taken_at`, timestamps). `phone_messages.media_url`/`phone_messages.media_kind`, both nullable.

- [ ] **Step 1: Write the failing test**

```lua
-- plugins/oblsk_phone/tests/migrations_audit_spec.lua
-- Runs every oblsk_phone migration file's up() against a stubbed
-- Schema/Database and asserts none of them error - mirrors
-- tests/migration_audit_spec.lua, pointed at this plugin's own migrations
-- directory (tests/support/audit_migrations.lua is explicitly designed to
-- be reused this way).
-- Run from the repository root:  lua5.4 plugins/oblsk_phone/tests/migrations_audit_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Schema.lua')

local AuditMigrations = dofile(CORE_ROOT .. '/tests/support/audit_migrations.lua')

local result = AuditMigrations.run(CORE_ROOT .. '/plugins/oblsk_phone/server/migrations')

if #result.failed > 0 then
    print('FAILED migrations:')
    for _, f in ipairs(result.failed) do
        print('  ' .. f.file .. ': ' .. f.error)
    end
    os.exit(1)
end

print(#result.passed .. ' migration files passed audit, 0 failed')
os.exit(0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 plugins/oblsk_phone/tests/migrations_audit_spec.lua`
Expected: currently passes for the existing migrations (none of the new files exist yet, so nothing new is exercised) — this step confirms the harness itself runs cleanly before you add the new files. Note the passed count so you can confirm it grows by exactly 3 in Step 4.

- [ ] **Step 3: Write the three migration files**

```lua
-- plugins/oblsk_phone/server/migrations/2026_08_13_120000_create_phone_albums_table.lua
--- Migration: Create phone_albums table
return {
    up = function()
        Schema.create('phone_albums', function(table)
            table:id()
            table:integer('owner_character_id'):index()
            table:string('name', 100)
            table:boolean('is_default'):default(0)
            table:timestamps()
        end)

        print('[Migration] Created phone_albums table')
    end,

    down = function()
        Schema.drop('phone_albums')
        print('[Migration] Dropped phone_albums table')
    end
}
```

```lua
-- plugins/oblsk_phone/server/migrations/2026_08_13_120001_create_phone_media_table.lua
--- Migration: Create phone_media table
return {
    up = function()
        Schema.create('phone_media', function(table)
            table:id()
            table:integer('owner_character_id'):index()
            table:foreignId('album_id'):constrained('phone_albums', 'id')
            table:string('kind', 10)
            table:string('storage_key', 255)
            table:string('url', 500)
            table:integer('duration_seconds'):nullable()
            table:timestamp('taken_at')
            table:timestamps()
        end)

        print('[Migration] Created phone_media table')
    end,

    down = function()
        Schema.drop('phone_media')
        print('[Migration] Dropped phone_media table')
    end
}
```

```lua
-- plugins/oblsk_phone/server/migrations/2026_08_13_120002_add_media_to_phone_messages_table.lua
--- Migration: Add media_url/media_kind columns to phone_messages table
--- Lets a message carry a photo/video from Gallery's "send to conversation"
--- action instead of (or alongside) text - see MessagesService.send.
return {
    up = function()
        Schema.table('phone_messages', function(table)
            table:string('media_url', 500):nullable()
            table:string('media_kind', 10):nullable()
        end)

        print('[Migration] Added media_url/media_kind columns to phone_messages table')
    end,

    down = function()
        Schema.dropColumn('phone_messages', 'media_url')
        Schema.dropColumn('phone_messages', 'media_kind')
        print('[Migration] Dropped media_url/media_kind columns from phone_messages table')
    end
}
```

- [ ] **Step 4: Register the migrations**

In `plugins/oblsk_phone/server/migrations.json`, append to the `migrations` array (after the last existing entry):

```json
    "2026_08_13_120000_create_phone_albums_table",
    "2026_08_13_120001_create_phone_media_table",
    "2026_08_13_120002_add_media_to_phone_messages_table"
```

(Keep valid JSON — add a comma after the previous last entry.)

- [ ] **Step 5: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_phone/tests/migrations_audit_spec.lua`
Expected: passed count is exactly 3 higher than Step 2's baseline, 0 failed.

- [ ] **Step 6: Add the new spec to `package.json` and run the full suite**

Add `&& lua5.4 plugins/oblsk_phone/tests/migrations_audit_spec.lua` to the end of `package.json`'s `"test"` script (check the file first — do not assume the exact current string, append after whatever the last existing command is).

Run: `npm test` — expect every spec to pass, exit code 0.

- [ ] **Step 7: Commit**

```bash
git add plugins/oblsk_phone/server/migrations/2026_08_13_120000_create_phone_albums_table.lua plugins/oblsk_phone/server/migrations/2026_08_13_120001_create_phone_media_table.lua plugins/oblsk_phone/server/migrations/2026_08_13_120002_add_media_to_phone_messages_table.lua plugins/oblsk_phone/server/migrations.json plugins/oblsk_phone/tests/migrations_audit_spec.lua package.json
git commit -m "feat(phone): add phone_albums/phone_media tables and message attachment columns"
```

---

### Task 3: MessagesService — attachment support

**Files:**
- Modify: `plugins/oblsk_phone/server/services/MessagesService.lua`
- Test: `plugins/oblsk_phone/tests/messages_service_spec.lua`

**Interfaces:**
- Consumes: `phone_messages.media_url`/`media_kind` columns (Task 2).
- Produces: `MessagesService.send(characterId, threadId, body, mediaUrl, mediaKind)` — `mediaUrl`/`mediaKind` are optional (nil for a normal text-only send, exactly matching every existing call site). `GalleryService.sendToConversation` (Task 4) is the first caller to pass them.

- [ ] **Step 1: Write the failing test**

Add to `plugins/oblsk_phone/tests/messages_service_spec.lua` (inside the existing `withFakeDb` test block structure — follow the file's existing pattern of seeding `tables.phone_threads`/`tables.phone_thread_members` for a thread between characters 1 and 2 before calling `MessagesService.send`; match whatever seeding helper the file already uses for its other `send` tests rather than re-deriving one):

```lua
test('send() with no body but a mediaUrl still sends (attachment-only message)', function()
    withFakeDb(function(tables)
        tables.phone_threads = { { id = 1, is_group = false } }
        tables.phone_thread_members = {
            { id = 1, thread_id = 1, character_id = 1 },
            { id = 2, thread_id = 1, character_id = 2 },
        }

        local message = MessagesService.send(1, 1, nil, 'https://example.test/storage/photo.jpg', 'photo')
        truthy(message, 'expected an attachment-only send to succeed')
        eq(message.body, '')
        eq(message.media_url, 'https://example.test/storage/photo.jpg')
        eq(message.media_kind, 'photo')
    end)
end)

test('send() with neither body nor mediaUrl returns nil', function()
    withFakeDb(function(tables)
        tables.phone_threads = { { id = 1, is_group = false } }
        tables.phone_thread_members = {
            { id = 1, thread_id = 1, character_id = 1 },
            { id = 2, thread_id = 1, character_id = 2 },
        }

        local message = MessagesService.send(1, 1, nil, nil, nil)
        eq(message, nil)
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 plugins/oblsk_phone/tests/messages_service_spec.lua`
Expected: FAIL — `send()` currently returns `nil` for a blank/non-string body regardless of any other argument.

- [ ] **Step 3: Update `MessagesService.send`**

In `plugins/oblsk_phone/server/services/MessagesService.lua`, replace the existing `MessagesService.send` function:

```lua
function MessagesService.send(characterId, threadId, body)
    if type(body) ~= 'string' then
        return nil
    end
    local trimmed = body:match('^%s*(.-)%s*$')
    if trimmed == '' then
        return nil
    end
    if not isMember(characterId, threadId) then
        return nil
    end

    local now = Database.now()
    local id = QueryBuilder.new('phone_messages'):insert({
        thread_id = threadId,
        sender_character_id = characterId,
        body = trimmed,
        created_at = now,
        updated_at = now,
    })

    QueryBuilder.new('phone_thread_members')
        :where('thread_id', threadId):where('character_id', characterId)
        :update({ last_read_message_id = id, updated_at = now })
    QueryBuilder.new('phone_threads'):where('id', threadId):update({ updated_at = now })

    return QueryBuilder.new('phone_messages'):where('id', id):firstSync()
end
```

with:

```lua
--- @param characterId number
--- @param threadId number
--- @param body string|nil the message text; may be nil/blank if mediaUrl is set (an attachment-only message)
--- @param mediaUrl string|nil set by GalleryService.sendToConversation for a photo/video attachment
--- @param mediaKind string|nil 'photo'|'video', required alongside mediaUrl
--- @return table|nil message row
function MessagesService.send(characterId, threadId, body, mediaUrl, mediaKind)
    local trimmed = ''
    if type(body) == 'string' then
        trimmed = body:match('^%s*(.-)%s*$')
    end
    if trimmed == '' and not mediaUrl then
        return nil
    end
    if not isMember(characterId, threadId) then
        return nil
    end

    local now = Database.now()
    local id = QueryBuilder.new('phone_messages'):insert({
        thread_id = threadId,
        sender_character_id = characterId,
        body = trimmed,
        media_url = mediaUrl,
        media_kind = mediaKind,
        created_at = now,
        updated_at = now,
    })

    QueryBuilder.new('phone_thread_members')
        :where('thread_id', threadId):where('character_id', characterId)
        :update({ last_read_message_id = id, updated_at = now })
    QueryBuilder.new('phone_threads'):where('id', threadId):update({ updated_at = now })

    return QueryBuilder.new('phone_messages'):where('id', id):firstSync()
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_phone/tests/messages_service_spec.lua`
Expected: full pass count including the 2 new tests, 0 failures. Confirm no prior test broke (a plain-text send still works identically since `mediaUrl`/`mediaKind` default to `nil` when omitted, matching every existing call site).

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_phone/server/services/MessagesService.lua plugins/oblsk_phone/tests/messages_service_spec.lua
git commit -m "feat(phone): let MessagesService.send carry a media attachment"
```

---

### Task 4: GalleryService + net events + app registration

**Files:**
- Create: `plugins/oblsk_phone/server/services/GalleryService.lua`
- Modify: `plugins/oblsk_phone/server/services/PhoneAppRegistry.lua`
- Modify: `plugins/oblsk_phone/server/main.lua`
- Test: `plugins/oblsk_phone/tests/gallery_service_spec.lua`

**Interfaces:**
- Consumes: `Storage.delete` (core), `MessagesService.send` (Task 3).
- Produces: `GalleryService.getDefaultAlbum(characterId)` → album row (creates it if missing). `GalleryService.listAlbums(characterId)` → album rows. `GalleryService.createAlbum(characterId, name)` → album row or nil. `GalleryService.renameAlbum(characterId, albumId, name)` → boolean. `GalleryService.deleteAlbum(characterId, albumId)` → boolean (reassigns contained media to the default album first; refuses to delete the default album itself). `GalleryService.listMedia(characterId, albumId)` → media rows, newest first. `GalleryService.deleteMedia(characterId, mediaId)` → boolean. `GalleryService.sendToConversation(characterId, mediaId, threadId)` → message row or nil, err.

- [ ] **Step 1: Write the failing test**

```lua
-- plugins/oblsk_phone/tests/gallery_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_phone/tests/gallery_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(scriptDir .. '../server/services/PhoneNumberService.lua')
dofile(scriptDir .. '../server/services/MessagesService.lua')
dofile(scriptDir .. '../server/services/GalleryService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected a truthy value', 2) end end

-- Storage.delete is a core global; fake it out so GalleryService.deleteMedia
-- doesn't need a real Storage adapter to be configured.
local deletedKeys = {}
_G.Storage = { delete = function(key) table.insert(deletedKeys, key); return true end }

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('getDefaultAlbum creates a Camera Roll album on first call, reuses it after', function()
    withFakeDb(function(tables)
        local first = GalleryService.getDefaultAlbum(1)
        eq(first.name, 'Camera Roll')
        truthy(first.is_default)

        local second = GalleryService.getDefaultAlbum(1)
        eq(second.id, first.id)
        eq(#tables.phone_albums, 1, 'expected exactly one default album to have been created')
    end)
end)

test('createAlbum rejects a blank name', function()
    withFakeDb(function()
        eq(GalleryService.createAlbum(1, '   '), nil)
        eq(GalleryService.createAlbum(1, ''), nil)
    end)
end)

test('createAlbum makes a real, non-default album', function()
    withFakeDb(function()
        local album = GalleryService.createAlbum(1, 'Vacation')
        truthy(album)
        eq(album.name, 'Vacation')
        eq(album.is_default, false)
    end)
end)

test('listAlbums only returns the calling character\'s albums', function()
    withFakeDb(function()
        GalleryService.createAlbum(1, 'Mine')
        GalleryService.createAlbum(2, 'Not mine')

        local albums = GalleryService.listAlbums(1)
        eq(#albums, 1)
        eq(albums[1].name, 'Mine')
    end)
end)

test('deleteAlbum reassigns contained media to the default album instead of deleting it', function()
    withFakeDb(function(tables)
        local default = GalleryService.getDefaultAlbum(1)
        local vacation = GalleryService.createAlbum(1, 'Vacation')
        -- QueryBuilder.new('phone_media') hasn't been called by the service
        -- yet at this point, so the fake's lazily-created table doesn't
        -- exist - seed it directly before inserting into it.
        tables.phone_media = tables.phone_media or {}
        table.insert(tables.phone_media, {
            id = 1, owner_character_id = 1, album_id = vacation.id,
            kind = 'photo', storage_key = 'k', url = 'u', taken_at = 'now',
        })

        local ok = GalleryService.deleteAlbum(1, vacation.id)
        truthy(ok)

        local media = GalleryService.listMedia(1, default.id)
        eq(#media, 1)
        eq(media[1].album_id, default.id)

        local albums = GalleryService.listAlbums(1)
        eq(#albums, 1, 'the deleted album should be gone, only the default remains')
    end)
end)

test('deleteAlbum refuses to delete the default album', function()
    withFakeDb(function()
        local default = GalleryService.getDefaultAlbum(1)
        eq(GalleryService.deleteAlbum(1, default.id), false)
    end)
end)

test('deleteMedia removes the row and calls Storage.delete with its storage_key', function()
    withFakeDb(function(tables)
        local default = GalleryService.getDefaultAlbum(1)
        tables.phone_media = tables.phone_media or {}
        table.insert(tables.phone_media, {
            id = 5, owner_character_id = 1, album_id = default.id,
            kind = 'photo', storage_key = 'phone-media/1/5.webp', url = 'u', taken_at = 'now',
        })
        deletedKeys = {}

        local ok = GalleryService.deleteMedia(1, 5)
        truthy(ok)
        eq(#deletedKeys, 1)
        eq(deletedKeys[1], 'phone-media/1/5.webp')
        eq(#GalleryService.listMedia(1, default.id), 0)
    end)
end)

test('deleteMedia refuses to delete another character\'s media', function()
    withFakeDb(function(tables)
        local default = GalleryService.getDefaultAlbum(2)
        tables.phone_media = tables.phone_media or {}
        table.insert(tables.phone_media, {
            id = 9, owner_character_id = 2, album_id = default.id,
            kind = 'photo', storage_key = 'k', url = 'u', taken_at = 'now',
        })

        eq(GalleryService.deleteMedia(1, 9), false)
        eq(#GalleryService.listMedia(2, default.id), 1)
    end)
end)

test('sendToConversation delegates to MessagesService.send with the media url/kind', function()
    withFakeDb(function(tables)
        local default = GalleryService.getDefaultAlbum(1)
        tables.phone_media = tables.phone_media or {}
        table.insert(tables.phone_media, {
            id = 7, owner_character_id = 1, album_id = default.id,
            kind = 'video', storage_key = 'k', url = 'https://example.test/v.webm', taken_at = 'now',
        })
        tables.phone_threads = { { id = 1, is_group = false } }
        tables.phone_thread_members = {
            { id = 1, thread_id = 1, character_id = 1 },
            { id = 2, thread_id = 1, character_id = 2 },
        }

        local message = GalleryService.sendToConversation(1, 7, 1)
        truthy(message)
        eq(message.media_url, 'https://example.test/v.webm')
        eq(message.media_kind, 'video')
    end)
end)

test('sendToConversation refuses another character\'s media', function()
    withFakeDb(function(tables)
        local default = GalleryService.getDefaultAlbum(2)
        tables.phone_media = tables.phone_media or {}
        table.insert(tables.phone_media, {
            id = 8, owner_character_id = 2, album_id = default.id,
            kind = 'photo', storage_key = 'k', url = 'u', taken_at = 'now',
        })
        tables.phone_threads = { { id = 1, is_group = false } }
        tables.phone_thread_members = { { id = 1, thread_id = 1, character_id = 1 } }

        local message, err = GalleryService.sendToConversation(1, 8, 1)
        eq(message, nil)
        truthy(err)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('gallery_service_spec: %d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('  FAIL: ' .. f.name .. '\n    ' .. tostring(f.err)) end
if #failures > 0 then os.exit(1) end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 plugins/oblsk_phone/tests/gallery_service_spec.lua`
Expected: FAIL, `plugins/oblsk_phone/server/services/GalleryService.lua` does not exist yet.

- [ ] **Step 3: Write `GalleryService.lua`**

```lua
-- plugins/oblsk_phone/server/services/GalleryService.lua
--- GalleryService (server) - albums and media (photos/videos) captured via
--- CameraService. Character-scoped ownership throughout, matching
--- MessagesService's convention. See
--- docs/superpowers/specs/2026-08-13-camera-gallery-design.md.
GalleryService = {}

--- Finds or lazily creates the character's default "Camera Roll" album -
--- every character gets exactly one, created on first use rather than at
--- character creation, so a character who never opens Camera never gets a
--- row for it.
--- @param characterId number
--- @return table album row
function GalleryService.getDefaultAlbum(characterId)
    local album = QueryBuilder.new('phone_albums')
        :where('owner_character_id', characterId):where('is_default', true):firstSync()
    if album then
        return album
    end

    local now = Database.now()
    local id = QueryBuilder.new('phone_albums'):insert({
        owner_character_id = characterId,
        name = 'Camera Roll',
        is_default = true,
        created_at = now,
        updated_at = now,
    })
    return QueryBuilder.new('phone_albums'):where('id', id):firstSync()
end

--- @param characterId number
--- @return table[] album rows
function GalleryService.listAlbums(characterId)
    return QueryBuilder.new('phone_albums'):where('owner_character_id', characterId):getSync()
end

--- @param characterId number
--- @param name string
--- @return table|nil album row, nil if name is blank
function GalleryService.createAlbum(characterId, name)
    if type(name) ~= 'string' or name:match('^%s*$') then
        return nil
    end

    local now = Database.now()
    local id = QueryBuilder.new('phone_albums'):insert({
        owner_character_id = characterId,
        name = name,
        is_default = false,
        created_at = now,
        updated_at = now,
    })
    return QueryBuilder.new('phone_albums'):where('id', id):firstSync()
end

--- @param characterId number
--- @param albumId number
--- @param name string
--- @return boolean
function GalleryService.renameAlbum(characterId, albumId, name)
    if type(name) ~= 'string' or name:match('^%s*$') then
        return false
    end

    local affected = QueryBuilder.new('phone_albums')
        :where('id', albumId):where('owner_character_id', characterId)
        :update({ name = name, updated_at = Database.now() })
    return affected > 0
end

--- Deletes a non-default album, reassigning its media to the character's
--- default album first so a mistaken album delete never loses a capture.
--- The default album itself cannot be deleted.
--- @param characterId number
--- @param albumId number
--- @return boolean
function GalleryService.deleteAlbum(characterId, albumId)
    local album = QueryBuilder.new('phone_albums')
        :where('id', albumId):where('owner_character_id', characterId):firstSync()
    if not album or album.is_default then
        return false
    end

    local default = GalleryService.getDefaultAlbum(characterId)
    QueryBuilder.new('phone_media')
        :where('album_id', albumId)
        :update({ album_id = default.id, updated_at = Database.now() })
    QueryBuilder.new('phone_albums'):where('id', albumId):delete()
    return true
end

--- @param characterId number
--- @param albumId number
--- @return table[] media rows, newest first
function GalleryService.listMedia(characterId, albumId)
    return QueryBuilder.new('phone_media')
        :where('owner_character_id', characterId):where('album_id', albumId)
        :orderBy('taken_at', 'desc'):getSync()
end

--- @param characterId number
--- @param mediaId number
--- @return boolean
function GalleryService.deleteMedia(characterId, mediaId)
    local media = QueryBuilder.new('phone_media')
        :where('id', mediaId):where('owner_character_id', characterId):firstSync()
    if not media then
        return false
    end

    Storage.delete(media.storage_key)
    QueryBuilder.new('phone_media'):where('id', mediaId):delete()
    return true
end

--- @param characterId number
--- @param mediaId number
--- @param threadId number
--- @return table|nil message row
--- @return string|nil err set only when the message row is nil
function GalleryService.sendToConversation(characterId, mediaId, threadId)
    local media = QueryBuilder.new('phone_media')
        :where('id', mediaId):where('owner_character_id', characterId):firstSync()
    if not media then
        return nil, 'media not found'
    end

    local message = MessagesService.send(characterId, threadId, nil, media.url, media.kind)
    if not message then
        return nil, 'send failed'
    end
    return message
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_phone/tests/gallery_service_spec.lua`
Expected: `gallery_service_spec: 10/10 passed`.

- [ ] **Step 5: Register the apps in `PhoneAppRegistry.CATALOG`**

In `plugins/oblsk_phone/server/services/PhoneAppRegistry.lua`, add two entries to `PhoneAppRegistry.CATALOG` (after the existing `contacts` entry, or wherever the non-mandatory apps are listed):

```lua
    { app_key = 'camera',   name = 'Camera' },
    { app_key = 'gallery',  name = 'Gallery' },
```

- [ ] **Step 6: Add the Gallery net events to `server/main.lua`**

Add to `plugins/oblsk_phone/server/main.lua` (near the existing Messages handlers):

```lua
Obelisk.onServer('oblsk_phone:server:gallery-albums', function()
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return
    end

    GalleryService.getDefaultAlbum(characterId) -- ensures at least one album exists
    Obelisk.emitClient('oblsk_phone:client:gallery-albums', source, GalleryService.listAlbums(characterId))
end)

Obelisk.onServer('oblsk_phone:server:gallery-media', function(albumId)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId or type(albumId) ~= 'number' then
        return
    end

    Obelisk.emitClient('oblsk_phone:client:gallery-media', source, albumId, GalleryService.listMedia(characterId, albumId))
end)

Obelisk.onServer('oblsk_phone:server:gallery-create-album', function(name)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return
    end

    GalleryService.createAlbum(characterId, name)
    Obelisk.emitClient('oblsk_phone:client:gallery-albums', source, GalleryService.listAlbums(characterId))
end)

Obelisk.onServer('oblsk_phone:server:gallery-rename-album', function(albumId, name)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId or type(albumId) ~= 'number' then
        return
    end

    GalleryService.renameAlbum(characterId, albumId, name)
    Obelisk.emitClient('oblsk_phone:client:gallery-albums', source, GalleryService.listAlbums(characterId))
end)

Obelisk.onServer('oblsk_phone:server:gallery-delete-album', function(albumId)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId or type(albumId) ~= 'number' then
        return
    end

    GalleryService.deleteAlbum(characterId, albumId)
    Obelisk.emitClient('oblsk_phone:client:gallery-albums', source, GalleryService.listAlbums(characterId))
end)

Obelisk.onServer('oblsk_phone:server:gallery-delete-media', function(albumId, mediaId)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId or type(albumId) ~= 'number' or type(mediaId) ~= 'number' then
        return
    end

    GalleryService.deleteMedia(characterId, mediaId)
    Obelisk.emitClient('oblsk_phone:client:gallery-media', source, albumId, GalleryService.listMedia(characterId, albumId))
end)

Obelisk.onServer('oblsk_phone:server:gallery-send-to-conversation', function(mediaId, threadId)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId or type(mediaId) ~= 'number' or type(threadId) ~= 'number' then
        return
    end

    local message, err = GalleryService.sendToConversation(characterId, mediaId, threadId)
    if not message then
        Obelisk.emitClient('oblsk_phone:client:gallery-send-failed', source, err)
        return
    end

    Obelisk.emitClient('oblsk_phone:client:gallery-sent-to-conversation', source, threadId)

    for _, otherCharacterId in ipairs(MessagesService.otherMembers(characterId, threadId)) do
        local otherSource = CharacterService.findSourceByCharacterId(otherCharacterId)
        if otherSource then
            Obelisk.emitClient('oblsk_phone:client:messages-new', otherSource, threadId, message)
        end
    end
end)
```

- [ ] **Step 7: Run the full suite and commit**

Run: `npm test` — expect every spec to pass, exit code 0.

```bash
git add plugins/oblsk_phone/server/services/GalleryService.lua plugins/oblsk_phone/server/services/PhoneAppRegistry.lua plugins/oblsk_phone/server/main.lua plugins/oblsk_phone/tests/gallery_service_spec.lua
git commit -m "feat(phone): add GalleryService (albums, media, send-to-conversation)"
```

---

### Task 5: CameraService + net events + quota config

**Files:**
- Create: `plugins/oblsk_phone/server/services/CameraService.lua`
- Modify: `plugins/oblsk_phone/server/main.lua`
- Modify: `<repo-root>/server.cfg.example`, `<repo-root>/server.cfg`
- Test: `plugins/oblsk_phone/tests/camera_service_spec.lua`

**Interfaces:**
- Consumes: `GalleryService.getDefaultAlbum` (Task 4), `Storage.mintUploadToken`/`Storage.uploadUrl` (core), `exports.screencapture:remoteUpload`/`startVideoCaptureUpload`/`stopVideoCapture`.
- Produces: `CameraService.capturePhoto(source, characterId, albumId, callback)` — `callback(media, err)`. `CameraService.startVideo(source, characterId, albumId, callback)` → returns `captureId` synchronously, `callback(media, err)` fires later. `CameraService.stopVideo(captureId)`.

- [ ] **Step 1: Write the failing test**

```lua
-- plugins/oblsk_phone/tests/camera_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_phone/tests/camera_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected a truthy value', 2) end end

-- Fakes for everything CameraService depends on outside its own file.
_G.Storage = {
    mintUploadToken = function(key, contentType) return 'tok-' .. key end,
    uploadUrl = function() return 'http://127.0.0.1:30120/core/storage/upload' end,
}
_G.GalleryService = {
    getDefaultAlbum = function(characterId) return { id = 100 + characterId } end,
}

dofile(scriptDir .. '../server/services/CameraService.lua')

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('capturePhoto uploads via screencapture.remoteUpload with a header token, no query token', function()
    withFakeDb(function()
        local seenUrl, seenOptions
        _G.exports = { screencapture = {
            remoteUpload = function(_self, source, url, options, callback)
                seenUrl, seenOptions = url, options
                callback({ url = 'http://127.0.0.1:30120/core/storage/phone-media/1/x.webp' })
            end,
        } }

        local media, err
        CameraService.capturePhoto(1, 1, nil, function(m, e) media, err = m, e end)

        truthy(media, 'expected a saved media row')
        eq(err, nil)
        eq(media.kind, 'photo')
        eq(media.album_id, 101)
        eq(seenUrl, 'http://127.0.0.1:30120/core/storage/upload')
        truthy(seenOptions.headers['X-Storage-Token'], 'expected an X-Storage-Token header')
        eq(seenOptions.headers['X-Storage-Token']:sub(1, 4), 'tok-')
    end)
end)

test('capturePhoto treats a response with no url as a failure, no media row saved', function()
    withFakeDb(function(tables)
        _G.exports = { screencapture = {
            remoteUpload = function(_self, source, url, options, callback)
                callback({})
            end,
        } }

        local media, err
        CameraService.capturePhoto(1, 1, nil, function(m, e) media, err = m, e end)

        eq(media, nil)
        truthy(err)
        eq(#(tables.phone_media or {}), 0)
    end)
end)

test('capturePhoto refuses to upload once the character is at the gallery quota', function()
    withFakeDb(function(tables)
        _G.GetConvarInt = function(_, default) return 1 end -- quota of 1 for this test
        tables.phone_media = { { id = 1, owner_character_id = 1, album_id = 101 } }

        local uploadCalled = false
        _G.exports = { screencapture = {
            remoteUpload = function() uploadCalled = true end,
        } }

        local media, err
        CameraService.capturePhoto(1, 1, nil, function(m, e) media, err = m, e end)

        eq(media, nil)
        eq(err, 'gallery full')
        eq(uploadCalled, false)
        _G.GetConvarInt = function(_, default) return default end -- restore
    end)
end)

test('startVideo caps duration at 15s and returns a captureId synchronously', function()
    withFakeDb(function()
        local seenOptions, capturedCallback
        _G.exports = { screencapture = {
            startVideoCaptureUpload = function(_self, source, url, options, callback)
                seenOptions, capturedCallback = options, callback
                return 'capture-123'
            end,
        } }

        local captureId = CameraService.startVideo(1, 1, nil, function() end)
        eq(captureId, 'capture-123')
        eq(seenOptions.duration, 15)
    end)
end)

test('startVideo callback saves a media row on a successful, non-empty result', function()
    withFakeDb(function()
        local capturedCallback
        _G.exports = { screencapture = {
            startVideoCaptureUpload = function(_self, source, url, options, callback)
                capturedCallback = callback
                return 'capture-456'
            end,
        } }

        local media, err
        CameraService.startVideo(1, 1, nil, function(m, e) media, err = m, e end)
        capturedCallback({
            status = 'success', bytesReceived = 4096,
            response = { url = 'http://127.0.0.1:30120/core/storage/phone-media/1/v.webm' },
        })

        truthy(media)
        eq(media.kind, 'video')
        eq(media.duration_seconds, 15)
    end)
end)

test('startVideo callback treats a zero-byte result as a failure (the documented empty-file case)', function()
    withFakeDb(function(tables)
        local capturedCallback
        _G.exports = { screencapture = {
            startVideoCaptureUpload = function(_self, source, url, options, callback)
                capturedCallback = callback
                return 'capture-789'
            end,
        } }

        local media, err
        CameraService.startVideo(1, 1, nil, function(m, e) media, err = m, e end)
        capturedCallback({ status = 'success', bytesReceived = 0 })

        eq(media, nil)
        truthy(err)
        eq(#(tables.phone_media or {}), 0)
    end)
end)

test('stopVideo calls exports.screencapture:stopVideoCapture with the given captureId', function()
    local seenCaptureId
    _G.exports = { screencapture = {
        stopVideoCapture = function(_self, captureId) seenCaptureId = captureId end,
    } }

    CameraService.stopVideo('capture-abc')
    eq(seenCaptureId, 'capture-abc')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('camera_service_spec: %d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('  FAIL: ' .. f.name .. '\n    ' .. tostring(f.err)) end
if #failures > 0 then os.exit(1) end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 plugins/oblsk_phone/tests/camera_service_spec.lua`
Expected: FAIL, `plugins/oblsk_phone/server/services/CameraService.lua` does not exist yet.

- [ ] **Step 3: Write `CameraService.lua`**

```lua
-- plugins/oblsk_phone/server/services/CameraService.lua
--- CameraService (server) - captures photos and short video clips via the
--- screencapture resource (github.com/itschip/screencapture), uploading
--- straight to this server's own Storage.uploadUrl() endpoint using a
--- server-minted, single-use token (Storage.mintUploadToken) passed via
--- the X-Storage-Token header - never exposed to the client, matching
--- screencapture's own recommendation over its client-side upload export.
--- See docs/superpowers/specs/2026-08-13-camera-gallery-design.md.
CameraService = {}

local MAX_VIDEO_DURATION_SECONDS = 15

--- @param characterId number
--- @return boolean
local function hasCapacity(characterId)
    local count = #QueryBuilder.new('phone_media'):where('owner_character_id', characterId):getSync()
    return count < GetConvarInt('phone_gallery_max_items', 200)
end

--- @param characterId number
--- @param albumId number|nil
--- @param kind string 'photo'|'video'
--- @param storageKey string
--- @param url string
--- @param durationSeconds number|nil
--- @return table media row
local function insertMedia(characterId, albumId, kind, storageKey, url, durationSeconds)
    local now = Database.now()
    local id = QueryBuilder.new('phone_media'):insert({
        owner_character_id = characterId,
        album_id = albumId,
        kind = kind,
        storage_key = storageKey,
        url = url,
        duration_seconds = durationSeconds,
        taken_at = now,
        created_at = now,
        updated_at = now,
    })
    return QueryBuilder.new('phone_media'):where('id', id):firstSync()
end

--- @param characterId number
--- @return number albumId
local function resolveAlbumId(characterId, albumId)
    if albumId then
        return albumId
    end
    return GalleryService.getDefaultAlbum(characterId).id
end

--- @param characterId number
--- @param ext string file extension, no dot
--- @return string storage key, unique enough for this purpose (not a security token)
local function newStorageKey(characterId, ext)
    return string.format('phone-media/%d/%d-%04x.%s', characterId, os.time(), math.random(0, 0xffff), ext)
end

--- @param source number
--- @param characterId number
--- @param albumId number|nil defaults to the character's default album
--- @param callback function(media table|nil, err string|nil)
function CameraService.capturePhoto(source, characterId, albumId, callback)
    if not hasCapacity(characterId) then
        callback(nil, 'gallery full')
        return
    end

    local resolvedAlbumId = resolveAlbumId(characterId, albumId)
    local storageKey = newStorageKey(characterId, 'webp')
    local token = Storage.mintUploadToken(storageKey, 'image/webp')

    exports.screencapture:remoteUpload(source, Storage.uploadUrl(), {
        encoding = 'webp',
        headers = { ['X-Storage-Token'] = token },
    }, function(response)
        -- response is screencapture's parsed reply from our own
        -- /storage/upload endpoint, which replies {url=...} on success (see
        -- core/server/Services/storage/upload_handler.lua). A missing url
        -- is treated as failure regardless of what screencapture does with
        -- a non-2xx status internally - verify this against a live capture
        -- during manual testing, since screencapture's exact
        -- failure-callback shape isn't documented.
        if type(response) ~= 'table' or not response.url then
            callback(nil, 'upload failed')
            return
        end

        callback(insertMedia(characterId, resolvedAlbumId, 'photo', storageKey, response.url, nil), nil)
    end)
end

--- @param source number
--- @param characterId number
--- @param albumId number|nil defaults to the character's default album
--- @param callback function(media table|nil, err string|nil) fires once the recording finalizes (duration cap or a later CameraService.stopVideo call)
--- @return string captureId
function CameraService.startVideo(source, characterId, albumId, callback)
    if not hasCapacity(characterId) then
        callback(nil, 'gallery full')
        return nil
    end

    local resolvedAlbumId = resolveAlbumId(characterId, albumId)
    local storageKey = newStorageKey(characterId, 'webm')
    local token = Storage.mintUploadToken(storageKey, 'video/webm')

    return exports.screencapture:startVideoCaptureUpload(source, Storage.uploadUrl(), {
        duration = MAX_VIDEO_DURATION_SECONDS,
        headers = { ['X-Storage-Token'] = token },
    }, function(result)
        -- status ~= 'success' covers an explicit screencapture error;
        -- bytesReceived == 0 covers the documented "silently produced an
        -- empty file" case (WebCodecs unavailable in that FiveM build's
        -- bundled Chromium) - both need live-capture verification, video
        -- capture is explicitly experimental per screencapture's own docs.
        if not result or result.status ~= 'success' or not (result.bytesReceived and result.bytesReceived > 0) then
            callback(nil, 'recording failed')
            return
        end

        local url = result.response and result.response.url
        if not url then
            callback(nil, 'recording failed')
            return
        end

        callback(insertMedia(characterId, resolvedAlbumId, 'video', storageKey, url, MAX_VIDEO_DURATION_SECONDS), nil)
    end)
end

--- @param captureId string
function CameraService.stopVideo(captureId)
    exports.screencapture:stopVideoCapture(captureId)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_phone/tests/camera_service_spec.lua`
Expected: `camera_service_spec: 7/7 passed`.

- [ ] **Step 5: Add the Camera net events to `server/main.lua`**

Add to `plugins/oblsk_phone/server/main.lua`:

```lua
Obelisk.onServer('oblsk_phone:server:camera-capture-photo', function(albumId)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return
    end

    CameraService.capturePhoto(source, characterId, albumId, function(media, err)
        if not media then
            Obelisk.emitClient('oblsk_phone:client:camera-capture-failed', source, err)
            return
        end

        Obelisk.emitClient('oblsk_phone:client:camera-photo-saved', source, media)
    end)
end)

Obelisk.onServer('oblsk_phone:server:camera-start-video', function(albumId)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return
    end

    local captureId = CameraService.startVideo(source, characterId, albumId, function(media, err)
        if not media then
            Obelisk.emitClient('oblsk_phone:client:camera-capture-failed', source, err)
            return
        end

        Obelisk.emitClient('oblsk_phone:client:camera-video-saved', source, media)
    end)

    if captureId then
        Obelisk.emitClient('oblsk_phone:client:camera-video-started', source, captureId)
    end
end)

Obelisk.onServer('oblsk_phone:server:camera-stop-video', function(captureId)
    if type(captureId) ~= 'string' then
        return
    end
    CameraService.stopVideo(captureId)
end)
```

- [ ] **Step 6: Add the quota convar**

In `<repo-root>/server.cfg.example`, add after the `storage_http_port` line added in Task 1:

```
# Max photos+videos a character's Gallery can hold across all albums.
set phone_gallery_max_items 200
```

Copy the same line into `<repo-root>/server.cfg`.

- [ ] **Step 7: Run the full suite and commit**

Run: `npm test` — expect every spec to pass, exit code 0.

```bash
git add plugins/oblsk_phone/server/services/CameraService.lua plugins/oblsk_phone/server/main.lua plugins/oblsk_phone/tests/camera_service_spec.lua
git commit -m "feat(phone): add CameraService (photo/video capture via screencapture)"
```

```bash
git -C <repo-root> add server.cfg.example server.cfg
git -C <repo-root> commit -m "Add phone_gallery_max_items config for Camera+Gallery"
```

---

### Task 6: Icons and app tile metadata

**Files:**
- Modify: `plugins/oblsk_phone/web/phone/Icon.vue`
- Modify: `plugins/oblsk_phone/web/phone/appMeta.js`

**Interfaces:**
- Produces: `Icon.vue`'s `ICONS` map gains `camera` and `image` keys. `appMeta.js`'s app-metadata map gains `camera`/`gallery` entries, consumed by `Camera.vue`/`Gallery.vue` (Tasks 7-8) and the home-screen tile grid.

- [ ] **Step 1: Add `camera` and `image` glyphs to `Icon.vue`**

In `plugins/oblsk_phone/web/phone/Icon.vue`'s `ICONS` map, add (matching the existing entries' `{tag, attrs}` shape and 24x24 stroke-based style — these are the standard Feather-icon `camera`/`image` glyphs, MIT-licensed path data, consistent with this file's existing icon set):

```js
camera: [
  { tag: 'path', attrs: { d: 'M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z' } },
  { tag: 'circle', attrs: { cx: 12, cy: 13, r: 4 } }
],
image: [
  { tag: 'rect', attrs: { x: 3, y: 3, width: 18, height: 18, rx: 2, ry: 2 } },
  { tag: 'circle', attrs: { cx: 8.5, cy: 8.5, r: 1.5 } },
  { tag: 'polyline', attrs: { points: '21 15 16 10 5 21' } }
],
```

- [ ] **Step 2: Add `camera`/`gallery` entries to `appMeta.js`**

In `plugins/oblsk_phone/web/phone/appMeta.js`'s app-metadata map, add (colors match the original design mockup's tile metadata for these two apps):

```js
camera: { name: 'Camera', icon: 'camera', color: '#1f2937' },
gallery: { name: 'Gallery', icon: 'image', color: '#3f2b56' },
```

- [ ] **Step 3: Verify the web build**

Run: `cd core/web && npm run build`
Expected: build succeeds with no errors (Vue components aren't unit-tested in this codebase, so a clean build is the verification step, matching the precedent set by prior frontend-only tasks in this repo).

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_phone/web/phone/Icon.vue plugins/oblsk_phone/web/phone/appMeta.js
git commit -m "feat(phone): add camera/gallery icons and app tile metadata"
```

---

### Task 7: Camera.vue

**Files:**
- Create: `plugins/oblsk_phone/web/apps/Camera/Camera.vue`

**Interfaces:**
- Consumes: net events from Task 10's client relay (`oblsk_phone:client:camera-capture-photo`, `-start-video`, `-stop-video` outbound; `-photo-saved`, `-video-started`, `-video-saved`, `-capture-failed` inbound) — this task writes the component against those event names; Task 10 wires the client-side relay that makes them real. The component works once Task 10 lands; a build check is this task's verification since there's no NUI runtime in the test suite.

- [ ] **Step 1: Write `Camera.vue`**

```vue
<template>
  <div class="absolute inset-0 flex flex-col bg-black">
    <div class="flex-1 relative flex items-center justify-center text-white/30 text-[12px]">
      <!-- The live game view shows through the NUI's transparent background
           behind this overlay; there is no <video> preview element here,
           screencapture reads directly from the game's own render output. -->
      <span v-if="recording">Recording… {{ elapsed }}s</span>
    </div>

    <div v-if="toast" class="absolute top-4 left-1/2 -translate-x-1/2 rounded-full bg-white/10 border border-white/15 px-4 py-1.5 text-[12px]">
      {{ toast }}
    </div>

    <div class="shrink-0 pb-8 pt-4 flex items-center justify-center gap-8">
      <button
        class="w-9 h-9 rounded-full border border-white/20 grid place-items-center text-[10px] font-mono"
        :class="mode === 'photo' ? 'bg-white/15' : 'text-white/40'"
        @click="mode = 'photo'"
      >
        <Icon name="camera" :size="16" />
      </button>

      <button
        class="w-16 h-16 rounded-full border-4 border-white/70 grid place-items-center"
        :class="recording ? 'bg-red-500/80' : 'bg-white/10'"
        @click="shutter"
      >
        <span v-if="recording" class="w-5 h-5 rounded-sm bg-white"></span>
      </button>

      <button
        class="w-9 h-9 rounded-full border border-white/20 grid place-items-center text-[10px] font-mono"
        :class="mode === 'video' ? 'bg-white/15' : 'text-white/40'"
        @click="mode = 'video'"
      >
        <Icon name="image" :size="16" />
      </button>
    </div>
  </div>
</template>

<script setup>
// Camera: photo/video mode toggle + shutter. Capture itself is entirely
// server-driven (CameraService, via screencapture's server-side exports) -
// this component only starts/stops a capture and shows the result, it
// never touches image/video bytes directly. See
// docs/superpowers/specs/2026-08-13-camera-gallery-design.md.
import { onBeforeUnmount, onMounted, ref } from 'vue'
import Obelisk from '@/obelisk.js'
import Icon from '../../phone/Icon.vue'

const mode = ref('photo')
const recording = ref(false)
const elapsed = ref(0)
const toast = ref('')
const captureId = ref(null)
let elapsedTimer = null
let toastTimer = null

function showToast(message) {
  toast.value = message
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { toast.value = '' }, 2000)
}

function shutter() {
  if (mode.value === 'photo') {
    Obelisk.emit('oblsk_phone:client:camera-capture-photo', {})
    return
  }

  if (recording.value) {
    Obelisk.emit('oblsk_phone:client:camera-stop-video', { captureId: captureId.value })
    return
  }

  Obelisk.emit('oblsk_phone:client:camera-start-video', {})
}

function handleVideoStarted(id) {
  captureId.value = id
  recording.value = true
  elapsed.value = 0
  elapsedTimer = setInterval(() => { elapsed.value += 1 }, 1000)
}

function stopRecordingUi() {
  recording.value = false
  captureId.value = null
  clearInterval(elapsedTimer)
}

function handlePhotoSaved() {
  showToast('Saved to Gallery')
}

function handleVideoSaved() {
  stopRecordingUi()
  showToast('Saved to Gallery')
}

function handleCaptureFailed(reason) {
  stopRecordingUi()
  showToast(reason === 'gallery full' ? 'Gallery full — delete something first' : 'Capture failed')
}

onMounted(() => {
  Obelisk.on('oblsk_phone:client:camera-photo-saved', handlePhotoSaved)
  Obelisk.on('oblsk_phone:client:camera-video-started', handleVideoStarted)
  Obelisk.on('oblsk_phone:client:camera-video-saved', handleVideoSaved)
  Obelisk.on('oblsk_phone:client:camera-capture-failed', handleCaptureFailed)
})

onBeforeUnmount(() => {
  Obelisk.off('oblsk_phone:client:camera-photo-saved', handlePhotoSaved)
  Obelisk.off('oblsk_phone:client:camera-video-started', handleVideoStarted)
  Obelisk.off('oblsk_phone:client:camera-video-saved', handleVideoSaved)
  Obelisk.off('oblsk_phone:client:camera-capture-failed', handleCaptureFailed)
  clearInterval(elapsedTimer)
  clearTimeout(toastTimer)
})
</script>
```

- [ ] **Step 2: Verify the web build**

Run: `cd core/web && npm run build`
Expected: build succeeds. (`Camera.vue` isn't imported anywhere yet — Task 10 wires it into `Phone.vue` — so a successful build here just confirms the file itself is syntactically valid Vue/JS; Task 10's build check is what confirms it's actually reachable.)

- [ ] **Step 3: Commit**

```bash
git add plugins/oblsk_phone/web/apps/Camera/Camera.vue
git commit -m "feat(phone): add Camera.vue capture UI"
```

---

### Task 8: Gallery.vue

**Files:**
- Create: `plugins/oblsk_phone/web/apps/Gallery/Gallery.vue`

**Interfaces:**
- Produces: emits nothing external; internally drives the `gallery-*` net events from Task 4. Mounts `ShareSheet.vue` for "send to conversation" (Task 9 extends `ShareSheet.vue` to support this — this task writes `Gallery.vue` against that extended prop shape).

- [ ] **Step 1: Write `Gallery.vue`**

```vue
<template>
  <div class="absolute inset-0 flex flex-col">
    <!-- Album grid -->
    <div v-if="!openAlbum" class="flex-1 overflow-y-auto p-3">
      <div class="flex items-center justify-between mb-3">
        <span class="text-[13px] font-medium">Gallery</span>
        <button class="font-mono text-[9px] text-white/40 hover:text-white" @click="creatingAlbum = true">NEW ALBUM</button>
      </div>

      <div v-if="creatingAlbum" class="mb-3 flex gap-2">
        <input
          v-model="newAlbumName"
          class="flex-1 bg-white/[0.05] border border-white/10 rounded-xl px-3 py-2 text-[12px]"
          placeholder="Album name"
          @keyup.enter="createAlbum"
        />
        <button class="px-3 rounded-xl bg-white/10 text-[11px]" @click="createAlbum">Add</button>
      </div>

      <div class="grid grid-cols-2 gap-2">
        <button
          v-for="album in albums"
          :key="album.id"
          class="rounded-2xl border border-white/10 bg-white/[0.04] p-3 text-left"
          @click="openAlbum = album"
        >
          <div class="flex items-center gap-2 mb-1">
            <Icon name="image" :size="13" class="text-white/50" />
            <span class="text-[12.5px] font-medium truncate">{{ album.name }}</span>
          </div>
        </button>
      </div>
    </div>

    <!-- Media grid for one album -->
    <div v-else-if="!openMedia" class="flex-1 overflow-y-auto p-3">
      <div class="flex items-center gap-2 mb-3">
        <button class="text-white/50" @click="openAlbum = null">
          <Icon name="chevL" :size="16" />
        </button>
        <span class="text-[13px] font-medium">{{ openAlbum.name }}</span>
      </div>

      <div v-if="!media.length" class="text-center text-[11.5px] text-white/30 py-8">
        Nothing here yet.
      </div>

      <div v-else class="grid grid-cols-3 gap-1.5">
        <button
          v-for="item in media"
          :key="item.id"
          class="aspect-square rounded-lg overflow-hidden bg-white/5"
          @click="openMedia = item"
        >
          <img v-if="item.kind === 'photo'" :src="item.url" class="w-full h-full object-cover" />
          <video v-else :src="item.url" class="w-full h-full object-cover" muted />
        </button>
      </div>
    </div>

    <!-- Single media detail -->
    <div v-else class="flex-1 flex flex-col">
      <div class="flex items-center gap-2 p-3">
        <button class="text-white/50" @click="openMedia = null">
          <Icon name="chevL" :size="16" />
        </button>
      </div>
      <div class="flex-1 flex items-center justify-center bg-black">
        <img v-if="openMedia.kind === 'photo'" :src="openMedia.url" class="max-w-full max-h-full object-contain" />
        <video v-else :src="openMedia.url" class="max-w-full max-h-full object-contain" controls />
      </div>
      <div class="shrink-0 p-3 flex gap-2">
        <button class="flex-1 rounded-xl bg-white/10 py-2 text-[11.5px]" @click="shareOpen = true">Send to conversation</button>
        <button class="flex-1 rounded-xl bg-red-500/20 text-red-300 py-2 text-[11.5px]" @click="deleteCurrent">Delete</button>
      </div>
    </div>

    <ShareSheet
      :open="shareOpen"
      :media-id="openMedia && openMedia.id"
      preview="Photo/video"
      @close="shareOpen = false"
      @shared="shareOpen = false"
    />
  </div>
</template>

<script setup>
// Gallery: album grid -> media grid -> media detail, matching the list/
// detail toggle pattern from Messages.vue. See
// docs/superpowers/specs/2026-08-13-camera-gallery-design.md.
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import Obelisk from '@/obelisk.js'
import Icon from '../../phone/Icon.vue'
import ShareSheet from '../Messages/ShareSheet.vue'

const albums = ref([])
const openAlbum = ref(null)
const media = ref([])
const openMedia = ref(null)
const creatingAlbum = ref(false)
const newAlbumName = ref('')
const shareOpen = ref(false)

function handleAlbums(list) {
  albums.value = Array.isArray(list) ? list : []
}

function handleMedia(albumId, list) {
  if (!openAlbum.value || openAlbum.value.id !== albumId) return
  media.value = Array.isArray(list) ? list : []
  if (openMedia.value && !media.value.find((m) => m.id === openMedia.value.id)) {
    openMedia.value = null
  }
}

function createAlbum() {
  if (!newAlbumName.value.trim()) return
  Obelisk.emit('oblsk_phone:client:gallery-create-album', { name: newAlbumName.value.trim() })
  newAlbumName.value = ''
  creatingAlbum.value = false
}

function deleteCurrent() {
  if (!openAlbum.value || !openMedia.value) return
  Obelisk.emit('oblsk_phone:client:gallery-delete-media', { albumId: openAlbum.value.id, mediaId: openMedia.value.id })
  openMedia.value = null
}

watch(openAlbum, (album) => {
  media.value = []
  openMedia.value = null
  if (album) {
    Obelisk.emit('oblsk_phone:client:gallery-media', { albumId: album.id })
  }
})

onMounted(() => {
  Obelisk.on('oblsk_phone:client:gallery-albums', handleAlbums)
  Obelisk.on('oblsk_phone:client:gallery-media', handleMedia)
  Obelisk.emit('oblsk_phone:client:gallery-albums', {})
})

onBeforeUnmount(() => {
  Obelisk.off('oblsk_phone:client:gallery-albums', handleAlbums)
  Obelisk.off('oblsk_phone:client:gallery-media', handleMedia)
})
</script>
```

- [ ] **Step 2: Verify the web build**

Run: `cd core/web && npm run build`
Expected: build fails at this point — `Gallery.vue` imports `../Messages/ShareSheet.vue` with a `media-id` prop that doesn't exist on `ShareSheet.vue` yet (Task 9). A Vue template referencing an undeclared prop doesn't hard-fail a Vite build (unknown props are just passed through as attrs), so the build itself should still succeed; confirm it does. Full end-to-end correctness (the picker actually sending media, not text) is verified once Task 9 lands.

- [ ] **Step 3: Commit**

```bash
git add plugins/oblsk_phone/web/apps/Gallery/Gallery.vue
git commit -m "feat(phone): add Gallery.vue browse/album/detail UI"
```

---

### Task 9: ShareSheet media support

**Files:**
- Modify: `plugins/oblsk_phone/web/apps/Messages/ShareSheet.vue`
- Create: `plugins/oblsk_phone/web/apps/Messages/sendMediaToThread.js`

**Interfaces:**
- Consumes: `oblsk_phone:client:gallery-send-to-conversation` (Task 10's client relay).
- Produces: `ShareSheet.vue` gains an optional `mediaId` prop; when set, picking a thread sends the media instead of `body` text. `sendMediaToThread(threadId, mediaId)` — same shape as the existing `shareToThread(threadId, body)`.

- [ ] **Step 1: Write `sendMediaToThread.js`**

```js
// plugins/oblsk_phone/web/apps/Messages/sendMediaToThread.js
import Obelisk from '@/obelisk.js'

/**
 * Sends a Gallery photo/video into an existing thread. Real delivery goes
 * through GalleryService.sendToConversation via the
 * oblsk_phone:server:gallery-send-to-conversation handler (server/main.lua),
 * which owns the ownership check on the media row - this only names which
 * thread and which media id, it never carries the url/bytes itself.
 * @param {number} threadId
 * @param {number} mediaId
 */
export function sendMediaToThread(threadId, mediaId) {
  if (!threadId || !mediaId) return
  Obelisk.emit('oblsk_phone:client:gallery-send-to-conversation', { threadId, mediaId })
}
```

- [ ] **Step 2: Extend `ShareSheet.vue`**

In `plugins/oblsk_phone/web/apps/Messages/ShareSheet.vue`, replace the `<script setup>` block's props/imports/`pick` function:

```js
import { onBeforeUnmount, ref, watch } from 'vue'
import Obelisk from '@/obelisk.js'
import Icon from '../../phone/Icon.vue'
import { threadLabel } from './threadLabel.js'
import { shareToThread } from './shareToThread.js'

const props = defineProps({
  open: { type: Boolean, default: false },
  // The exact text to send, e.g. "Check out this bleet: ..." or a shared
  // map pin's description. The caller composes this, ShareSheet just picks
  // the destination thread and sends it. Ignored when mediaId is set.
  body: { type: String, default: '' },
  // When set, picking a thread sends this Gallery media id instead of
  // `body` text (Gallery.vue's "send to conversation" action).
  mediaId: { type: Number, default: null },
  // Optional short preview line shown above the thread list (e.g. "Photo"
  // or a truncated snippet of what's being shared).
  preview: { type: String, default: '' }
})
const emit = defineEmits(['close', 'shared'])

const threads = ref([])
const sentTo = ref(null)

function handleThreads(list) {
  threads.value = Array.isArray(list) ? list : []
}

function refresh() {
  Obelisk.emit('oblsk_phone:client:messages-threads', {})
}

function pick(thread) {
  if (props.mediaId) {
    sendMediaToThread(thread.id, props.mediaId)
  } else {
    if (!props.body) return
    shareToThread(thread.id, props.body)
  }
  sentTo.value = thread.id
  emit('shared', thread.id)
  setTimeout(close, 500)
}

function close() {
  sentTo.value = null
  emit('close')
}

watch(() => props.open, (isOpen) => {
  if (isOpen) refresh()
})

Obelisk.on('oblsk_phone:client:messages-threads', handleThreads)
onBeforeUnmount(() => {
  Obelisk.off('oblsk_phone:client:messages-threads', handleThreads)
})
```

And add the missing import at the top of that same block:

```js
import { sendMediaToThread } from './sendMediaToThread.js'
```

(Full import list at the top of the script block after this change: `onBeforeUnmount, ref, watch` from vue; `Obelisk`; `Icon`; `threadLabel`; `shareToThread`; `sendMediaToThread`.)

Also update the disabled-body guard: nothing else in the template references `body` directly (the template only ever calls `pick(thread)`), so no template changes are needed beyond the script block above.

- [ ] **Step 3: Verify the web build**

Run: `cd core/web && npm run build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_phone/web/apps/Messages/ShareSheet.vue plugins/oblsk_phone/web/apps/Messages/sendMediaToThread.js
git commit -m "feat(phone): let ShareSheet send Gallery media, not just text"
```

---

### Task 10: Client relay + Phone.vue wiring

**Files:**
- Modify: `plugins/oblsk_phone/client/main.lua`
- Modify: `plugins/oblsk_phone/web/Phone.vue`

**Interfaces:**
- Produces: every `camera-*`/`gallery-*` NUI event from Tasks 4/5/7/8/9 now has a real client-side relay (`WebView.on` for NUI→server, `Obelisk.onClient` for server→NUI), and `Camera`/`Gallery` are mounted as real routes in the phone shell. This is the task that makes the whole feature reachable end-to-end.

- [ ] **Step 1: Add the client relay for Camera events**

Add to `plugins/oblsk_phone/client/main.lua` (near the existing Messages relay block):

```lua
WebView.on('oblsk_phone:client:camera-capture-photo', function(data)
    Obelisk.emitServer('oblsk_phone:server:camera-capture-photo', data and data.albumId)
end)

WebView.on('oblsk_phone:client:camera-start-video', function(data)
    Obelisk.emitServer('oblsk_phone:server:camera-start-video', data and data.albumId)
end)

WebView.on('oblsk_phone:client:camera-stop-video', function(data)
    Obelisk.emitServer('oblsk_phone:server:camera-stop-video', data.captureId)
end)

Obelisk.onClient('oblsk_phone:client:camera-photo-saved', function(media)
    SendNUIMessage({ eventname = 'oblsk_phone:client:camera-photo-saved', args = { media } })
end)

Obelisk.onClient('oblsk_phone:client:camera-video-started', function(captureId)
    SendNUIMessage({ eventname = 'oblsk_phone:client:camera-video-started', args = { captureId } })
end)

Obelisk.onClient('oblsk_phone:client:camera-video-saved', function(media)
    SendNUIMessage({ eventname = 'oblsk_phone:client:camera-video-saved', args = { media } })
end)

Obelisk.onClient('oblsk_phone:client:camera-capture-failed', function(reason)
    SendNUIMessage({ eventname = 'oblsk_phone:client:camera-capture-failed', args = { reason } })
end)
```

- [ ] **Step 2: Add the client relay for Gallery events**

Add to `plugins/oblsk_phone/client/main.lua`:

```lua
WebView.on('oblsk_phone:client:gallery-albums', function(data)
    Obelisk.emitServer('oblsk_phone:server:gallery-albums')
end)

WebView.on('oblsk_phone:client:gallery-media', function(data)
    Obelisk.emitServer('oblsk_phone:server:gallery-media', data.albumId)
end)

WebView.on('oblsk_phone:client:gallery-create-album', function(data)
    Obelisk.emitServer('oblsk_phone:server:gallery-create-album', data.name)
end)

WebView.on('oblsk_phone:client:gallery-rename-album', function(data)
    Obelisk.emitServer('oblsk_phone:server:gallery-rename-album', data.albumId, data.name)
end)

WebView.on('oblsk_phone:client:gallery-delete-album', function(data)
    Obelisk.emitServer('oblsk_phone:server:gallery-delete-album', data.albumId)
end)

WebView.on('oblsk_phone:client:gallery-delete-media', function(data)
    Obelisk.emitServer('oblsk_phone:server:gallery-delete-media', data.albumId, data.mediaId)
end)

WebView.on('oblsk_phone:client:gallery-send-to-conversation', function(data)
    Obelisk.emitServer('oblsk_phone:server:gallery-send-to-conversation', data.mediaId, data.threadId)
end)

Obelisk.onClient('oblsk_phone:client:gallery-albums', function(albums)
    SendNUIMessage({ eventname = 'oblsk_phone:client:gallery-albums', args = { albums } })
end)

Obelisk.onClient('oblsk_phone:client:gallery-media', function(albumId, media)
    SendNUIMessage({ eventname = 'oblsk_phone:client:gallery-media', args = { albumId, media } })
end)

Obelisk.onClient('oblsk_phone:client:gallery-send-failed', function(reason)
    SendNUIMessage({ eventname = 'oblsk_phone:client:gallery-send-failed', args = { reason } })
end)

Obelisk.onClient('oblsk_phone:client:gallery-sent-to-conversation', function(threadId)
    SendNUIMessage({ eventname = 'oblsk_phone:client:gallery-sent-to-conversation', args = { threadId } })
end)
```

- [ ] **Step 3: Mount Camera and Gallery in `Phone.vue`**

In `plugins/oblsk_phone/web/Phone.vue`, add the imports (near the existing `import Messages from './apps/Messages/Messages.vue'`):

```js
import Camera from './apps/Camera/Camera.vue'
import Gallery from './apps/Gallery/Gallery.vue'
```

And add the routing branches (near the existing `<Messages v-else-if="app === 'messages'" />`):

```html
<Camera v-else-if="app === 'camera'" />
<Gallery v-else-if="app === 'gallery'" />
```

- [ ] **Step 4: Verify the web build**

Run: `cd core/web && npm run build`
Expected: build succeeds with no errors or unresolved-import warnings.

- [ ] **Step 5: Run the full backend test suite one more time**

Run: `npm test` (from `core/`) — expect every spec to pass, exit code 0, confirming nothing in this purely-client-relay/Vue-wiring task touched Lua server code in a way that broke anything.

- [ ] **Step 6: Commit**

```bash
git add plugins/oblsk_phone/client/main.lua plugins/oblsk_phone/web/Phone.vue
git commit -m "feat(phone): wire Camera/Gallery into the phone shell and NUI relay"
```

---

## Manual verification (not part of the automated suite)

`screencapture`'s video capture is explicitly experimental, and several assumptions in this plan (`Storage.uploadUrl()`'s port convar, `remoteUpload`'s exact failure-callback shape for a non-2xx response, `startVideoCaptureUpload`'s `result` shape) are the implementer's best-faith reading of `screencapture`'s README, not verified against a live capture. Before relying on this feature:

1. Start the stack with `screencapture` actually installed (`ensure screencapture` per Task 1), confirm no `[Storage]`/manifest-dependency errors on boot.
2. Take a real photo in-game via Camera, confirm it appears in Gallery's default "Camera Roll" album and the image actually loads.
3. Record a short video, confirm it saves and plays back; separately, try recording on a client where you suspect WebCodecs might be unavailable (older hardware/build) to see whether the `bytesReceived == 0` failure path in `CameraService.startVideo`'s callback actually triggers as expected rather than silently saving a broken row.
4. Create a second album, move a photo into it via the default-album-reassignment path (delete the album, confirm the photo is now in Camera Roll, not gone).
5. Send a photo to an existing Messages conversation via Gallery's "Send to conversation," confirm the recipient's Messages app shows it.
6. Hit the quota: set `phone_gallery_max_items` low (e.g. `2`) temporarily, confirm the third capture is rejected with a clear failure rather than erroring.

## Out of scope (matches the design spec)

- Sending photos to Bleeter (doesn't exist yet).
- Photo/video editing (filters, cropping, trimming).
- Cloud backup/sync.
- Live streaming (`screencapture` has this feature; unused here).
