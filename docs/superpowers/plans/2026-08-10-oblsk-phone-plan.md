# oblsk_phone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Given the scale of this plan (one plugin, ~25 internal apps), treat each numbered app section under [App Tasks](#app-tasks) as its own subagent-driven-development task, in the order listed; do not attempt to implement more than one app per dispatch.

**Goal:** Port the design system's phone prototype (`pages/phone.html` and everything it imports) from React to Vue 3 + Tailwind, as a single new Obelisk plugin, `oblsk_phone`. Every "app" on the phone's home screen (Dialer, Messages, MDT, Bleeter, games, etc.) is an internal module of this one plugin, not a separate plugin repo, gated by a config-and-App-Store toggle system — **except Banking, revised mid-build to live in its own plugin, `oblsk_banking`, see the note under Global Constraints and Task 9.** Dialer, Messages, and the App Store itself are the only mandatory apps; everything else can be disabled server-wide (admin config) or per-account (the in-phone App Store's install/uninstall flow).

**Source:** A Claude Design project (`claude.ai/design/p/019de78f-9966-77d9-90c0-73b12ead46cd`), read via the DesignSync tool. The prototype is plain React + Tailwind's CDN build, mounted with Babel-in-browser, no build step, no backend, most state living in module-level mutable objects with a `subs: Set()` pub/sub pattern (`BT_STORE`, `RADIO_STORE`, `NOTES_STORE`, `MAIL_STORE`, `HOME_STORE`, `WIDGET_STORE`, `DOCS_STORE`, `OPERATOR_STORE`, `PIC_STORE`, `MDT_AUDIT`) and `localStorage` (game high scores). None of this persists server-side; porting to Obelisk means designing a real schema and real Lua services behind every one of these stores.

**Explicitly out of scope:** Housing, Medic, and Lab UIs (referenced by contacts/tags in the prototype, e.g. "Realtor · Bea", "Dr. Iris Hahn") are excluded from this plan entirely, per instruction ("they need to be adjusted" — a future, separately-designed pass). Any place this plan's apps reference those concepts (e.g. a contact tagged "Housing") is a placeholder contact only, not a dependency.

## Global Constraints

- **One plugin, one repository — with one sanctioned exception.** `plugins/oblsk_phone`, own git repo, no worktree (nothing exists yet to protect). Every app below is `plugins/oblsk_phone/web/apps/<AppName>/*.vue` and `plugins/oblsk_phone/server/services/<AppName>Service.lua` (where it needs a backend), not a separate plugin — **except an app whose scope genuinely warrants its own plugin repo** (Banking is the first: it needs its own migrations/services independent of the phone's release cycle, and other plugins besides the phone may eventually want to read/write bank balances directly). Such a plugin registers itself into the phone rather than living inside it, via the two extension points below (both already implemented, added after Task 1 landed, not tracked as their own numbered task):
  - **Server-side catalog**: `PhoneAppRegistry.register({ app_key, name, mandatory })`, called from the contributing plugin's own `server/main.lua` at boot. Upsert-once-safe, mirrors `ActionService.register`'s shape. `oblsk_phone`'s own built-in apps are NOT registered this way, they're the static `PhoneAppRegistry.CATALOG` table; this call is only for apps living outside this repo.
  - **Client-side component discovery**: a `web/phoneApps.js` file in the contributing plugin's own repo, exporting `[{ app_key, component }]`, discovered by a glob in `Phone.vue` (`import.meta.glob('../../*/web/phoneApps.js', { eager: true })`), same convention as core's own `globalElements.js` glob. `Phone.vue`'s app-switch checks this registry as a fallback for any `app_key` it doesn't own itself.
- **App enable/disable is two-layered.** A server-wide config (`shared/config.lua`, a plain Lua table server owners edit, restart-only) lists which app keys exist at all on this server. A per-account/character install state (`phone_installed_apps`, polymorphic `owner_type`/`owner_id` like `oblsk_preferences`) tracks which of the server-enabled apps a given player has actually installed via the in-phone App Store. `dialer`, `messages`, `store` are always both server-enabled and pre-installed; nothing can uninstall them.
- **Reuse existing modules instead of duplicating their concepts.** MyFit's food/water rings read `CharacterService.getVitals(characterId).food/.drink` (from `oblsk_characters`, already has these columns, nothing calls them yet, this plugin becomes the first caller). Settings' flight-mode/DND/hide-number toggles are `PreferenceService` keys (from `oblsk_preferences`), scoped `character`, convention `phone:<setting>`, not a new table. Global-element visibility (the phone frame itself showing/hiding) uses the existing `WebView.showGlobalElement`/`hideGlobalElement`/`toggleGlobalElement` API and the `hud:phone:enabled` preference key the earlier `oblsk_phone` skeleton already established (see below).
- **This plan supersedes the earlier `oblsk_phone` skeleton.** A prior, much smaller pass already scaffolded `plugins/oblsk_phone` as a placeholder (`web/Phone.vue` rendering "Phone (placeholder)", `web/globalElements.js` registering it as a `phone` global element with `defaultVisible: false`). That registration point (the global element named `phone`, the `hud:phone:enabled` preference key it gets for free from `oblsk_preferences`'s hydrator) is kept; its placeholder `.vue` content is replaced wholesale by this plan's actual shell.
- **No native game integrations this plan doesn't already have a concrete plan for.** Real screenshot capture (Camera app), real waypoint-setting (Maps app), real weather sync (Weather app), real nearby-player detection (Bluetooth app), and real voice/radio integration (Radio app) are each flagged in their own app section below as a known gap with a stubbed fallback, not blocking the Vue port of that app's UI and its non-native backend (e.g. Maps' server-configured POIs and player-dropped pins persist and render correctly; only the "Set waypoint" button's actual native call is deferred).
- **Every mutable "store" object becomes a Pinia-free reactive composable**, matching the pattern `core/web/src/App.vue` already established for the global-elements registry (`reactive(new Map())`, no new state-management dependency). Each app's composable lives at `web/apps/<AppName>/store.js`, exporting a `use<AppName>()` function; server-backed data is fetched via `Obelisk.emit`/`Obelisk.on` round trips into the composable's reactive state, not polled.
- **Event naming**: `oblsk_phone:server:<app>-<action>` / `oblsk_phone:client:<app>-<action>`, matching the `<plugin>:<server|client>:<action>` convention established this session.
- No Claude co-authorship in any commit. Minimize em/en dashes in prose (commit messages, docs); not code/SQL.

## Architecture

### The App Store / config system

**Schema:**

`phone_apps` (catalog, seeded by a migration, one row per app key this plugin ships):

| Column | Type | Notes |
|---|---|---|
| `app_key` | string(50), unique | e.g. `'dialer'`, `'mdt'`, `'bleeter'` |
| `name` | string(100) | display name |
| `mandatory` | boolean | `dialer`/`messages`/`store` only |
| `server_enabled` | boolean | default `1`; a server owner can disable an app fleet-wide without a code change |

`phone_installed_apps` (per-owner install state, polymorphic like `preferences`):

| Column | Type | Notes |
|---|---|---|
| `owner_type` | string(20) | `'character'` (the phone is a per-character possession, not per-account, since a phone number ties to one character) |
| `owner_id` | integer | `characters.id` |
| `app_key` | string(50) | |
| `installed_at` | datetime | |

`unique({'owner_type', 'owner_id', 'app_key'})`.

**`PhoneAppService` (server):**

- `PhoneAppService.available()`: every `phone_apps` row where `server_enabled = 1`.
- `PhoneAppService.installed(characterId)`: every `phone_installed_apps` row for that character, joined against `available()` (an app disabled server-wide after install disappears from the phone without needing an uninstall).
- `PhoneAppService.install(characterId, appKey)` / `.uninstall(characterId, appKey)`: refuses on a mandatory `app_key` or one that's not currently `server_enabled`.

The home screen's `HOME_STORE.order` grid (from `phone.jsx`) is seeded from `installed()` on phone open, not from the prototype's hardcoded `HOME_DEFAULT` array. The App Store app (`store` in `phone.jsx`, the prototype's own icon grid + install/uninstall affordance already exists as a UI concept, currently disconnected from any real state) becomes the real `install`/`uninstall` caller.

### Vue component structure

```
plugins/oblsk_phone/
  web/
    Phone.vue                    -- replaces the placeholder; the draggable frame + status bar + nav (from phone.jsx's PhoneUI/PhoneStatus/PhoneNav)
    globalElements.js             -- unchanged registration, name: 'phone'
    router.js                     -- NOT core's page router; the phone's own internal app-switching state (`app`, `view` in PhoneUI), not a Vue Router instance
    apps/
      Home/                       -- home screen grid, widgets, edit mode, App Store install entry point
      Dialer/                     -- dialer, recents, in-call/group-call overlay (mandatory)
      Contacts/
      Messages/                   -- 1:1 + group threads (mandatory)
      Settings/                   -- flight/DND/hide-number via PreferenceService, not local state
      Store/                      -- the App Store itself (mandatory)
      Dispatch/
      Mdt/                        -- the single largest app, see its own section below
      -- Banking/ moved to its own plugin, plugins/oblsk_banking, see Task 9
      Mail/
      Files/                      -- generic cloud-drive-style file browser
      Paperwork/                  -- document templates/editor, shares a DocEditor component with Mdt's docs module
      Bleeter/                    -- social feed + camera + gallery
      Radio/
      Maps/
      Weather/
      Fit/                        -- reads CharacterService.getVitals
      Notes/
      Lawbook/                    -- reads the same law_books/charge_book schema Mdt owns, read-only
      Bluetooth/
      Games/
        Snake/ Skyhop/ Maze/ TicTacToe/ Chess/ Sketch/
  server/
    migrations/
    services/
```

### Shared components (not their own "app", used by several)

- `DocEditor.vue`: the rich-text, sign/redact/print/download document surface. `phone-docs.jsx`'s `MdtDocEditor` and the prototype's separate `Paperwork` app both need this; port once, both apps use it.
- `SkillCheck` components (`TimingCheck`/`SequenceCheck`/`DialCheck` from `skillcheck.jsx`): not phone-specific at all (used by mechanic/medic/drugs prototypes too, per the source file's own comment), but this plugin needs them for nothing right now, no phone app calls a skill check in the reviewed source. Port them into `core`'s own shared Vue components only if/when a future plugin actually needs them; not part of this plan.
- `ItemSlot`/`DndProvider` (`slot.jsx`): drag-and-drop inventory slot rendering. Nothing in the reviewed phone apps uses a grid inventory; skip porting this file for this plan.

### Backend service pattern (every app-with-state follows this)

1. A migration under `server/migrations/` for that app's tables, polymorphic `owner_type`/`owner_id` on `character` wherever the prototype's data was "mine" (threads, notes, bank accounts, installed apps), no owner column at all for genuinely global data (the law book text, server-configured map POIs).
2. A `server/services/<App>Service.lua` with plain functions (`list`, `get`, `create`, `update`, `delete` as needed), no dedicated model file unless the app's data shape earns one (mirrors `PreferenceService`'s precedent of skipping a model for a simple table).
3. A pair of `Obelisk.onServer`/`Obelisk.emitClient` handlers per read/write action, resolving the calling player's `characterId` via `CharacterService.getActiveCharacterId(source)` server-side, exactly like `oblsk_preferences`'s connect-hook pattern (client never supplies an id).
4. The Vue app's composable (`store.js`) calls through `client/main.lua`'s `RegisterNUICallback` relays (one shared relay file, `client/main.lua`, not one per app, matching how `oblsk_preferences`'s `client/main.lua` handles both its events).

## Known cross-app schema reuse

- **Law data.** `Lawbook` (a phone app) reads `law_books`/`charge_book` rows that `Mdt`'s laws module writes. One schema, owned by `Mdt`'s migrations (since MDT is where laws get published/amended), read-only from `Lawbook`.
- **Game scores.** All six minigames (`Snake`, `Skyhop`, `Maze`, `TicTacToe`, `Chess`, `Sketch` has no leaderboard) currently keep `localStorage`-backed per-game high-score arrays with fake seeded rivals. One shared table, `phone_game_scores` (`game_key`, `character_id`, `score`, `created_at`), not one table per game. `Maze`'s per-level board (`mzBoard(lv)`) becomes `game_key = 'maze', meta = {level: lv}` (a `json` column) rather than a `phone_game_scores_maze_levels` table.
- **Phone number.** Nothing in the reviewed source models a phone number as a first-class thing (contacts/threads reference display names and fake numbers like `555-0114` directly). This plan adds `characters.phone_number` (a new migration, unique, auto-assigned on character creation, format `555-XXXX`) since `Dialer`, `Messages`, `Contacts`, and `Radio`'s presets all implicitly need a stable identifier to route a call/message to the right player, and there is nowhere else in the framework that owns this concept yet.

## App Tasks

Each of the following is sized as one subagent-driven-development task (schema + service + Vue components for that app). Build order matters only for the "mandatory" tier (must exist for the phone to be usable at all) and for schema dependencies (`Lawbook` needs `Mdt`'s law tables to exist first); everything else can be built in any order.

### Task 1: Schema foundation and shell

- Migrations: `characters.phone_number` (altering `oblsk_characters`' own table, same cross-repo-migration convention as `accounts.max_characters`, since this module doesn't otherwise depend on `oblsk_characters` beyond `owner_type = 'character'`), `phone_apps`, `phone_installed_apps`.
- `PhoneAppService` (available/installed/install/uninstall) + tests (fake `QueryBuilder`, same pattern as every other module this session).
- Replace the placeholder `web/Phone.vue` with the real shell: draggable frame (`pos`, `grab`, charging-cable rendering), `PhoneStatus` (battery/signal/DND/flight/bluetooth icons), `PhoneNav` (back/home/app-switcher), the notification banner + notification-centre overlay, the control-centre quick-settings sheet. Home screen grid comes from `PhoneAppService.installed()`, not a hardcoded array.
- The app-switching state (`app`, `view`, `open` background-apps list) lives in `Phone.vue` itself; each app below is mounted by string key exactly like the prototype's `{app === 'dialer' && <AppDialer .../>}` chain, ported to a Vue `<component :is="...">` switch.

### Task 2: Dialer + Calls (mandatory)

- Depends on: Task 1's `characters.phone_number`.
- Migration: `phone_recents` (`character_id`, `direction`, `other_number`, `duration_seconds`, `at`).
- `Obelisk.emitServer`-routed call placing: caller's client asks the server to look up which character (if any) owns the dialled number, server relays a ringing event to that character's session if online, else the call fails with a "not reachable" state (the prototype's fake instant-answer/instant-decline flow becomes real cross-player signaling).
- Port `AppDialer`, `RECENTS` list backed by `phone_recents`, `PhoneCallOverlay` (in-call UI, mute/speaker/keypad/hold).
- **Known gap**: group calls (the prototype's `THREADS` group-chat concept extended to calls) are not in the reviewed source as a real feature, only implied by "group:true" contact tags; not built.

### Task 3: Contacts

- Migration: `phone_contacts` (`character_id`, `name`, `number`, `tag`, `favorite`, `flagged`).
- Port `AppContacts`. Contacts referencing a real other-character's number can show a live online/offline dot (`AccountService`/`CharacterService` session maps already expose this); contacts with no matching character (an NPC number) always show offline.

### Task 4: Messages (mandatory)

- Migrations: `phone_threads` (`id`, `is_group`), `phone_thread_members` (`thread_id`, `character_id`), `phone_messages` (`thread_id`, `sender_character_id`, `body`, `at`).
- Real delivery: sending a message resolves every other thread member's session (if online) and pushes it via `Obelisk.emitClient`; offline members see it on next connect via a `list unread since last seen` query, no push-notification infrastructure needed beyond what already exists.
- Port `AppMessages`, `ShareSheet` (the "share this to a conversation" bottom sheet every other app's share button reuses), `shareToThread`.

### Task 5: Settings

- No new schema. Every toggle (`flight`, `hideNum`, `dnd`) is a `PreferenceService` call, scoped `character`, keys `phone:flight_mode`/`phone:hide_number`/`phone:dnd`. Port `AppSettings`, wiring its toggles to `Obelisk.emit('oblsk_preferences:client:set', ...)` directly (this app is the first real caller of that write path outside the hydrator).

### Task 6: App Store (mandatory)

- Depends on: Task 1's `PhoneAppService`.
- Port the prototype's `store` app concept into a real install/uninstall browser over `PhoneAppService.available()`/`.installed()`, showing every server-enabled app with an install/uninstall button, mandatory apps shown as permanently installed.

### Task 7: Dispatch

- Migration: `phone_dispatch_calls` (mirrors `DISPATCH_CALLS`' shape: `type`, `location`, `priority`, `units_json`, `created_at`).
- Port `AppDispatch`. **Gap resolved since this plan was written**: unit assignment/status (`UNIT_STATUS`) originally had no real job-system integration (no LSPD job/duty module existed). `modules/oblsk_organizations` now provides that: a "unit" can be a real `OrganizationService.getMembership(characterId, lspdOrgId)` row (department = which unit, e.g. "Patrol"/"SWAT"), so the roster lookup can be real instead of a free-text field — a decision for whoever starts this task, since a free-text field may still be preferred for simplicity; this is no longer a hard gap either way.

### Task 8: MDT (the largest single task, likely worth its own follow-up plan)

The MDT terminal (`mdt.jsx` + `mdt-audit.jsx` + `mdt-case-flow.jsx` + `mdt-data.jsx` + `mdt-docs.jsx` + `mdt-find.jsx` + `mdt-modules.jsx` + `mdt-staff.jsx`) is bigger than every other app in this plan combined: case files with a full lifecycle state machine (open → investigation → prosecution → court → verdict → appeal, cross-agency LSPD/LSMD/DOJ permission grants per document), citizens/vehicles/impound/detention records, a document editor with redaction/signing/printing, an audit trail, employee records with duty-hour tracking and a rank salary table, law books with amendment history, a blackboard, a calendar, and the phone-lines/911-operator console (`phone-calls.jsx`'s `MdtLines`, shared with the Dialer's call-answering machinery).

Given this scale, this task should be treated as: (a) port the MDT *shell* (`mdt.jsx`'s `Pill`/`MdtPanel`/`MdtSearch` primitives, the module-switching frame, the `files` app's landscape-mode "the device opens into a tablet" behavior from `phone.jsx`) plus (b) `cases`, `citizens`, `docs` (the three modules every other MDT module links back to) in this pass, and (c) explicitly park `vehicles`/`admin`/`manhunts`/`impound`/`detention`/`board`/`calendar`/`staff`/`laws` as a follow-up plan once (a) and (b) are proven, rather than attempting all eleven MDT modules in one task. Schema for (b):

- `mdt_cases` (`case_number`, `db_group` [`ls-shared`/`lsmd`], `title`, `status`, `priority`, `lead_character_id`, `narrative`, `stage`, `settle_json`, `restricted_depts_json`, `opened_at`), `mdt_case_charges` (`case_id`, `charge_code`), `mdt_case_people` (`case_id`, `name`, `role`, `citizen_id` nullable), `mdt_case_officers` (`case_id`, `character_id`, `role`), `mdt_case_shares` (`case_id`, `shared_with_auth`, `scope`, `until`), `mdt_case_stages` (`case_id`, `at`, `stage`, `by_character_id`, `note`), `mdt_case_hearings` (`case_id`, `who`, `kind`, `body`, `at`, `by_character_id`).
- `mdt_citizens` (`db_group`, `name`, `dob`, `phone_number` nullable FK to a real phone, `bank_account` nullable, `address`, `wanted`, `wanted_for`), `mdt_citizen_licenses` (`citizen_id`, `license`), `mdt_citizen_vehicles` deferred to the parked `vehicles` module.
- `mdt_documents` (`title`, `template_id`, `kind`, `auth`, `attach_kind` nullable, `attach_id` nullable, `author_character_id`, `status`, `body`, `perm_read_json`, `perm_write_json`, `orgs_json`, `org_write_json`), `mdt_document_versions` (`document_id`, `at`, `by_character_id`, `what`, `body`).
- `mdt_audit_log` (`at`, `character_id`, `auth`, `module`, `what`, `ref` nullable). Every write in every MDT module (including the parked ones, once built) inserts one row here; this table itself is Task 8's, other tasks in a future MDT follow-up plan just call `MdtAuditService.log(...)`.

**Gap resolved since this plan was written**: the permission model (`mdtCan`, rank/department gates, cross-agency read/write grants) originally assumed a rank/department system for police/medical/justice characters that didn't exist anywhere in the framework. It now does: `modules/oblsk_organizations` (organizations/departments/ranks/memberships) plus core's `PermissionService`/`HasPermissions` (a generic, polymorphic permission-grant mechanism, `Character:can(key)` walking through a character's rank/department grants via `PermissionService.addDelegate`). This task should model LSPD/LSMD/DOJ as real `oblsk_organizations` rows (one org each, or one shared org with departments per agency, a decision for whoever starts this task) and cross-agency read/write grants as named permission keys granted to specific ranks/departments (e.g. `PermissionService.grant('department', lsmdDeptId, 'mdt-write-medical-case')`), checked via `Character:can(key)` server-side before any MDT write — instead of the originally-planned `character.mdt_auth`/`character.mdt_rank`/`character.mdt_depts` stub columns, which should NOT be built now that the real mechanism exists. `oblsk_phone`/`oblsk_organizations` stay decoupled the same way `oblsk_organizations`/`oblsk_characters` already are: MDT's service code calls `CharacterService`/`OrganizationService`/`PermissionService` as plain cross-module globals, no migration-level dependency.

### Task 9: Banking — MOVED to its own plugin, `plugins/oblsk_banking`

Revised mid-build, after this plan was originally written: Banking needs its own migrations/services independent of the phone's release cycle, and other plugins besides the phone may eventually want to read/write bank balances directly, so it no longer lives inside `oblsk_phone`. `plugins/oblsk_banking` is already scaffolded as its own git repo (currently empty, no commits) — this task is now that plugin's own plan, not a task here. When it's built:

- Same schema shape as originally planned (`bank_accounts`, `bank_transactions`), but living in `oblsk_banking`'s own migrations, and account ownership should be polymorphic (`owner_type`/`owner_id`) rather than `character_id`-only + a `shared` bool, since `modules/oblsk_organizations` now exists and an org-owned account (a gang treasury, a PD budget) is a real, expected case, not a hypothetical — `owner_type = 'character'` or `'organization'`.
- Withdrawal/transfer limits on an org-owned account should be a `PermissionService` grant on the relevant `Rank`/`Department` (e.g. `manage_bank`), checked via `Character:can('manage_bank')` (which walks through the character's rank/department grants automatically, see Task 8's note above) — not a bespoke permission system inside the banking plugin.
- Registers itself into the phone via `PhoneAppRegistry.register({ app_key = 'banking', name = 'e-Banking' })` (server boot) and a `web/phoneApps.js` export (client), per the Global Constraints note above. `oblsk_phone` never gains a dependency on `oblsk_banking`.
- Port `AppBank` (referenced by `phone.jsx`'s app switch and `WidgetBank`, not among the files read for the original phone plan; fetch `src/proto/banking.jsx` before starting) and `ShopUI`'s card-payment flow (`shop.jsx`), which spends against these same accounts.
- **Known gap, unchanged**: no real economy/currency module exists yet; balances here are this plugin's own ledger, not tied to a server-wide cash system. A future Economy module may need to reconcile with this table.

### Task 10: Mail

- Migration: `phone_mail_accounts` (`character_id`, `address`, `label`, `shared` bool), `phone_mail_messages` (`account_id`, `from_addr`, `subject`, `body`, `box`, `unread`, `at`).
- Port `AppMail` (referenced but not among the fetched files; fetch `src/proto/*.jsx` for it before starting, likely alongside `docs.jsx`/`cloud.jsx` if those exist as separate files, the file list returned by `list_files` didn't show a dedicated `mail.jsx`/`cloud.jsx`/`docs.jsx` under `src/proto/`, only `phone.jsx`'s app switch references `AppMail`/`AppDocs`/`AppCloud`/`AppFiles`/`AppStore`; these may be defined inline in `phone.jsx`'s un-read tail or in a file not yet fetched, confirm before starting).

### Task 11: Files / Paperwork

- Shared `DocEditor.vue` (see Architecture) ported once here, reused by Task 8's MDT docs module.
- Migration: `phone_paperwork_documents` (`character_id`, `kind`, `title`, `client` nullable, `date`, `due` nullable, `items_json` nullable, `tax` nullable, `notes` nullable, `body` nullable for letter/contract/memo kinds).
- Port `AppPaperwork` (`phone-paperwork.jsx`, only partially read for this plan, its middle/tail content was truncated by output size, re-read the full file before starting this task) and the shared `pwSetLand`/`usePwLand` device-orientation behavior (opening a document flips the whole phone frame to landscape, `Phone.vue`'s `land` computation already accounts for `app === 'paper' && pwLand`).

### Task 12: Bleeter (social)

- Migrations: `phone_bleeter_accounts` (`character_id`, `handle` unique, `display_name`, `avatar_color`, `bio`, `private` bool), `phone_bleeter_posts` (`account_id`, `body`, `photo_ref` nullable, `at`), `phone_bleeter_likes` (`post_id`, `account_id`), `phone_bleeter_replies` (`post_id`, `account_id`, `body`, `at`).
- Port `BleeterRegister` (account creation gate), `AppBleeter` (feed, thread/likers sheets, composer, in-app camera stub), `AppCamera`, `AppGallery`.
- **Known gap, explicit**: `AppCamera`'s "photo" is a solid-color placeholder in the prototype (no real image); a real port needs an actual screenshot-capture native or leaves this as a color-swatch placeholder indefinitely. Flag for the user to decide before this task starts, don't guess.

### Task 13: Radio

- Migration: `phone_radio_presets` (`character_id`, `frequency`, `label`).
- Port `AppRadio` (dual-channel, keypad tuning, saved presets, simulated traffic).
- **Known gap, explicit**: no real proximity voice/radio system exists in the framework; this app's "transmitting"/"receiving" state and the simulated traffic log are decorative only until a real voice-radio integration is designed, which is a separate, much larger project (likely its own future module, not part of this plan).

### Task 14: Maps

- Migration: `phone_map_pois` (server-configured, admin-managed, `name`, `category`, `x`, `y`, `note`, `interactions_json`), `phone_map_pins` (player-dropped, `character_id`, `name`, `x`, `y`).
- Port `AppMaps`, `MapPlate`, `MapPin`. Real GTA V map tiles load from the public `gta5-map.github.io` tile set exactly as the prototype does (an external image CDN, not something this plugin hosts).
- **Known gap, explicit**: "Set waypoint" is decorative (a toast message) in the prototype; a real port calls `SetNewWaypoint`, a client native, trivial to add but not exercised by the prototype's own code, confirm the exact in-world behavior wanted (does it override the player's own map blip, etc.) before wiring it for real.

### Task 15: Weather

- No new schema; read-only. Port `AppWeather`, `WX_ICONS`.
- **Known gap, explicit**: the prototype's weather data is static (`WX_NOW`/`WX_HOURS`/`WX_DAYS`). A real port either stays decorative or syncs to FiveM's actual weather system (`GetWeatherTypeTransition`); decide before building, this plan doesn't assume either.

### Task 16: MyFit

- No new schema. Reads `CharacterService.getVitals(characterId).food`/`.drink` from `oblsk_characters` (a real cross-plugin dependency this plugin declares, same "no code dependency, session/global-call only" convention `oblsk_preferences` uses for `AccountService`/`CharacterService`). `stamina` and `steps` have no home in `oblsk_characters` yet (`stamina` column exists but nothing writes it; `steps` doesn't exist anywhere) — this app's stamina/steps rings stay decorative (a locally-generated placeholder number) until something writes real values, flagged, not blocking.
- Port `AppFit`, `FitRing`, `FitBar`.

### Task 17: Notes

- Migration: `phone_notes` (`character_id`, `title`, `body`, `pinned`, `at`).
- Port `AppNotes`.

### Task 18: Lawbook

- Depends on: Task 8's `mdt_documents`-adjacent law schema. Add `mdt_law_books` (`abbr`, `name`, `version`, `published_at`) and `mdt_law_sections` (`book_id`, `parent_id` nullable, `number`, `title`, `body`, `pen_json`) as part of Task 8, not this task, since MDT is where laws get authored; this task is read-only against them.
- Port `AppLawbook` (text/offences/amendments tabs), reading `mdt_law_books`/`mdt_law_sections`/`mdt_case_charges`' `CHARGE_BOOK` equivalent.

### Task 19: Bluetooth

- No new schema (Bluetooth is a transfer mechanism over existing data: files, photos, map pins, contacts, phone number, bank account, per `BT_KINDS`).
- Port `PhoneBluetooth`. **Known gap, explicit**: "nearby devices" in the prototype is a fake timed reveal of a hardcoded list; a real port needs an actual in-world proximity check (distance between two players' peds), a native/gameplay concern this plan flags but doesn't design, since it depends on how far along any future job/proximity-interaction system is.

### Task 20: Games

Depends on: the shared `phone_game_scores` table (Architecture section). One subtask per game, each small enough to bundle into a single dispatch if done together, or split further if any one proves larger than expected:

- **Snake** (`phone-snake.jsx`): port `AppSnake`, swap `localStorage` reads/writes for `phone_game_scores` calls (`game_key = 'snake'`).
- **Skyhop** (`phone-games.jsx`'s `AppSkyhop`): same swap.
- **Labyrinth/Maze** (`phone-games.jsx`'s `AppMaze`): same swap, `meta = {level}` json column per the Architecture note.
- **Tic-tac-toe and Chess** (`phone-games-vs.jsx`): these are two-player, not just leaderboard-backed. **Known gap, explicit**: the prototype's "invite a friend" flow fakes the opponent joining after a timeout; a real port needs actual match-state relay between two players' phones via `Obelisk.emitClient` (whoever's turn it is, sent moves), which this task should build (the move-application logic, `chMoves`/`chApply`/`ttt` win-check, already exists and is pure, portable as-is; only the transport is new). Bot-vs-player mode (`chPick`'s two-ply greedy AI) needs no networking and ports directly.
- **Sketch** (`phone-draw.jsx`): port `AppSketch`, canvas drawing is entirely client-side already (no backend needed beyond saving the resulting image alongside Bleeter's gallery/camera storage from Task 12).

### Task 21: Widgets

- Depends on: every app it can surface a widget for (Radio, Banking, Bleeter, MDT, Weather, Fit, Notes) already existing. `WidgetBank` now reads from `oblsk_banking` (its own plugin, see Task 9), a cross-plugin read the same way MyFit reads `oblsk_characters` — no new pattern needed.
- Migration: `phone_home_widgets` (`character_id`, `widget_key`, `slot`).
- Port the widget placement system (`widgetCells`/`canPlaceWidget`/`placeWidget`/`firstWidgetSlot`) and each `Widget*` component, reading real data from the now-real app backends instead of the prototype's shared in-memory stores.

## Revision notes (post-Task-2, mid-build)

- Banking moved out of this plan entirely, into its own plugin (`plugins/oblsk_banking`, scaffolded, empty). See the Global Constraints exception and the rewritten Task 9.
- The phone gained a real cross-plugin app-registration mechanism (`PhoneAppRegistry.register` + `web/phoneApps.js` glob) so Banking (and any future similarly-scoped app) can register into the phone without living inside this repo.
- `modules/oblsk_organizations` + core's `PermissionService`/`HasPermissions` now exist, resolving the rank/department/permission gaps this plan originally flagged as unsolved in Task 7 (Dispatch) and Task 8 (MDT) — both sections updated above. Nothing else in this plan changes as a result; the remaining tasks (3-6, 10-21) were written without assuming a jobs/orgs system and don't need it.

## Self-review notes (from writing this plan)

- Two apps referenced by `phone.jsx`'s app switch (`AppMail`, `AppDocs`, `AppCloud`, `AppStore`, `AppFiles`) were never found as their own fetched `.jsx` file; either they're defined in a part of `phone.jsx` past what was read for this plan (confirmed truncated by output size, see Task 10/11's notes), or in a file not in this plan's original file list. Whoever starts Task 10 or Task 11 must re-fetch and read `phone.jsx` in full (and search `list_files`'s output for any `src/proto/*.jsx` not yet fetched) before writing that task's brief, not guess at these apps' shape from name alone.
- This plan's MDT task (Task 8) is, on its own, roughly the size of the Accounts + Characters + Preferences modules combined from earlier this session. Treat its "park most modules for a follow-up plan" scoping as load-bearing, not optional, revisit with the user explicitly before attempting all eleven MDT modules in one pass.
- Several tasks (`Bleeter`'s camera, `Radio`, `Maps`' waypoint, `Bluetooth`'s proximity, `Weather`'s sync) each have one explicit, named "known gap" requiring a product decision (native integration vs. stay decorative) that this plan deliberately does not make on the user's behalf; each task's brief must carry that open question forward, not silently pick an answer.
