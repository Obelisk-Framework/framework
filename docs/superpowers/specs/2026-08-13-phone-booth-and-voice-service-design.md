# Phone Booth Plugin & VoiceService Design

## Context

The FiveM prototypes project (`pages/phone-booth.html` / `src/proto/phonebooth.jsx`) has a fully designed street payphone: feed a dollar bill for a minute of line time, dial on a keypad, lift the handset to place a call, low-credit warning flash, dollar-bill fly-in animation, LCD power-on flicker and scanline. This needs to become a real Obelisk plugin.

Every "call" in the framework today is cosmetic. `oblsk_phone`'s `CallOverlay.vue` is explicitly commented `<!-- cosmetic toggles, no real audio integration -->`, and `RadioService.lua` documents that "no real proximity voice/radio system exists in this framework yet." There is currently zero voice plumbing anywhere in Obelisk. Building the phone booth honestly requires building that plumbing first, since a booth call with no audio isn't a booth call.

This spec covers four pieces, built in this order because each later piece depends on the one before it:

- **A. VoiceService** — a new core-adjacent module providing a provider-agnostic voice API, with real adapters for pma-voice, YaCA, and SaltyChat, and a safe no-op `native` fallback.
- **B. `oblsk_phonebooth`** — the new plugin. The actual ask. World-placed booths, full prototype UI/animation fidelity, real credit and real calls.
- **C. `oblsk_phone` Dialer/CallOverlay retrofit** — swap the cosmetic call path for real `VoiceService` calls.
- **D. `oblsk_phone` Radio app retrofit** — swap the simulated dual-channel tuner for real `VoiceService` radio channels.

## A. VoiceService

### Why a new module, not a plugin

Both `oblsk_phonebooth` and `oblsk_phone` need it, and future systems (dispatch, org radio nets) will too. It follows the same shape as `oblsk_preferences`: a small module other plugins depend on, versioned and installed independently, no UI of its own.

### Provider adapter contract

Every adapter (`native`, `pma`, `yaca`, `saltychat`) implements the same five functions, server-side:

```lua
VoiceAdapter.setProximity(source, range)            -- normal walk-around voice distance, in metres
VoiceAdapter.joinRadioChannel(source, channelId)     -- channelId: the frequency string, e.g. "AM 154.75"
VoiceAdapter.leaveRadioChannel(source, channelId)
VoiceAdapter.startCall(callId, sourceA, sourceB)     -- isolates two players' audio into a private channel
VoiceAdapter.endCall(callId)
```

`VoiceService` (the module's public API, what other plugins call) resolves to whichever adapter `Config.provider` names, exactly like the storage service's `storage_driver`. Nothing outside `VoiceService` ever calls an adapter directly, and nothing outside `VoiceService` ever calls a provider's native exports directly — this is the one seam that changes if a server switches from pma-voice to YaCA.

`VoiceService.startCall`/`endCall` take a framework-generated `callId` (already the shape `DialerService.activeCalls` produces) so a call and its voice channel share identity — no separate bookkeeping to keep in sync.

### `native` adapter

The default when `Config.provider` is unset or names a provider that isn't actually running. Implements `setProximity` for real (it's a bare game native, `NETWORK_SET_TALKER_PROXIMITY`, no external resource needed). `joinRadioChannel`/`leaveRadioChannel`/`startCall`/`endCall` are no-ops — radio and calls silently degrade to "no audio, text/UI state still works." This is the difference between "voice provider not installed" being a shrug versus a hard crash; a server can run Obelisk with zero voice resources and every plugin above still functions.

### `pma` adapter

