# Organizations Module and Core Permissions Design

**Repositories:** `core` (new `PermissionService` + `HasPermissions` trait, one migration), `modules/oblsk_organizations` (new module).

**Goal:** Model in-game organizations (jobs like police/EMS, gangs) with departments and ranks, so other modules/plugins (banking, phone Dispatch/MDT) can gate resources on org membership, department, or rank. Alongside that, add a generic, reusable permission-grant mechanism to core itself, since "can this entity do X" turns out to be needed by more than just organizations (accounts, characters).

## Why permissions belong in core, not in `oblsk_organizations`

The natural first cut was an `organization_permissions` table scoped to ranks/departments only. But the same shape (grant a named permission to some entity, check it later) is obviously useful for `Account` and `Character` too, and none of those three modules should depend on each other to share it. Core already has exactly this kind of problem solved once: `PolicyService` is a registry (`PolicyService.registry`) plus a polymorphic pivot table (`policy_attachments` / `action_policy` / `interaction_policy`) that any module attaches to without core knowing about actions or interactions in advance. This design reuses that idiom for permissions.

The remaining wrinkle: `Character:can('manage_bank')` needs to be true not just from grants made directly to that character, but also from whatever rank/department the character holds *in `oblsk_organizations`* — a module core cannot depend on. The fix is the same direction every other cross-module extension point in this framework already uses (`PhoneAppRegistry.register`, core's own `globalElements.js` glob): the module with the extra context registers itself into the generic mechanism, not the other way around. `oblsk_organizations` calls `PermissionService.addDelegate('character', resolverFn)` at its own boot; `oblsk_characters` never learns organizations exists.

## Part 1: Core `PermissionService` and `HasPermissions`

### Schema

One migration, `core/server/database/migrations/`, alongside the existing `policy_attachments` migration:

`permissions`:

| Column | Type | Notes |
|---|---|---|
| `owner_type` | string(50) | e.g. `'character'`, `'account'`, `'rank'`, `'department'` — validated against `PermissionService`'s registered-type set at grant time, not a fixed enum |
| `owner_id` | integer | no FK, target table depends on `owner_type` |
| `permission_key` | string(150) | e.g. `'manage_bank'` |
| (timestamps) | | |

`unique({'owner_type', 'owner_id', 'permission_key'})`: a row's existence is the grant; there is no `value` column, nothing to store beyond "granted or not."

### `PermissionService` (`core/server/Services/PermissionService.lua`)

- **`PermissionService.registerType(typeName, Model)`** — an entity type's owning module calls this once at boot (`oblsk_characters` for `'character'`, `oblsk_accounts` for `'account'`, `oblsk_organizations` for `'rank'` and `'department'`). Builds the allowlist `grant`/`revoke`/`has` validate against, mirroring `PolicyService`'s `ALLOWED_RESOURCE_TYPES`, except built dynamically since core cannot hardcode module-owned type names. `Model` is stored for later reference (not required for the permission checks themselves, but keeps the registry a real registry rather than a bare set of strings, useful for any future admin tooling that wants to resolve an owner back to its model).
- **`PermissionService.grant(ownerType, ownerId, key)`** / **`.revoke(ownerType, ownerId, key)`** — insert-if-missing / delete, erroring if `ownerType` was never registered.
- **`PermissionService.has(ownerType, ownerId, key)`** — direct grant lookup only, no delegation. The primitive the rest of this builds on.
- **`PermissionService.list(ownerType, ownerId)`** — every granted key for that owner.
- **`PermissionService.addDelegate(typeName, resolverFn)`** — registers `resolverFn(ownerId) -> { { type = ..., id = ... }, ... }`, called by a *different* module than the one that owns `typeName`. Multiple delegates can be added for the same type (e.g. two unrelated modules both want to extend what "can a character do X" means); all run.
- **`PermissionService.can(ownerType, ownerId, key)`** — `true` if `has(ownerType, ownerId, key)`, or if any delegate's resolved refs individually satisfy `has(ref.type, ref.id, key)`. One level deep only, not recursive (a delegate's own delegates are not walked) — YAGNI until a real use case needs deeper chains.

### `HasPermissions` trait (`core/server/Traits/HasPermissions.lua`)

Not a general trait system, one small mixin for this one behavior:

```lua
HasPermissions.apply(Character, 'character')
```

does, in order: sets `Model.permissionType = typeName`, calls `PermissionService.registerType(typeName, Model)`, and defines instance methods on `Model`:

- `instance:can(key)` → `PermissionService.can(self.permissionType, self.id, key)`
- `instance:grant(key)` → `PermissionService.grant(self.permissionType, self.id, key)`
- `instance:revoke(key)` → `PermissionService.revoke(self.permissionType, self.id, key)`
- `instance:permissionList()` → `PermissionService.list(self.permissionType, self.id)`

Applied to `Character` (in `oblsk_characters`) and `Account` (in `oblsk_accounts`) as part of this same plan, one line each in their model files, so the pattern is proven end-to-end rather than only theorized. Applied to `Rank` and `Department` in `oblsk_organizations` (Part 2).

