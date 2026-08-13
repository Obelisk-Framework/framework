# Camera + Gallery — Design Spec

**Sub-project 1** of the phone-feature decomposition (Storage service → **Camera+Gallery** → Bleeter → Home infra → Mail/Docs/Cloud → Paperwork). Builds on the storage service (`core/server/Services/StorageService.lua`, merged to `main` at `5934a28`).

## Goal

Two built-in `oblsk_phone` apps — Camera (capture photos and short video clips) and Gallery (browse, organize into albums, delete, and send to a Messages conversation) — with a real backend (DB-backed, not decorative), matching the rigor of the existing Messages app.

## Non-goals

- Live streaming (the `screencapture` resource has a live-streaming feature; not used here).
- Photo/video editing (filters, cropping, trimming).
- Sharing to Bleeter (Bleeter doesn't exist yet — sub-project 2).
- Cloud/backup sync (sub-project 4).

## Dependency: `screencapture`

[itschip/screencapture](https://github.com/itschip/screencapture) (successor to `screenshot-basic`, AGPL-3.0, actively maintained) is added as a new resource dependency. Relevant server-side exports:

- `serverCapture(source, options, callback, dataType)` — captures a still, returns image data directly (not used here — we upload, not inline-return).
- `remoteUpload(source, url, options, callback, dataType)` — captures a still and POSTs it directly to `url` as multipart form data. `options.headers` and `options.formField` are configurable; the docs explicitly recommend this server-side path over the client-side `requestScreenshotUpload` export, which they flag as "not recommended" because it exposes the upload token to the client.
- `startVideoCaptureUpload(source, url, options, callback)` / `stopVideoCapture(captureId)` — starts a WebM (VP9) recording, uploads to `url` on finalize. **Experimental**: the README warns it can silently produce an empty file if WebCodecs isn't available in that FiveM build's bundled Chromium.
- `isVideoCaptureActive(captureId)`.

All of these are called from server-side Lua with a player `source` — no client Lua/NUI code needed for the capture itself. This matches this framework's existing `PerformHttpRequest`/service-driven patterns and specifically vindicates the storage service's server-minted, single-use, short-lived token design (`Storage.mintUploadToken`/`consumeUploadToken`), which `screencapture`'s own docs recommend for exactly the reason we already built it.

`fxmanifest.lua` gets `screencapture` added to `dependencies {}`; `server.cfg.example`/`server.cfg` get `ensure screencapture` added before `ensure core`.

## Storage service changes (small, additive)

Two changes to `core/server/Services/`:

1. **`Storage.uploadUrl(token)`** (new function in `StorageService.lua`) — builds the absolute URL `screencapture`'s server-side exports need to POST to. FXServer mounts a resource's HTTP handler under `/<resourceName>/...`, and since `plugins/*/server/**/*.lua` is globbed into the same single resource as `core` (confirmed via `fxmanifest.lua` — there is one `fx_version`/manifest for the whole repo), the URL is `http://127.0.0.1:<endpoint-port>/<GetCurrentResourceName()>/storage/upload?...`. The exact convar for the endpoint port needs confirming against this repo's `server.cfg` during implementation (FXServer convention is typically `endpointport` or derived from the `endpoint_add_tcp`/`endpoint_add_udp` lines) — implementation must verify this against a running stack, not assume.
2. **`upload_handler.lua` accepts the token via an `X-Storage-Token` header**, as a fallback when the multipart body has no `token` field. `screencapture`'s `remoteUpload`/`startVideoCaptureUpload` send exactly one file field (name configurable via `formField`) plus custom `headers` — they cannot add a second `token` form field. The existing multipart-body `token` field path (used by the original `screenshot-basic`-oriented design) stays as-is for any future direct/manual caller; this is purely additive.

Both changes are implemented as their own task in the implementation plan, ahead of the Camera/Gallery services that depend on them.

## Data model

Two new tables, in `oblsk_phone`'s own migrations (matching Messages' convention: `plugins/oblsk_phone/server/migrations/`):

```
phone_albums
  id
  owner_character_id  (index)
  name                 string
  is_default           boolean, default false   -- the auto-created "Camera Roll"
  timestamps

phone_media
  id
  owner_character_id  (index)
  album_id             (index, FK -> phone_albums.id)
  kind                 string  ('photo' | 'video')
  storage_key          string  -- the key passed to Storage.put/mintUploadToken
  url                  string  -- Storage.url(storage_key) at capture time
  duration_seconds     integer, nullable  -- video only
  taken_at             timestamp
  timestamps
```

No thumbnail column/generation step: photos render via `url` directly; video uses a native `<video>` element, which already shows the first frame as a poster without any server-side thumbnailing (nothing in this stack — pure Lua, no image library — could generate one anyway).

`phone_messages` gets two new nullable columns via a small migration: `media_url` (string), `media_kind` (string, `'photo'|'video'`) — the minimal addition needed for the Messages-attach feature below; `MessagesService.send` gets an optional `media` parameter.

## Backend services (in `oblsk_phone`)

`plugins/oblsk_phone/server/services/CameraService.lua`:
- `CameraService.capturePhoto(source, characterId, albumId)` — quota check → `Storage.mintUploadToken` → `exports.screencapture:remoteUpload(source, Storage.uploadUrl(token), {encoding='webp', headers={['X-Storage-Token']=token}}, callback)` → on success, insert `phone_media` row (`kind='photo'`), return it. On failure (non-2xx from the upload, or an errored `screencapture` callback), return an error the caller shows as a toast — no partial/broken row.
- `CameraService.startVideo(source, characterId, albumId)` — quota check → mint token → `exports.screencapture:startVideoCaptureUpload(source, Storage.uploadUrl(token), {duration=15, headers={['X-Storage-Token']=token}}, callback)`, returns the `captureId` immediately so the client can show a recording indicator and a manual stop control (server-enforced 15s hard cap regardless). On the callback firing (either from the duration cap or a manual stop): validate `result.status == 'success'` and `result.bytesReceived > 0` (guards the documented empty-file failure mode) before inserting the `phone_media` row (`kind='video'`); otherwise return a clean failure.
- `CameraService.stopVideo(captureId)` — thin wrapper over `exports.screencapture:stopVideoCapture`.
- Quota check (shared helper): `QueryBuilder.new('phone_media'):where('owner_character_id', characterId):countSync() >= GetConvarInt('phone_gallery_max_items', 200)` → reject with a clear message if at/over cap.

`plugins/oblsk_phone/server/services/GalleryService.lua`:
- `GalleryService.getDefaultAlbum(characterId)` — finds or lazily creates the character's `is_default = true` "Camera Roll" album.
- `GalleryService.listAlbums(characterId)`, `GalleryService.createAlbum(characterId, name)`, `GalleryService.renameAlbum`, `GalleryService.deleteAlbum` — deleting a non-default album reassigns its `phone_media` rows to the character's default "Camera Roll" album rather than deleting them, so a mistaken album delete never loses a capture. The default album itself cannot be deleted.
- `GalleryService.listMedia(characterId, albumId)` — reverse-chronological by `taken_at`.
- `GalleryService.deleteMedia(characterId, mediaId)` — ownership check, `Storage.delete(storage_key)`, then the DB row.
- `GalleryService.sendToConversation(characterId, mediaId, threadId)` — ownership + thread-membership check, calls `MessagesService.send(characterId, threadId, nil, {url=..., kind=...})` (the new optional `media` param).

Net events follow the existing `RegisterNetEvent` + `Obelisk.emitClient` reply convention (`oblsk_phone:server:cameraCapturePhoto`, `oblsk_phone:server:cameraStartVideo`, `oblsk_phone:server:cameraStopVideo`, `oblsk_phone:server:galleryListMedia`, etc. — exact names finalized in the plan against the existing Messages event-naming pattern).

## Frontend

`plugins/oblsk_phone/web/apps/Camera/Camera.vue` — shutter button toggles photo/video mode (tap = photo, hold or a mode-switch tap = video per whatever the existing phone shell's interaction conventions are — decided in the plan); on video, shows a recording indicator + elapsed time + a stop button while `captureId` is active; on capture success, a brief toast ("Saved to Gallery") and no navigation away (matches "auto-save" decision below).

`plugins/oblsk_phone/web/apps/Gallery/Gallery.vue` — album list / album grid (thumbnail-less; photos render directly, videos render a `<video>` with no autoplay) toggle, matching the list-view/detail-view toggle pattern from `Messages.vue`; a media detail view with Delete and "Send to conversation" (opens the existing thread-picker UI, reused from Messages) actions.

Registered in `PhoneAppRegistry.CATALOG` as built-in apps (`app_key: 'camera'` and `'gallery'`), tile metadata in `oblsk_phone/web/phone/appMeta.js` using the icon/color values already present in the design mockup's tile metadata (`camera: icon 'camera', #1f2937` / `gallery: icon 'image', #3f2b56`).

## UX decisions (from brainstorming)

- **Ownership**: character-scoped, like Messages — a new character starts with an empty Gallery.
- **Capture flow**: auto-save immediately on successful upload, no keep/discard review step.
- **Video controls**: manual tap-to-start / tap-to-stop, with a server-enforced 15s hard cap as a safety net.
- **Organization**: albums (not a flat single roll) — every character gets an auto-created default "Camera Roll" album; new albums are user-created.
- **Quota**: `phone_gallery_max_items` convar (default 200), enforced per-character across all albums combined; new captures are rejected with a clear message once at/over the cap (no auto-deletion).
- **Messages-attach**: included in this sub-project — a minimal `media_url`/`media_kind` addition to `phone_messages` plus an optional param on `MessagesService.send`, not a payload-format redesign.

## Testing

Follows this repo's hand-rolled `lua5.4 tests/*_spec.lua` convention. `screencapture`'s exports are mocked the same way `PerformHttpRequest` was mocked for the S3 storage adapter — a test stub records calls and lets tests assert on what `CameraService`/`GalleryService` passed to `exports.screencapture:*`, without a real FXServer runtime. Manual verification (not automated, same as the storage service's own manual-verification section): a live stack with `screencapture` actually installed, confirming a real photo and a real short video round-trip end-to-end (capture → upload → `phone_media` row → visible in Gallery).

## Out of scope (matches this decomposition)

- Sending photos to Bleeter (doesn't exist yet).
- Photo/video editing.
- Cloud backup/sync.
- Live streaming.
