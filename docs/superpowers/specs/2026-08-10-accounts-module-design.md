# Accounts Module Design

**Repository:** `modules/oblsk_accounts` (own git repo, folded into `core` via the `modules/*/...` globs in `core/fxmanifest.lua`, same pattern as `oblsk_items` and `oblsk_vehicles`).

**Goal:** Resolve every connecting player to a stable `Account`, reachable through any identifier it has ever used, and gate connections against active bans, before the player ever spawns. Downstream modules (starting with a future Characters module) build on top of `Account`, they don't duplicate identity resolution.

## Why this exists

The framework has no account/identity concept yet. `Item.owner_type`/`Vehicle.owner_type` already anticipate a `'character'` owner type, and Characters will need a stable `owner_id` to point at, an FiveM's own connect-time identifiers (`license`, `license2`, `discord`, `steam`, `fivem`, `live`, `xbl`, plus the player's IP) are the only identity signal available without building a real OAuth login flow. `license` is the one identifier FXServer always provides; everything else is present or absent depending on platform and the player's linked accounts.

Two things this module deliberately does NOT do:

- **No OAuth login screen.** "Multiple ways to login" means an account is reachable via any identifier it has ever used, not a real Discord/Steam OAuth handshake. That's a distinct, much larger project (NUI browser flow, provider app registrations, a callback server) that isn't in scope here.
- **No true HWID/MAC fingerprinting.** FXServer's client Lua VM has no hardware access; reading real HWID/MAC values needs an external client-side tool, which is its own can of worms (spoofable, anti-cheat territory). This module stores what FXServer actually gives it: identifiers and IP.

## Schema

### `accounts`

| Column | Type | Notes |
|---|---|---|
| `id` | integer PK | |
| (timestamps) | | |

Deliberately bare. Nothing identifying lives directly on this row; that's what `account_identifiers` is for. Keeping `accounts` schema-stable means adding a new identifier type later never touches this table.

### `account_identifiers`

| Column | Type | Notes |
|---|---|---|
| `account_id` | integer FK | `references('id').on('accounts').onDelete('CASCADE')` |
| `type` | string(50) | `'license'`, `'license2'`, `'discord'`, `'steam'`, `'fivem'`, `'live'`, `'xbl'`, `'ip'`, more as FXServer adds them |
| `value` | string(255) | the raw identifier value, without the `type:` prefix FXServer includes |
| (timestamps) | | `updated_at` doubles as "last seen with this identifier" |

`unique({'type', 'value'})`: one identifier value can only ever belong to one account. This is the join key both directions, resolve an account from an identifier, and detect when an identifier already belongs to someone else.

### `bans`

| Column | Type | Notes |
|---|---|---|
| `account_id` | integer, nullable FK | `references('id').on('accounts').onDelete('CASCADE')`, set when banning an account |
| `identifier_type` | string(50), nullable | set when banning a raw identifier instead |
| `identifier_value` | string(255), nullable | paired with `identifier_type` |
| `reason` | text | |
| `issued_by` | string(255) | free text (admin name/identifier); no permissions/roles system exists yet to reference a real admin account |
| `expires_at` | datetime, nullable | `null` = permanent |
| `revoked_at` | datetime, nullable | set on unban |
| (timestamps) | | |

