# oblsk_reflexcheck

A standalone, reusable skill-check plugin: a sweeping-needle reflex dial.
Other plugins call `ReflexCheck.Start` (a plain global function — the shared
Lua VM means no FX exports are needed) to gate an action behind a
server-authoritative timing challenge. The server always judges hits; the
client only renders and pings "I pressed now".

See [design spec](https://github.com/Obelisk-Framework/core/blob/main/docs/superpowers/specs/2026-08-16-oblsk-reflexcheck-design.md).

## Usage

```lua
ReflexCheck.Start(player, {
    difficulty = 'medium',   -- key into ReflexCheckConfig.Presets
    count = {2, 3},           -- required-hit count: a number, or a {min,max}
                               -- range resolved to a random int once at start
    maxMisses = 3,             -- optional, overrides the preset
    zoneWidth = nil,            -- optional, overrides the preset (degrees)
    needleSpeed = nil,          -- optional, overrides the preset (degrees/sec)
}, function(passed)
    -- passed: boolean, called exactly once
end)
```

One session per player at a time. A second `Start` call for a player who
already has a running session returns `false, 'busy'` synchronously —
`onDone` is not invoked for the rejected call. Callers must not double-start.

## Configuring difficulty presets

`shared/config.lua`'s `ReflexCheckConfig.Presets` — see the file for the
three built-in presets (`easy`/`medium`/`hard`). Add more or edit the
existing ones; any `opts` field on a `Start` call overrides that preset
field for that call only.
