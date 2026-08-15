# Notebook item plugin

Status: approved
Date: 2026-08-15

## Summary

Port the `notebook.jsx` / `note-page.jsx` design prototypes into a new
`oblsk_notebook` plugin: an in-inventory notebook item you write in,
flip through, and can tear pages out of. A torn page becomes its own
item that can be read on its own.

## Data model

Two `base_items` rows, seeded idempotently by `NotebookItemSeeder.lua`
(same check-then-insert style as `LicensesItemSeeder.lua`), each bound
via `item_bindings` — nothing in this plugin ever hardcodes a
`base_item_id`:

| key | item | flags | `data` |
|---|---|---|---|
| `notebook.notebook` | Notebook | `is_useable=1`, `is_stackable=0` | `{ max_pages = 12 }` |
| `notebook.torn_page` | Torn note page | `is_useable=1`, `is_stackable=0` | `{}` |

`Config.Requires.bindings` in `shared/config.lua` declares both keys
(mirrors `oblsk_licenses`/`oblsk_banking`), registered with
`ItemService.registerRequirements('oblsk_notebook', ...)` at boot.

**Per-instance state lives on the `items` row, not the base item.**
A notebook item's `data` is:

```lua
{ pages = { { id = 'p1', title = 'Untitled page', body = '' }, ... } }
```

A newly granted notebook starts with a single blank page. `pages`
length is clamped server-side to the notebook's own base item
`data.max_pages` on every save — the client can request an add-page,
but the server is the one that refuses past the cap.

A torn note page's `data` is `{ title, body, from, meta }` — `from`
and `meta` are display-only provenance text ("Torn from Notebook",
a timestamp), filled in at tear time.

## Flows

### Opening the book (write/read/flip)

Inventory's existing `Use` context-menu action (`is_useable`) already
routes through `InventoryService.use` → `ItemService.use`, which runs
the base item's `actions` pipeline through `ActionService`. The
notebook base item's pipeline has one entry: a new action
`notebook:open`, registered by `server/actions/NotebookActions.lua`
(same pattern as core's `ItemActions.lua`). That action:

1. Checks the item is a `notebook.notebook`-bound item the caller
   owns (re-checked server-side, never trusts the client).
2. Sends the current `pages` + `max_pages` to the client.
3. `WebView.openPage(source, '/Notebook')` + `WebView.focus(source)`
   — a full routed page (`web/routes.js`, same shape as
   `oblsk_inventory`/`oblsk_keybinds`), not a HUD overlay, since it's
   a dedicated full-screen surface like Inventory.

`Notebook.vue` is the ported `notebook.jsx`: corner-drag page turn
(mouse-driven flip animation, `pointerdown`/`pointermove`/`pointerup`
exactly as prototyped, plus ← → keys), the tear-out rip animation,
ink-colour swatches, autosave.

Client → server events:

- `notebook:client:save(itemId, pages)` — full-page replace,
  ownership-checked, clamps to `max_pages`, persists to
  `items.data.pages`.
- `notebook:client:tearOut(itemId, pageIndex)` — see below.
- `notebook:client:close(itemId)` — no persistence side effect beyond
  the trailing save; just lets the server drop any per-session state
  if it ever needs to (none currently).

### Tearing a page out

`NotebookService.tearOut(source, itemId, pageIndex)`:

1. Ownership + bounds check.
2. Reads `pages[pageIndex]` (`{title, body}`).
3. Inserts a new `items` row: `base_item_id` = the
   `notebook.torn_page` binding's item, `owner_type='character'`,
   `owner_id=characterId`, `container`/`slot` left `NULL` — the
   existing lazy-placement repair in `InventoryService.buildCharacterSync`
   (`placeUnslotted`) picks it up on the player's next inventory sync,
   same convention `ItemService.add` already relies on. `data =
   { title, body, from = '<notebook name>', meta = <server timestamp> }`.
4. Replaces `pages[pageIndex]` in the notebook item with a fresh
   blank page (`{ id = new, title = 'Untitled page', body = '' }`) —
   page count is unchanged, matching the prototype's "rip and keep
   writing underneath" behaviour. Tearing is always allowed regardless
   of `max_pages` (it never grows the book).
5. Persists the notebook item, returns the new `pages` array to the
   client.

No forced inventory re-sync is pushed (matches `LicenseService`'s own
item-granting code — the new item shows up next time the inventory
app is opened/mutated through its own events; nothing else in the
codebase force-pushes a sync for items created elsewhere either).

### Viewing a single torn page

The torn-page base item is also `is_useable=1`, with its own action
`notebook:viewPage` (also in `NotebookActions.lua`). Unlike the
notebook itself, this doesn't open a routed page — it's a quick,
read-only look, so it uses a global overlay component
(`web/globalElements.js`, same mechanism as `licenses`'
`PresentOverlay`/`LicenseCard`):

1. Ownership check.
2. `WebView.emitClient(source, 'notebook:viewPage', payload)` +
   `WebView.showGlobalElement(source, 'notePageView')`.
3. `NotePageView.vue` (ported `note-page.jsx`) renders front (title +
   body) and back (`from`/`meta` line) faces, drag-to-flip with the
   mouse exactly as prototyped.
4. A "Close" control fires `notebook:client:closeView(itemId)` →
   server hides the global element.

Deliberately **not** broadcast to nearby players the way a license
present is — reading a personal note isn't something this plugin
shows off to bystanders, so there's no `PresentService`-equivalent
nearby-player scan here.

## Files

```
core/plugins/oblsk_notebook/
  fxmanifest.lua
  shared/config.lua
  server/
    main.lua                      -- event wiring, boot-time seeding
    actions/NotebookActions.lua   -- notebook:open, notebook:viewPage
    services/NotebookService.lua  -- save/tearOut/viewPage payload logic
    seeders/NotebookItemSeeder.lua
  client/main.lua                 -- WebView.on relays (open/save/tearOut/view/close)
  web/
    Notebook.vue                  -- ported notebook.jsx
    NotePageView.vue              -- ported note-page.jsx
    globalElements.js             -- registers notePageView overlay
    routes.js                     -- registers /Notebook route
  tests/
    notebook_service_spec.lua
```

## Testing

Lua specs mirroring `license_service_spec.lua`'s style:

- Save clamps `pages` to the notebook's `max_pages`.
- Save/tearOut/viewPage all reject a non-owner source.
- `tearOut` creates a `notebook.torn_page` item with the torn page's
  title/body, and resets the source page to blank without changing
  `pages` length.
- `viewPage` payload shape (title/body/from/meta) for a torn-page item.

No Vue component tests — matches the rest of the codebase (`oblsk_licenses`
has none either); verified manually via the dev sandbox pattern
(`import.meta.env.DEV` mock payload) already used in `PresentOverlay.vue`.
