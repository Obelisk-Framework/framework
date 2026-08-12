# Storage service: pluggable file storage + upload endpoint

**Goal:** Give core a generic "put a file somewhere, get a URL back" primitive
with a local-disk provider and an S3-compatible provider (AWS S3, MinIO,
Cloudflare R2, DigitalOcean Spaces — anything speaking the S3 API), plus an
HTTP upload endpoint that FiveM's `screenshot-basic` resource can POST to
directly. Nothing here is phone-specific — this is a prerequisite for the
upcoming Camera app (`oblsk_phone`), but any future plugin needing to store a
file (avatars, document attachments, etc.) uses the same API.

**Source:** greenfield — core has no HTTP handler or object-storage concept
today. `Database.init()`'s driver-selection-by-convar pattern
(`core/core/server/...`, gated on `db_driver`) is the direct precedent this
design follows for `storage_driver`.

## Architecture

`core/core/server/Services/StorageService.lua` exposes three functions:

- **`Storage.put(key, bytes, contentType)`** → `url` string. `key` is a
  caller-chosen path-like string (e.g. `phone-photos/<uuid>.jpg`); the caller
  is responsible for uniqueness (a collision silently overwrites, same as
  writing a file to a path).
- **`Storage.delete(key)`** → `boolean` (true if something was deleted).
- **`Storage.url(key)`** → `url` string, without touching storage (for
  reconstructing a URL from a previously-stored key, e.g. after a server
  restart with no in-memory cache).

`StorageService` itself contains no I/O — it loads one adapter module at
boot, based on `GetConvar('storage_driver', 'local')`, and forwards all three
calls to it. Boot fails fast (`error(...)`, matching `Database.init()`) if
the selected driver's required convars are missing. Each adapter is a plain
Lua module returning `{ put, delete, url }` with the same signatures:

- **`core/core/server/Services/storage/local.lua`** — writes under
  `GetConvar('storage_local_path', 'storage/')` (relative to the resource's
  working directory; gitignored the same way `server.cfg` already is — the
  spec's job is the code path, the `.gitignore` entry is a one-line
  implementation-plan task). `url(key)` returns `/storage/<key>` relative to
  core's own HTTP mount (see below); `put` creates parent directories as
  needed; `delete` removes the file, no-ops if absent.
- **`core/core/server/Services/storage/s3.lua`** — convars:
  `storage_s3_endpoint`, `storage_s3_bucket`, `storage_s3_key`,
  `storage_s3_secret`, `storage_s3_region` (default `us-east-1`, works
  unchanged for MinIO/R2/Spaces since they all accept a region string even
  when they don't route on it). `put`/`delete` issue signed HTTP requests via
  FXServer's `PerformHttpRequest`; `url` returns `<endpoint>/<bucket>/<key>`
  (path-style — matches every S3-compatible target this design lists, avoids
  the virtual-hosted-style DNS requirements that path-style doesn't need).

**SigV4 signer** (`core/core/server/Services/storage/sigv4.lua`): a small,
self-contained AWS Signature Version 4 implementation (canonical request →
string to sign → signing key derivation → signature), since no HTTP client
library in the FXServer Lua sandbox does this already. Pure functions over
strings/bytes, no I/O — this is what gets the dedicated unit tests (below);
`s3.lua` itself is a thin wrapper that builds a request and calls the signer.

## Upload endpoint

Core registers one HTTP handler via `SetHttpHandler` (in the same service or
a small `core/core/server/Services/storage/upload_handler.lua` — decide
during planning which keeps `StorageService.lua` from growing too large):

- **`POST /storage/upload`** — multipart/form-data. Requires a
  `token` field: a short-lived (60s TTL), single-use, server-minted token
  (random string, held in an in-memory table with an expiry, no DB row —
  matches the ephemeral nature of "this upload window is open right now").
  Any caller wanting an upload calls
  `Storage.mintUploadToken(key, contentType)` server-side first, which
  registers the pending upload and returns the token; the token is handed to
  the client, which passes it straight to
  `exports['screenshot-basic']:requestScreenshotUpload(url, 'files[]', {}, cb)`
  (or an equivalent raw POST) targeting `http://<server>/storage/upload` with
  that token in the form body. On receipt, the handler validates the token
  hasn't expired/been used, calls `Storage.put(key, bytes, contentType)` with
  the `key` the token was minted for (never a key the client supplies
  directly — this is what keeps the endpoint from being an open write-anything
  primitive), marks the token consumed, responds `200` with `{ url }`. Local
  dev (no public IP) works the same way `PerformHttpRequest`-based server↔
  client interactions already do in this framework — no extra tunneling setup
  implied by this design; if FXServer's client-to-server HTTP path needs a
  public/forwarded port for `screenshot-basic` to reach it, that's an
  existing FiveM server-hosting concern, not new surface added here.

## Server config additions (`server.cfg.example`)

```
# "local" (default) or "s3".
set storage_driver "local"

# local provider
set storage_local_path "storage/"

# s3 provider (S3-compatible: AWS S3, MinIO, R2, Spaces, ...)
# set storage_s3_endpoint "https://s3.us-east-1.amazonaws.com"
# set storage_s3_bucket "obelisk-uploads"
# set storage_s3_key "changeme"
# set storage_s3_secret "changeme"
# set storage_s3_region "us-east-1"
```

## Testing

- **`sigv4.lua`**: unit tests against AWS's published SigV4 test vectors
  (canonical request, string-to-sign, and final signature for a known
  fixed request/credentials/date) — this is the one piece with real
  correctness risk, gets the most scrutiny.
- **`local.lua`**: `lua5.4 *_spec.lua` against a real temp directory —
  put/url/delete round trip, put creating nested directories, delete on a
  missing key not erroring.
- **`s3.lua`**: request-shape tests only (asserts the right method/headers/
  signed-URL are built for a given put/delete/url call) with
  `PerformHttpRequest` stubbed — no live network call in the test suite, no
  test-only S3 credentials to manage. A live round-trip against a real
  S3-compatible endpoint is a manual/ops verification step, not part of the
  automated suite.
- **Upload endpoint**: token mint → valid upload → 200 with correct URL;
  expired token rejected; reused (already-consumed) token rejected; missing
  token rejected. Exercised by calling the handler function directly with a
  constructed request table, not a real HTTP round trip (matches this
  repo's existing pattern of testing Lua logic directly rather than spinning
  up a server in tests).

## Out of scope

- SFTP provider — dropped; the adapter interface is generic enough to add
  one later if actually needed, but it requires shelling out to an external
  binary or a sidecar process, which is real ops complexity for a rarely-used
  option (see design discussion).
- Anything Camera/`oblsk_phone`-specific (calling `Storage.mintUploadToken`
  from the phone, the `phone_photos` table, the Gallery UI) — that's the next
  sub-project.
- Per-file access control / signed read URLs — every stored file is
  publicly readable at its URL once uploaded (same trust model as a typical
  FiveM screenshot-basic + Discord-webhook setup, just self-hosted). Revisit
  if a future caller needs private files.
- Automatic cleanup/garbage collection of orphaned files (e.g. a `Storage.put`
  whose owning DB row later gets deleted) — each caller is responsible for
  calling `Storage.delete` when it deletes its own row, same as today's
  pattern of no cascading file cleanup anywhere else in the framework.
