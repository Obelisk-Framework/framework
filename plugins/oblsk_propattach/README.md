# oblsk_propattach

Generic core mechanism to attach a prop to a vehicle/ped/player/object at a
named, DB-defined attach point, synced to every client via
`AttachEntityToEntity` and persisted across restarts.

See `docs/superpowers/specs/2026-08-15-prop-attachment-design.md` for the
full design.

## Usage (from another plugin)

```lua
local row, err = AttachmentService.attach('vehicle', VehToNet(vehicle), 'pounder', 'prop_deer_carc_01', 'trunk_slot', 0, {
    ownerType = 'plugin:oblsk_hunting',
    data = { animal = 'deer', weight = 82 },
})
if row then
    row.parent_model = 'pounder' -- required for the broadcast to resolve bone/offset, see Task 4's note
    PropAttachBroadcast(row)
end

-- later
PropAttachDetach(row.id)
```

## Placement tool

Requires the `propattach_edit` permission — grant it via the org-grant
pattern (same as `PropAttachPermissionSeeder.lua`'s doc comment shows), e.g.
`/org-grant character <characterId> propattach_edit`.

Three console commands drive the tool (no NUI form in v1):

- `/attach-point-edit <model>` — aim your camera at a live entity of that
  model, then run this to start a session. It raycasts to find the nearest
  bone and attaches a neutral preview prop there.
- Once a session is active: arrow keys nudge X/Y offset, PageUp/PageDown
  nudge Z offset, hold Shift + arrows to nudge rotation instead, Enter
  stages the placement for saving, Esc (or the bound `attach-point-cancel`
  key) cancels the session outright.
- `/attach-point-save <point_name> [slot_index]` — after Enter has staged a
  placement, run this to persist it as an attach point (`slot_index`
  defaults to `0`).
- `/attach-point-cancel` — cancel an active session, or clear a staged (but
  not yet saved) placement.

## Known limitations (v1)

- A restart loses the ability to re-resolve bone/offset for attachments
  whose parent model wasn't separately tracked by the calling plugin — the
  `attachments` table has no `parent_model` column. Callers needing
  restart-durable attachments should re-attach on their own resource start
  rather than relying on this plugin's late-joiner snapshot alone.
- The placement tool has no support for `object`-type parents (no bone
  sweep list) — attach points for objects must be inserted manually via SQL
  for now.
