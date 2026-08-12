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

--- @param key string
--- @param bytes string raw file contents
--- @param _contentType string unused by the local provider (no metadata store)
--- @return string url
function StorageLocal.put(key, bytes, _contentType)
  SaveResourceFile(GetCurrentResourceName(), resourcePath(key), bytes, #bytes)
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
  return config.urlPrefix .. '/' .. key
end
