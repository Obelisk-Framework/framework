--- WeatherConfigLoader - loads WeatherConfig.lua if a server owner has
--- created one (gitignored, so their edits survive a git pull), falling
--- back to the tracked WeatherConfig.lua.example defaults otherwise. Config
--- files themselves stay data-only; this is the only place that knows how
--- to find one.
if WeatherConfig then
    return
end

if not LoadConfigFile('core/server/Config/WeatherConfig.lua') then
    LoadConfigFile('core/server/Config/WeatherConfig.lua.example')
end
