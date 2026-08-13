--- Local-disk storage provider. Files live under GetResourcePath(resource)
--- .. '/' .. basePath, written/read via the resource-relative file natives
--- (SaveResourceFile/LoadResourceFile/RemoveResourceFile) — FXServer's Lua
--- sandbox has no io library, so this cannot use io.open directly.
StorageLocal = {}

local config = { basePath = 'storage', urlPrefix = '/storage' }

--- @param cfg table { basePath: string, urlPrefix: string }
function StorageLocal.configure(cfg)
  config.basePath = cfg.basePath or config.basePath
  config.urlPrefix = cfg.urlPrefix or config.urlPrefix
end

local function resourcePath(key)
  return config.basePath .. '/' .. key
end

--- @return string the configured basePath, e.g. 'storage' — exposed so
--- callers (e.g. the /storage/* GET handler in upload_handler.lua) can build
--- the same resource-relative path this module uses internally, without
--- hardcoding it and risking drift if basePath is ever reconfigured.
function StorageLocal.getBasePath()
  return config.basePath
end

--- @param key string
--- @param bytes string raw file contents
--- @param _contentType string unused by the local provider (no metadata store)
--- @return string url
function StorageLocal.put(key, bytes, _contentType)
  local ok = SaveResourceFile(GetCurrentResourceName(), resourcePath(key), bytes, #bytes)
  if not ok then
    error(string.format('[StorageLocal] put failed for key "%s": SaveResourceFile returned false', key), 2)
  end
  return StorageLocal.url(key)
end

--- @param key string
--- @return boolean
function StorageLocal.delete(key)
  return RemoveResourceFile(GetCurrentResourceName(), resourcePath(key)) and true or false
end

--- @param key string
--- @return string url
function StorageLocal.url(key)
  -- Must be absolute + resource-prefixed, not root-relative: the phone's
  -- NUI document loads from a nui://<resource>/... origin, so a bare
  -- '/storage/...' path never reaches the actual HTTP endpoint. Reuses
  -- Storage.baseUrl() (StorageService.lua) — the same construction
  -- Storage.uploadUrl() uses — to avoid duplicating it here.
  return Storage.baseUrl() .. config.urlPrefix .. '/' .. key
end
