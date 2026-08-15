# oblsk_mdt Command/Lines rework + real flight-mode/DND design

**Goal:** Replace the placeholder `mdt_unit_assignments` model with a real on-duty-roster-based Command centre, turn `oblsk_mdt`'s Phone Lines module into an actual emergency-line registration/failover system wired into `oblsk_phone`'s dialer, and make flight-mode/DND real, server-observed state instead of cosmetic client-only toggles.

**Supersedes:** The `command`/`lines` rows of `2026-08-11-mdt-plugin-design.md`'s module map, which scoped both to read `oblsk_phone`'s `DispatchService`/`phone_dispatch_calls` (the dispatcher CAD board) as their only cross-plugin dependency. That table is a separate, still-untouched system (incident records a dispatcher tracks, not real ringing phone calls) — this design does not change it. Command/Lines' actual cross-plugin dependency is `oblsk_phone`'s `DialerService`/`PhoneNumberService` (real 1:1 ringing calls), which the original design didn't anticipate needing.

**Context:** Command and Lines were built once already this session against the original module map (free-text `unit_id` upserted into `mdt_unit_assignments`, both modules showing the same dispatch-board read). That build works but doesn't match what either module is actually for. This design replaces it, not extends it.

## Scope split

- **Command centre**: fleet management + who's driving what. On-duty roster × vehicle fleet, assign/unassign.
- **Phone lines**: emergency-line registration (primary/passive per line) + real call routing with failover, via `oblsk_phone`'s dialer.
- **Flight mode / DND**: real per-character reachability state, gating message push, dialer ringing, and the character's own MDT access — needed by Lines' failover logic, but scoped as its own piece since it also affects Messages and the phone shell generally.

## Part 1 — Command centre

### Data model change

Drop `mdt_unit_assignments` (never shipped to real players; safe to replace outright, not migrate). A "unit" is not a free-standing entity — it's simply an on-duty officer. Add `assigned_vehicle_id` (nullable, FK-by-convention to `mdt_department_fleet.id`, same loose-FK style every other table in this plugin uses — no DB-level FK constraint, just an integer column) to the existing `mdt_staff_meta` table (already tracks `status`/`cam` per character per org).

- `MdtStaffService` gains `setAssignedVehicle(characterId, auth, orgId, targetCharacterId, vehicleId)` — same shape/permission gate (`mdt-write-staff`, reusing the existing key rather than inventing `mdt-write-command` for this one field) as `setDuty`/`setCam`.
- `buildStaffList` (the `main.lua` composition helper) picks up `assigned_vehicle_id` alongside `status`/`cam` in its per-row assembly, same as today.
- `mdt_department_fleet` (vehicle catalog) is unchanged — still admin-curated, still read via `MdtCommandService.fleet(orgId)`.

### UI

