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
  return adapter.put(key, bytes, contentType)
end

--- @param key string
--- @return boolean
function Storage.delete(key)
  return adapter.delete(key)
end

--- @param key string
--- @return string url
function Storage.url(key)
  return adapter.url(key)
end
