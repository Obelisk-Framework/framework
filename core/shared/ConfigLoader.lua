local resourceName = GetCurrentResourceName()

function LoadConfigFile(path)
    local content = LoadResourceFile(resourceName, path)
    if not content then
        return false
    end
    local chunk = load(content, '@' .. path)
    if not chunk then
        return false
    end
    chunk()
    return true
end