Command centre becomes: fleet list (from `command-fleet`, unchanged event) + on-duty roster (reuses `staff-list`, now carrying `assigned_vehicle_id`) with a real dropdown to assign any on-duty officer to any fleet vehicle — no more free-text unit ids, no more raw character-id input. Assignment write goes through the new `MdtStaffService.setAssignedVehicle` via a new event `oblsk_mdt:server:staff-set-vehicle` (re-emits `staff-list`, matching `staff-set-duty`/`staff-set-cam`'s convention exactly).

`MdtCommandService.assign`/`assignments` and the `mdt_unit_assignments` table are deleted outright (migration `down` for the original creating migration, or a fresh drop-migration — whichever this plugin's convention prefers for removing a never-shipped table; check how a prior phase in this plugin handled deleting an unused table, if any precedent exists, otherwise a straightforward `Schema.drop` migration is fine since no real data exists in it).

## Part 2 — Phone lines

### Data model (new)

- `mdt_lines`: `id, organization_id, number (string, unique across the whole table — see note below), label (string)`.
  - **Uniqueness note**: `number` is enforced unique at the row level. The user has confirmed they will not configure the same number for two different orgs in practice, so this is a hard constraint, not a soft convention — dialing a number resolves to at most one line, no collision-resolution logic needed anywhere in this design.
  - One org can have multiple lines (e.g. an org's "911" and a separate "non-emergency" number).
- `mdt_line_registrations`: `id, line_id (indexed), character_id, role (string, 'primary'|'passive'), registered_at`.
  - At most one `primary` and one `passive` row per `line_id`, enforced in the service via upsert-by-role (delete-then-insert or update-if-exists, matching `MdtCommandService.assign`'s existing upsert pattern for a per-key single row), not a DB constraint.

### Service (`MdtLineService`, new)

- `list(orgId)` — lines for an org, with their current primary/passive registrations joined in (per-row lookup against `mdt_line_registrations`, same "no join support, loop it" precedent used throughout this plugin).
- `create(characterId, auth, orgId, number, label)` / `delete(characterId, auth, lineId)` — admin-managed (gated `mdt-admin`, matching how templates/pinning were gated in the Docs+Admin phase — line configuration is an admin action, not a general officer action).
- `register(characterId, auth, orgId, lineId, role)` — an officer registers themselves as primary or passive on a line their own org owns (refuse if the line's `organization_id` doesn't match `orgId`). Upserts by `(line_id, role)`.
- `unregister(characterId, auth, lineId, role)`.
- `resolveByNumber(number)` — **called cross-plugin by `oblsk_phone`'s `DialerService`**, not exposed as an `Obelisk.onServer` event. Returns `{lineId, organizationId, primaryCharacterId, passiveCharacterId}` or `nil`. This is the one function `oblsk_phone` needs to know about `oblsk_mdt`; mirrors the existing reverse-direction precedent (`MdtCommandService.activeCalls()` already calls `DispatchService.list()` as a plain cross-plugin global function call, no event round-trip).

### Call routing change (`oblsk_phone`)

`DialerService.call(callerSource, targetNumber)` gains a fallback path, tried only when `PhoneNumberService.resolveCharacterId(targetNumber)` finds no personal-number match:

1. Call `MdtLineService.resolveByNumber(targetNumber)`. If nil, existing `'unknown number'` behavior is unchanged.
2. If a line resolves: attempt to ring the **primary**.
   - Skip straight to **passive** without ringing primary at all if the primary is unreachable outright: offline, already in `DialerService.activeCalls` (busy), or `phone:flight_mode` is true for them (see Part 3) — these are all "can't possibly answer" states, no point ringing.
   - Otherwise, ring the primary with a new ring-timeout (`DialerService` has no timeout today — add one; 15 seconds is a reasonable default, exact value not load-bearing to this design). No answer within the timeout, or an explicit decline → fall through to the passive using the same reachability check.
3. If the passive is also unreachable (by the same check) or also rings out → the call fails, exactly like dialing any other unreachable number today. No queueing, no retry, no voicemail — confirmed explicitly out of scope.
4. If there is no passive registered at all and the primary doesn't answer → same "call fails" outcome.

This is genuinely new logic in `DialerService`, not a thin wrapper — the existing service has no ring-timeout and no failover concept at all today (confirmed via research: strictly 1:1, first-and-only target, no busy-check consulted anywhere).

## Part 3 — Flight mode / DND

### Current state (confirmed via research, not assumed)

The storage layer already exists and is real: `Settings.vue` already writes `phone:flight_mode`/`phone:dnd` (booleans) to `oblsk_preferences` (character-scoped) via the standard `oblsk_preferences:client:set` event. The gap is that `Phone.vue` maintains its **own separate, disconnected** local `flight`/`dnd` refs (used by the control-centre quick-toggle and a client-side-only delivery simulation) that never read from or write to the same preference keys Settings.vue uses. Two toggles, not synced.

### Fix: single source of truth

`Phone.vue`'s `flight`/`dnd` refs are replaced with values hydrated from `oblsk_preferences` (same pattern `PreferencesHydrator.vue` already establishes elsewhere in this plugin) and every write (from either the Settings screen or the quick-toggle) goes through `oblsk_preferences:client:set` on the same keys. No new client state.

### Server-side gating — flight mode only

DND does **not** gate anything server-side (see below). Flight mode gates four real points, each behind a plain `PreferenceService.get('character', characterId, 'phone:flight_mode')` call (a synchronous global function already usable cross-service, same convention as `MdtAuditService.log`):

1. **Messages** (`oblsk_phone/server/main.lua`, `oblsk_phone:server:messages-send` handler): the message is still stored normally via `MessagesService.send` (so it's there when the recipient next opens Messages — flight mode defers live delivery, it doesn't destroy the message, matching real airplane-mode semantics). The live per-recipient push (`Obelisk.emitClient('oblsk_phone:client:messages-new', recipientSource, ...)`) is skipped for any recipient currently in flight mode.
2. **Direct dialer calls** (`DialerService.call`): if the target number resolves to a real personal number (not a line) and that character is in flight mode, the call fails immediately (no ring), same "unreachable" outcome as calling an offline character.
3. **Line failover** (Part 2): flight mode is one of the three "skip this person" conditions for both primary and passive.
4. **The flight-mode character's own MDT access**: while flight mode is on, `oblsk_mdt`'s `Mdt.vue` shell renders a "No signal" placeholder instead of the normal interface — this is a client-side check against the character's own hydrated `phone:flight_mode` preference (no server round-trip needed, the client already has this value from its own hydration), not a new push-blocking mechanism (confirmed via research: no MDT→phone push exists to gate in the first place; MDT is request/response, and the character's own flight mode means their own device has no signal to make those requests meaningfully — this is the correct read of "no updates on the MDT," not a literal push block).

Bleeter/social does not exist in this codebase (confirmed via research) — no gating work there, nothing to build.

### DND — client-side only, no server gating

DND suppresses the on-screen notification/alert on the receiving device only. Messages still push live, calls still ring normally — DND does not affect delivery, only whether the recipient's client surfaces an interruption for it. This is existing client-side behavior in `Phone.vue` (the delivery-simulation function already referenced above); the only change DND needs is reading its state from the same shared `oblsk_preferences` key instead of the disconnected local ref.

## Data flow / event naming

New events follow this plugin's existing `oblsk_mdt:server:<module>-<action>` / `oblsk_mdt:client:<module>-<action>` convention:
- `lines-list`, `lines-create`, `lines-delete` (admin), `lines-register`, `lines-unregister`.
- `staff-set-vehicle` (Command centre's new assignment action, alongside the existing `staff-set-duty`/`staff-set-cam`).

No new `oblsk_mdt:server:*` event is needed for line resolution during a call — that's a same-process Lua global function call from `oblsk_phone` into `oblsk_mdt`'s `MdtLineService`, not a client-server round trip.

## Error handling

- `lines-register`/`unregister`: refuse (return false → `{ok:false,error:'forbidden'}`) if the line doesn't belong to the acting character's org, same object-level pattern as every other per-row check added in this plugin's port so far (`caseInGroup`, `vehicleInGroup`, `canRead`/`canWrite`).
- `lines-create`/`delete`: gated `mdt-admin`.
- `staff-set-vehicle`: gated `mdt-write-staff`, refuses if the target character isn't currently on duty in that org (mirrors `setDuty`'s existing org-membership check).
- A failed/unreachable line call surfaces to the caller exactly like any other unreachable-number call does today — no special-cased error message needed.

## Testing

- `tests/mdt_line_service_spec.lua` (new): CRUD, register/unregister upsert-by-role behavior, cross-org registration refusal, `resolveByNumber` shape.
- `tests/mdt_staff_service_spec.lua` (extend): `setAssignedVehicle` happy path + off-duty refusal.
- `oblsk_phone/tests/dialer_service_spec.lua` (extend): line resolution fallback, ring-timeout → failover-to-passive, busy/flight-mode skip-straight-to-passive, both-unreachable → call fails. `MdtLineService.resolveByNumber` stubbed the same way other cross-plugin globals are already stubbed in this codebase's specs.
- `oblsk_phone/tests/messages_service_spec.lua` or the `main.lua`-handler-level spec (whichever already covers the send path): flight-mode recipient does not receive the live push event, but the message row still exists.
- No integration/browser tests, matching every other module in this port.

## Out of scope (explicitly)

- Queueing/retry on a failed line call, or any voicemail concept — confirmed: a failed call just fails.
- IVR/department-picker for numbers shared across orgs — moot, numbers are unique per line by design.
- Bleeter/social gating — the app doesn't exist in this codebase.
- Any change to `oblsk_phone`'s `DispatchService`/`phone_dispatch_calls` (the dispatcher CAD board) — untouched, unrelated system.
- Full call lifecycle (create/close a dispatch call) from MDT — attach/detach only was in scope for an earlier iteration of this design and has since been superseded entirely by the line-registration model above (there is no "attach a unit to a dispatch call" feature in this design; Lines is about registering on emergency numbers, not the CAD board).
