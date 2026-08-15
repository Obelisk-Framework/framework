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

`/attach-point-edit <model>` while aiming at a live entity of that model —
see the design doc's "Placement tool" section for controls.

## Known limitations (v1)

- A restart loses the ability to re-resolve bone/offset for attachments
  whose parent model wasn't separately tracked by the calling plugin — the
  `attachments` table has no `parent_model` column. Callers needing
  restart-durable attachments should re-attach on their own resource start
  rather than relying on this plugin's late-joiner snapshot alone.
- The placement tool has no support for `object`-type parents (no bone
  sweep list) — attach points for objects must be inserted manually via SQL
  for now.