## Part 2: `oblsk_organizations`

New module, `modules/oblsk_organizations`, depends on `oblsk_characters` (for `character_id`) the same way `oblsk_characters` depends on `oblsk_accounts` — a plain global service call, no migration-level FK across module boundaries beyond what's already established as acceptable in this framework.

### Schema

`organizations`: `id`, `name`, timestamps.

`departments`: `id`, `organization_id`, `name`, timestamps. Pure grouping label — no permissions of its own beyond what `HasPermissions` gives it once applied; belongs to exactly one organization.

`ranks`: `id`, `organization_id`, `name`, `grade` (integer, higher = more senior), timestamps. `grade` is the hierarchy level used for promotion/demotion ordering; permission checks go through `HasPermissions`, not grade comparisons.

`organization_memberships`: `id`, `character_id`, `organization_id`, `rank_id`, timestamps. One row per character per organization they belong to. A config flag, `Config.Organizations.allowMultiple` (default `false`), controls whether `OrganizationService.join` removes a character's existing memberships before creating the new one, or leaves them and lets the character hold several simultaneously.

`organization_department_members`: `id`, `membership_id`, `department_id`, timestamps. Many-to-many: a character can belong to 0-n departments within an organization they're already a member of (joining a department without an existing membership row is a no-op error, not an implicit join).

### `OrganizationService`

- `create(name)` / `rename(orgId, name)` / `delete(orgId)`
- `addDepartment(orgId, name)` / `removeDepartment(deptId)`
- `addRank(orgId, name, grade)` / `removeRank(rankId)`
- `join(characterId, orgId, rankId)` — respects `Config.Organizations.allowMultiple`
- `leave(characterId, orgId)` — also clears that membership's department rows
- `setRank(characterId, orgId, rankId)` — promote/demote
- `joinDepartment(characterId, orgId, deptId)` / `leaveDepartment(characterId, orgId, deptId)`
- `getMembership(characterId, orgId)` → `{ organization_id, rank, departments[] }` or `nil`
- `getMemberships(characterId)` → same shape, one entry per org the character belongs to (a list even when `allowMultiple` is `false`, since that config only constrains *writes*, not what a caller can read)

Deletion cascades, so a broken reference is never left behind: `delete(orgId)` removes that org's departments, ranks, memberships, and department-members rows. `removeDepartment(deptId)` removes its department-members rows. `removeRank(rankId)` sets `rank_id` to `nil` on any membership that held it (a character isn't kicked from the org just because its rank was deleted, they simply have no rank until `setRank` gives them a new one), rather than failing or cascading further.

### Wiring into `PermissionService`

At `oblsk_organizations` boot, after models are loaded:

```lua
HasPermissions.apply(Rank, 'rank')
HasPermissions.apply(Department, 'department')

PermissionService.addDelegate('character', function(characterId)
    local refs = {}
    for _, membership in ipairs(OrganizationService.getMemberships(characterId)) do
        if membership.rank then
            table.insert(refs, { type = 'rank', id = membership.rank.id })
        end
        for _, dept in ipairs(membership.departments) do
            table.insert(refs, { type = 'department', id = dept.id })
        end
    end
    return refs
end)
```

This is the entire cross-module link. `oblsk_characters` never references `oblsk_organizations`; `Character:can('manage_bank')` works because the delegate above was registered, and would simply always return `false` via that path if `oblsk_organizations` weren't installed at all.

### Commands

Admin-only, same style and `isAdmin` check as `oblsk_accounts`' `AccountCommands`:

- `/org-create <name>`
- `/org-delete <orgId>`
- `/org-adddept <orgId> <name>` / `/org-removedept <deptId>`
- `/org-addrank <orgId> <name> <grade>` / `/org-removerank <rankId>`
- `/org-setrank <serverId> <orgId> <rankId>`
- `/org-join <serverId> <orgId> <rankId>` / `/org-leave <serverId> <orgId>`
- `/org-adddeptmember <serverId> <orgId> <deptId>` / `/org-removedeptmember <serverId> <orgId> <deptId>`
- `/org-grant <ownerType> <ownerId> <key>` / `/org-revoke <ownerType> <ownerId> <key>` — thin wrapper over `PermissionService.grant`/`.revoke`, kept in `oblsk_organizations` rather than core since core ships no commands anywhere else in this framework; `ownerType` here will in practice always be `'rank'` or `'department'`, but the command doesn't enforce that, `PermissionService` itself already rejects an unregistered type.

All commands resolve `<serverId>` arguments to `character_id` via `CharacterService.getActiveCharacterId`, same pattern as `AccountCommands`.

## Testing

Fake-`QueryBuilder`-backed specs, same pattern as every other module this session: `permission_service_spec.lua` (core, new), `organization_service_spec.lua` (grant/delegate behavior covered indirectly through `PermissionService.can`, plus membership/department join-table behavior directly).
