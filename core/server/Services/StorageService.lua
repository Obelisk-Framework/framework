--- Generic file storage: put/delete/url, dispatched to one adapter chosen at
--- boot by the storage_driver convar. Mirrors Database.init()'s driver-
--- selection-by-convar pattern (core/server/ORM/Database.lua) — same
--- fail-fast-with-a-loud-print behaviour, no in-memory fallback.
Storage = {}

Storage.ready = false
Storage.driver = nil -- 'local' | 's3'
local adapter = nil  -- the selected adapter table (StorageLocal or StorageS3)

local function failInit(lines)
  Storage.ready = false
  print('[Storage] ============================================================')
  for _, line in ipairs(lines) do print('[Storage] ' .. line) end
  print('[Storage] ============================================================')
  return false
end

--- @return boolean ready
function Storage.init()
  local driver = GetConvar('storage_driver', 'local')

  if driver == 'local' then
    StorageLocal.configure({
      basePath = GetConvar('storage_local_path', 'storage'),
      urlPrefix = '/storage',
    })
    adapter = StorageLocal
  elseif driver == 's3' then
    local endpoint = GetConvar('storage_s3_endpoint', '')
    local bucket = GetConvar('storage_s3_bucket', '')
    local accessKey = GetConvar('storage_s3_key', '')
    local secretKey = GetConvar('storage_s3_secret', '')
    if endpoint == '' or bucket == '' or accessKey == '' or secretKey == '' then
      return failInit({
        'FATAL: storage_driver "s3" requires storage_s3_endpoint, storage_s3_bucket,',
        'storage_s3_key and storage_s3_secret to all be set.',
        'Set them in server.cfg, or switch storage_driver back to "local".',
      })
    end
    StorageS3.configure({
      endpoint = endpoint,
      bucket = bucket,
      accessKey = accessKey,
      secretKey = secretKey,
      region = GetConvar('storage_s3_region', 'us-east-1'),
    })
    adapter = StorageS3
  else
    return failInit({
      'FATAL: unknown storage_driver "' .. tostring(driver) .. '".',
      'Valid values: "local" (default), "s3".',
    })
  end

  -- Note: the /storage/upload HTTP handler (core/server/Services/storage/
  -- upload_handler.lua) self-registers via SetHttpHandler when that file
  -- loads (see fxmanifest.lua's storage/*.lua glob) — nothing to call here.
  Storage.driver = driver
  Storage.ready = true
  print('[Storage] Initialized (driver: ' .. driver .. ')')
  return true
end

--- @param key string
--- @param bytes string raw file contents
--- @param contentType string MIME type, e.g. 'image/jpeg'
--- @return string url
function Storage.put(key, bytes, contentType)
  if not Storage.ready then
    error('[Storage] not initialized — Storage.init() must succeed before use', 2)
  end
  return adapter.put(key, bytes, contentType)
end

--- @param key string
--- @return boolean
function Storage.delete(key)
  if not Storage.ready then
    error('[Storage] not initialized — Storage.init() must succeed before use', 2)
  end
  return adapter.delete(key)
end

--- @param key string
--- @return string url
function Storage.url(key)
  if not Storage.ready then
    error('[Storage] not initialized — Storage.init() must succeed before use', 2)
  end
  return adapter.url(key)
end

--- Builds the absolute URL screencapture's server-side exports (or any
--- other out-of-process uploader) POST to. FXServer mounts a resource's
--- HTTP handler under /<resourceName>/..., and plugins/*/server/**/*.lua
--- loads into the same single resource as core (see fxmanifest.lua's
--- globs), so this resource's own name is always the right prefix no
--- matter which plugin calls this. storage_http_port must match whatever
--- port this server's endpoint_add_tcp/endpoint_add_udp lines in
--- server.cfg actually use (no other convar exposes this).
--- @return string url
function Storage.uploadUrl()
  local port = GetConvarInt('storage_http_port', 30120)
  return string.format('http://127.0.0.1:%d/%s/storage/upload', port, GetCurrentResourceName())
end

local PENDING_UPLOADS = {} -- token -> { key, contentType, expiresAt }
local TOKEN_TTL_SECONDS = 60

local function randomToken()
  local chars = '0123456789abcdefghijklmnopqrstuvwxyz'
  local out = {}
  for i = 1, 32 do
    local n = math.random(1, #chars)
    out[i] = chars:sub(n, n)
  end
  return table.concat(out)
end

--- Registers a pending upload and returns a short-lived, single-use token
--- for it. The caller hands this token to the client, which posts it (with
--- the file) to POST /storage/upload — the handler only ever writes to the
--- exact `key` this call registered, never a key the client supplies.
--- @param key string
--- @param contentType string
--- @return string token
function Storage.mintUploadToken(key, contentType)
  local token = randomToken()
  PENDING_UPLOADS[token] = { key = key, contentType = contentType, expiresAt = os.time() + TOKEN_TTL_SECONDS }
  return token
end

--- Consumes a token if valid (exists, not expired). Single-use: removes it
--- either way once looked up, so a second call for the same token always
--- misses. Returns nil if the token was never valid.
--- @param token string
--- @return table|nil { key, contentType }
function Storage.consumeUploadToken(token)
  local entry = PENDING_UPLOADS[token]
  PENDING_UPLOADS[token] = nil
  if not entry then return nil end
  if entry.expiresAt < os.time() then return nil end
  return entry
end