**Invariant (app-level, not DB-enforced, same convention as the Item/Vehicle modules' polymorphic ownership columns):** exactly one of `account_id` or the `identifier_type`/`identifier_value` pair is set per row, never both, never neither.

Banning by raw identifier (not just by account) exists because ban evasion typically means showing up with a fresh license/account on the same IP or Discord ID. A ban targeting `identifier_type = 'ip', identifier_value = '1.2.3.4'` still catches that, since `AccountService.checkBan` matches on the incoming connection's raw identifiers, not just the resolved account id.

## `AccountService` (server-only)

### Identifier resolution

- **`AccountService.parseIdentifiers(rawIdentifiers)`**: `GetPlayerIdentifiers(source)` returns strings like `"license:abc123..."`. Splits each on the first `:` into `{ type, value }`.
- **`AccountService.findOrCreateAccount(identifiers)`**:
  1. Find the `license` entry. If absent, return an error, license is required.
  2. Look it up in `account_identifiers` (`type = 'license'`). If a row exists, that `account_id` is authoritative.
  3. If not, create a new `accounts` row, then insert its `license` into `account_identifiers`.
  4. For every other identifier on this connection (`discord`, `steam`, `ip`, ...):
     - Not in `account_identifiers` yet → insert it, linked to this account.
     - Already linked to this account → touch `updated_at` (last-seen).
     - Already linked to a **different** account → log a conflict (`print` warning with both account ids and the identifier), do not merge, do not fail the connection. Auto-merging accounts on a colliding secondary identifier is an account-theft vector (e.g. a stale/leaked Discord ID sitting on an unrelated account); `license` is the one signal trusted enough to decide identity.
  5. Return the resolved `account_id`.

### Ban checking

- **`AccountService.checkBan(accountId, identifiers)`**: returns the first active ban (`revoked_at IS NULL`, and `expires_at IS NULL OR expires_at > now`) matching `account_id = accountId`, OR matching any `(identifier_type, identifier_value)` pair present in `identifiers`. Returns `nil` if none.
- **`AccountService.ban(target, reason, issuedBy, expiresAt)`**: `target` is either `{ accountId = ... }` or `{ type = ..., value = ... }`. Inserts a `bans` row.
- **`AccountService.unban(banId)`**: sets `revoked_at = now`.
- **`AccountService.formatBanMessage(ban)`**: builds the player-facing deferral message from a ban row, e.g. `"Banned: <reason> (permanent)"` or `"Banned: <reason> (expires <date>)"`.

### Session map

- `AccountService.sessionAccounts[source] = accountId`, populated once resolution + ban check pass in `playerConnecting`, cleared in `playerDropped`.
- **`AccountService.getAccountId(source)`**: the lookup every other module (Characters, later) uses to get the current player's account id. Returns `nil` if the player hasn't been resolved (shouldn't happen if `playerConnecting` ran, but callers should treat `nil` as "not ready" rather than assuming it's always set).

## Connect hook

Hooked into FXServer's `playerConnecting` with `deferrals`, so a banned or unresolvable player is rejected before they ever spawn:

```lua
AddEventHandler('playerConnecting', function(name, setKickReason, deferrals)
    local src = source
    deferrals.defer()
    Citizen.Wait(0)
    deferrals.update('Checking account...')

    local identifiers = AccountService.parseIdentifiers(GetPlayerIdentifiers(src))

    local accountId, err = AccountService.findOrCreateAccount(identifiers)
    if not accountId then
        deferrals.done(err or 'Could not verify your account.')
        return
    end

    local ban = AccountService.checkBan(accountId, identifiers)
    if ban then
        deferrals.done(AccountService.formatBanMessage(ban))
        return
    end

    AccountService.sessionAccounts[src] = accountId
    deferrals.done()
end)

AddEventHandler('playerDropped', function()
    AccountService.sessionAccounts[source] = nil
end)
```

**Fails closed:** no `license` identifier, or a DB error anywhere in resolution, rejects the connection via `deferrals.done(...)`. This module gates everything downstream (Characters included), so an unresolved player must never be let through with no account.

## Admin commands

No permissions/roles system exists yet, so these are gated directly by FXServer's ACE permission (`IsPlayerAceAllowed(source, 'oblsk_accounts.ban')`), the same primitive server owners already use for other admin commands.

- **`/ban <serverId> <reason...>`**: permanent ban on the target's currently-resolved account (via `AccountService.getAccountId(serverId)`).
- **`/tempban <serverId> <minutes> <reason...>`**: same, with `expires_at = now + minutes`.
- **`/banid <type> <value> <reason...>`**: bans a raw identifier directly (offline player, or a bare IP/license with no account attached yet).
- **`/unban <banId>`**: revokes a ban by its row id.

Without these, `bans` has no practical way to be written to short of raw SQL; they're the minimum viable admin surface, not a full moderation UI.

## Error handling

- Missing `license` identifier: reject the connection.
- DB error during `findOrCreateAccount` or `checkBan`: reject the connection with a generic message, never let a player through with an unresolved account.
- Identifier conflict (secondary identifier already linked elsewhere): log only, never blocks the connection, never merges accounts.

## Testing

Unit tests mirror the Items/Vehicles modules' pattern (stubbed `Database`/`QueryBuilder`, no live FXServer runtime needed):

- `parseIdentifiers`: parses FXServer's `"type:value"` strings correctly, including values that themselves contain a `:` (e.g. `ip` values are safe, but be defensive: split on the *first* `:` only).
- `findOrCreateAccount`: matches existing account by license; creates a new account when license is unseen; links a new secondary identifier to an existing account; touches `updated_at` when a secondary identifier is already linked to the same account; detects (without merging) a secondary identifier linked to a different account.
- `checkBan`: matches an active ban by `account_id`; matches an active ban by raw identifier; ignores a `revoked_at`-set ban; ignores an expired ban; returns `nil` when nothing matches.
- `ban`/`unban`: round-trip, including the `account_id`-vs-raw-identifier target shapes.

## Known gaps (deferred)

- No real OAuth login flow (see [Why this exists](#why-this-exists)). "Multiple ways to login" is passive identity capture from whatever identifiers FXServer already provides, not an active login screen.
- No true HWID/MAC fingerprinting; not natively available without external client-side tooling.
- No admin UI/panel for viewing accounts, identifiers, or ban history; console commands only.
- No permissions/roles system; admin commands are gated by raw ACE permissions, not a real role model.
- Characters module (a separate, future spec) is the first real consumer of `AccountService.getAccountId(source)`; nothing in this module assumes what a "Character" looks like.
