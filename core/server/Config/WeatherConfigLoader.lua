--- WeatherConfigLoader - loads WeatherConfig.lua if a server owner has
--- created one (gitignored, so their edits survive a git pull), falling
--- back to the tracked WeatherConfig.lua.example defaults otherwise. Config
--- files themselves stay data-only; this is the only place that knows how
--- to find one.
if WeatherConfig then
    return
end

local resourceName = GetCurrentResourceName()

local function loadConfigFile(path)
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

if not loadConfigFile('core/server/Config/WeatherConfig.lua') then
    loadConfigFile('core/server/Config/WeatherConfig.lua.example')
end
