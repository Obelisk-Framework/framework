# oblsk_mdt: Mobile Data Terminal plugin design

**Goal:** Build the MDT (Mobile Data Terminal) as its own plugin, `oblsk_mdt`, registering itself into `oblsk_phone` as a phone app via the existing cross-plugin extension points, rather than living inside `oblsk_phone`. All 15 modules from the source design are in scope for this pass (no phased follow-up).

**Source:** A Claude Design project (`claude.ai/design/p/019de78f-9966-77d9-90c0-73b12ead46cd`), `src/proto/mdt.jsx`, `src/proto/mdt-modules.jsx`, `src/proto/mdt-data.jsx`, read via the DesignSync tool.

**Supersedes:** Task 8 of `docs/superpowers/plans/2026-08-10-oblsk-phone-plan.md`, which originally scoped MDT to live inside `oblsk_phone` and be built in a shell+cases/citizens/docs pass with the rest parked. That task is now superseded: MDT is a separate plugin, and this design covers the full module set.

## Architecture

- New plugin `oblsk_mdt`, own git repository (`core/plugins/oblsk_mdt`), own migrations/services — not a directory inside `oblsk_phone`.
- Registers into the phone via the two extension points already implemented in `oblsk_phone`:
  - Server-side: `PhoneAppRegistry.register({ app_key = 'mdt', name = 'MDT' })`, called from `oblsk_mdt`'s own `server/main.lua` at boot.
  - Client-side: a `web/phoneApps.js` file in `oblsk_mdt` exporting `[{ app_key: 'mdt', component }]`, discovered by `Phone.vue`'s `import.meta.glob('../../*/web/phoneApps.js', { eager: true })`.
  - This requires removing the static `{ app_key = 'mdt', name = 'MDT' }` entry from `oblsk_phone`'s `PhoneAppRegistry.CATALOG` (`server/services/PhoneAppRegistry.lua`) — the same move already made for Banking.
- Three separate `oblsk_organizations` organizations — LSPD, LSMD, DOJ — each with their own departments and ranks, matching the design's `AUTH_DEPTS`/`AUTH_RANKS`:
  - LSPD depts: Patrol, Traffic, Detective Bureau, Air Support, Academy, Command.
  - LSMD depts: Pillbox Hill, Sandy Shores, Air Ambulance, Field Operations, Training.
  - DOJ depts: Criminal Division, Civil Division, Judiciary.
  - Ranks per org per the design's `AUTH_RANKS` table.
- A character's active MDT "authority" (`lspd`/`lsmd`/`doj`) is derived from their `oblsk_organizations` membership, not stored as an MDT-specific field. If a character holds membership in more than one of the three orgs, MDT shows the design's authority switcher; otherwise the authority is implicit and no switcher is shown.
- DB isolation: LSPD and DOJ share case/citizen data (the design's `'ls-shared'` group), LSMD is walled off (`'lsmd'`). Modeled as a `db_group` column on `mdt_cases`/`mdt_citizens` (and similar), derived from the acting character's org at write time — not separate schemas or databases.
- Permission gating uses the existing `PermissionService`/`HasPermissions` mechanism (`Character:can(key)`), with grants scoped to org/department/rank. No new permission system. Cross-agency reads/writes (e.g. DOJ reading an LSPD case) are named permission keys (e.g. `mdt-write-medical-case`) granted via `PermissionService.grant(...)` to specific ranks/departments, checked server-side before every MDT write.
- The Command Centre (fleet/unit drag-drop assignment board) and Phone Lines (911 operator console) modules call into `oblsk_phone`'s existing `DispatchService`/`phone_dispatch_calls` as a cross-plugin dependency, rather than duplicating a call-queue table. `oblsk_mdt` adds only its own fleet/unit-assignment tables on top.
- `oblsk_mdt` and `oblsk_phone` stay decoupled the same way `oblsk_organizations`/`oblsk_characters` already are: cross-module calls to `CharacterService`/`OrganizationService`/`PermissionService`/`DispatchService` as plain globals, no migration-level dependency between the two plugins' schemas.

## Module map

Each module below is `plugins/oblsk_mdt/web/apps/<Module>/*.vue` plus `server/services/<Module>Service.lua` where it needs a backend.

| Module (`app_key` in nav) | Backend tables (new) | Notes |
|---|---|---|
| `command` | `mdt_unit_assignments`, `mdt_department_fleet` | drag-drop unit/vehicle assignment board; reads `oblsk_phone.phone_dispatch_calls` for the live call feed |
| `cases` | `mdt_cases`, `mdt_case_charges`, `mdt_case_people`, `mdt_case_officers`, `mdt_case_shares`, `mdt_case_stages`, `mdt_case_hearings` | full lifecycle state machine: open → investigation → prosecution → court → verdict → appeal |
| `citizens` | `mdt_citizens`, `mdt_citizen_licenses` | `vehicles`/`houses` are read from the `vehicles` module and a future housing reference, not embedded columns |
| `docs` | `mdt_documents`, `mdt_document_versions` | rich-text doc editor with redact/sign/print/download; shares a `DocEditor.vue` component with `oblsk_phone`'s Paperwork app — ported into `core`'s shared Vue components since two separate plugins now consume it |
| `vehicles` | `mdt_citizen_vehicles` | registration records, links to `impound` by plate |
| `audit` | `mdt_audit_log` | every write in every module inserts one row here via `MdtAuditService.log(...)` |
| `admin` | none new | department/rank management surface, backed by `oblsk_organizations`/`PermissionService` calls directly, no own table |
| `lines` | none new | 911 operator console; reads/answers via `oblsk_phone`'s `DispatchService`, shared with the Dialer's call-answering machinery |
| `manhunts` | `mdt_manhunts` | active/cleared BOLO-style alerts |
| `impound` | `mdt_impound` | |
| `detention` | `mdt_detention` (active), `mdt_detention_archive` | |
| `laws` | `mdt_law_books`, `mdt_law_sections`, `mdt_law_amendments` | `Lawbook` (an `oblsk_phone` app) reads these read-only; `oblsk_mdt` owns the schema since MDT is where laws get published/amended |
| `board` | `mdt_board_posts`, `mdt_board_reads` | department blackboard/notices |
| `staff` | `mdt_staff_meta` (duty status, salary, cam flag) | roster identity comes from `oblsk_organizations` membership; this table holds only MDT-specific extras not modeled elsewhere |
| `calendar` | `mdt_calendar_events`, `mdt_holiday_requests` | |

Shell: `Mdt.vue` — the ruggedised-tablet chrome, module nav (gated per-authority, matching each module's `auth` list in the design), auth switcher (only shown for multi-org characters), toast/notification plumbing. Ported from `mdt.jsx`'s `MdtScreen`.

## Data flow

- Every module with a backend follows the same pattern already established across this framework: a migration under `server/migrations/`, a `server/services/<Module>Service.lua` with plain CRUD functions, a matching pair of `Obelisk.onServer`/`Obelisk.emitClient` handlers per action resolving the calling player's `characterId` server-side via `CharacterService.getActiveCharacterId(source)` (never client-supplied), and a Vue composable (`store.js` per app) that round-trips through `client/main.lua`'s shared `WebView.on()` relay.
- Event naming: `oblsk_mdt:server:<module>-<action>` / `oblsk_mdt:client:<module>-<action>`.

## Error handling

- Every write handler calls `Character:can(key)` before touching data. A denied check returns a normal "forbidden" response, not an error/crash; the UI surfaces it as a toast (`ctx.flash` in the source design).
- Cross-agency reads/writes outside the acting character's `db_group` are refused server-side the same way, not merely hidden in the UI.

## Audit trail

Every module's write path — not just `cases`/`docs` — inserts one `mdt_audit_log` row via `MdtAuditService.log(...)`, matching the design's per-module `mdtAudit(ctx, module, what)` calls throughout the prototype.

## Testing

One spec file per service, fake `QueryBuilder`, matching the convention already used by every other module this session (`oblsk_organizations`, `oblsk_characters`, `oblsk_items`, etc.): unit tests for CRUD paths plus permission-denial paths. No integration or browser tests.

## Out of scope

Carried over from the original phone plan, still true here: Housing, Medic, and Lab cross-references (contacts/tags like "Realtor · Bea", "Dr. Iris Hahn") stay placeholder contacts, not real integrations. No native screenshot/waypoint integrations beyond what already exists elsewhere in the framework.