pma-voice is Mumble-based and owns proximity itself once running (the framework must not call `NETWORK_SET_TALKER_PROXIMITY` directly when this adapter is active — pma-voice's own proximity module already does, and two owners fighting over the same native is how radio/proximity bugs happen in every pma-voice integration guide). `setProximity` becomes a call into pma-voice's own radio/proximity exports instead of the bare native. Calls are implemented the way every existing pma-voice phone script does it: allocate an ephemeral radio-channel id per call, put both parties on it via pma-voice's `setPlayerRadio` server export, and release it on hangup — pma-voice has no first-class "call" concept, so a call *is* a two-person radio channel under the hood.

### `yaca` adapter

YaCA (`yaca-systems/fivem-yaca-typescript`) has first-class phone-call support (its own call-start/call-end events) as well as `setActiveRadioChannel` for radio. This adapter maps `startCall`/`endCall` to YaCA's native call exports directly rather than borrowing the radio mechanism.

### `saltychat` adapter

SaltyChat exposes `SetPlayerVoiceRange`, `SetPlayerRadioChannel`, and phone-specific exports (`SetPhoneSpeaker` and friends) server-side. `startCall` establishes the call through SaltyChat's own phone-call export pair; `joinRadioChannel`/`leaveRadioChannel` map onto `SetPlayerRadioChannel`.

Exact export names for the yaca/saltychat/pma adapters get pinned against each project's current docs at implementation time (verify-against-source, not memorized) — the contract above is what's load-bearing for this spec, not the literal export string.

### Config

```lua
-- oblsk_voice/config.lua
Config.provider = 'native'  -- 'native' | 'pma' | 'yaca' | 'saltychat'
```

## B. `oblsk_phonebooth` plugin

### World placement

Booths are **interactions**, registered through the existing core `InteractionService` — the same pattern `oblsk_garage` and `oblsk_shop` already use — not a custom coords/proximity system. `Config.booths = {{x, y, z, heading, label}, ...}`; `server/main.lua` registers one `InteractionService.register(...)` call per booth at boot, action `phonebooth:open`.

### Server state

Per-booth-session state (not persisted — a booth has no "owner", any character can walk up):

```lua
BoothService.sessions[source] = {
  characterId, creditSeconds, callId,   -- nil until a call connects
}
```

- **Feed dollar**: server consumes one unit of the `currency.cash` item binding (resolved via `oblsk_items`, not a hardcoded item name — matches the framework's existing item-bindings convention) and grants `BOOTH_SECONDS_PER_BILL` (60s) credit. Server-authoritative: the client cannot fabricate credit, it only requests a feed and the server confirms or rejects (insufficient cash).
- **Credit tick**: server-side 1s interval per active session decrements `creditSeconds`; at 0, force-ends any active call and notifies the client to show the "line dropped" state.
- **Dial**: reuses `PhoneNumberService.resolveCharacterId` and `DialerService`-style resolution (a booth call is a call *from* a booth, not from a phone number, so it's a thin variant of `DialerService.call` rather than a direct reuse — the booth has no number of its own to log recents against).
- **Connect**: on answer, `VoiceService.startCall(callId, boothSource, calleeSource)`.
- **Hang up / credit exhausted / handset dropped**: `VoiceService.endCall(callId)`.

### Client / UI

New Vue component (not a phone app — booths are their own standalone NUI overlay, opened by `phonebooth:open`, closed like any other page). Ports `src/proto/phonebooth.jsx` to Vue with full fidelity:

- Dollar-bill SVG + fly-in-and-vanish animation on feed
- LCD power-on flicker + scanline sweep on mount
- Handset lift/drop rotation transform, cord curve recompute
- Low-credit flash (LCD tints red, flashes) in the final 15s
- Keypad entry, clear, dial/hang-up button swap by call state
- All CSS keyframes (`boothLcdOn`, `boothScan`, `boothFeed`) ported as Vue scoped styles / CSS custom properties, matching how `Phone.vue` already handles the design system's `--ob-accent`/`--ob-radius` tokens

State machine mirrors the prototype 1:1: `idle → ringing → call → ended`, driven by server events for credit/call-state and local-only for handset lift (cosmetic, no server round-trip needed for that one).

## C. `oblsk_phone` Dialer/CallOverlay retrofit

`DialerService.answer(callId, source)` already exists as the single point where a call becomes live — add `VoiceService.startCall(callId, call.callerSource, call.calleeSource)` there. `DialerService.hangup(callId, source)` already exists as the single point where a call ends — add `VoiceService.endCall(callId)` there. No new call-lifecycle code; this is purely wiring two existing chokepoints to the new service. `CallOverlay.vue` loses its "cosmetic" comment; its mute/speaker toggles start calling through to `VoiceService` client-side helpers instead of being inert.

## D. `oblsk_phone` Radio app retrofit

`RadioService` presets already persist `frequency` strings — that's the channel id `VoiceService.joinRadioChannel` expects. `Radio.vue`'s tune-in action calls `joinRadioChannel(frequency)`; tune-out or power-off calls `leaveRadioChannel(frequency)`. The simulated traffic log stays simulated (out of scope — real traffic requires other players actually transmitting, which this spec doesn't add UI for).

## Testing

- `VoiceAdapter` contract gets a fake/`native`-backed spec, same shape as the repo's existing `fake_query_builder.lua` pattern, so `DialerService`/`BoothService`/`RadioService` tests exercise real call/join logic without a live voice resource.
- `BoothService` credit/feed/dial/hangup logic tested the same way `GarageService` is (service-level specs, no NUI).
- Adapter implementations themselves (pma/yaca/saltychat) are integration-only — not unit-testable without the real resource running — so they get a manual verification checklist in the implementation plan, not automated specs.

## Error handling

- Feed with insufficient `currency.cash`: reject, notify, no credit granted.
- Dial with zero credit / handset on hook / number too short: rejected client-side (matches prototype's existing guard messages) and re-validated server-side before any call attempt.
- Credit hits zero mid-call: server force-ends call and voice channel, client shows "line dropped."
- `VoiceService` call with an adapter whose provider isn't actually running (misconfigured `Config.provider`): adapter calls fail closed — booth call state still transitions normally (so gameplay isn't blocked), but no audio; this is a deployment misconfiguration, not something the booth/phone code needs to detect.
