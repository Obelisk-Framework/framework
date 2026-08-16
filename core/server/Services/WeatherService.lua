WeatherService = {}

local WEATHER_GRAPH = {
    CLEAR    = { CLEAR=0.4, CLOUDS=0.4, SMOG=0.1, FOGGY=0.1 },
    CLOUDS   = { CLEAR=0.3, CLOUDS=0.2, OVERCAST=0.4, FOGGY=0.1 },
    OVERCAST = { CLOUDS=0.2, OVERCAST=0.2, RAIN=0.4, FOGGY=0.2 },
    RAIN     = { OVERCAST=0.3, RAIN=0.4, THUNDER=0.3 },
    THUNDER  = { RAIN=0.5, OVERCAST=0.3, THUNDER=0.2 },
    FOGGY    = { CLEAR=0.3, CLOUDS=0.4, FOGGY=0.3 },
    SMOG     = { CLEAR=0.5, SMOG=0.5 },
    SNOW     = { SNOW=0.4, OVERCAST=0.3, BLIZZARD=0.1, CLOUDS=0.2 },
    BLIZZARD = { SNOW=0.6, BLIZZARD=0.4 },
    NEUTRAL  = { CLEAR=0.5, CLOUDS=0.5 },
}

local function isSnowMonth(month)
    for _, m in ipairs(WeatherConfig.seasons.snow_months) do
        if m == month then return true end
    end
    return false
end

--- @param month number 1-12
--- @param now number unix epoch (unused, kept for signature consistency)
--- @return number temperature in °C
function WeatherService.getTemperature(month, now)
    local cfg = WeatherConfig.climate
    -- cosine wave: peak in July (month 7), trough in January (month 1)
    local angle = ((month - 7) / 12) * 2 * math.pi
    return cfg.base_temp_c + cfg.temp_amplitude * math.cos(angle)
end

--- @param month number 1-12
--- @param prevType string previous weather type
--- @param rng function() → [0,1]
--- @return string next weather type
function WeatherService.getWeatherType(month, prevType, rng)
    local weights = {}
    local base = WEATHER_GRAPH[prevType] or WEATHER_GRAPH['CLEAR']
    -- remove snow types outside snow months
    for k, v in pairs(base) do
        if isSnowMonth(month) or (k ~= 'SNOW' and k ~= 'BLIZZARD') then
            weights[k] = v
        end
    end
    -- weighted random pick
    local total = 0
    for _, w in pairs(weights) do total = total + w end
    local r = rng() * total
    local cumulative = 0
    for weatherType, w in pairs(weights) do
        cumulative = cumulative + w
        if r <= cumulative then return weatherType end
    end
    return 'CLEAR'
end

--- Generate full 14-day forecast starting at `now`, writing to DB.
--- Each 2-hour window is inserted as its own row.
--- @param now number unix epoch seconds
function WeatherService.generateForecast(now)
    local cfg = WeatherConfig
    local totalWindows = cfg.lookahead_days * (86400 / cfg.window_duration)
    local prevType = 'CLEAR'
    for i = 0, totalWindows - 1 do
        local wStart = now + i * cfg.window_duration
        local wEnd   = wStart + cfg.window_duration
        local date   = os.date('*t', wStart)
        local wType  = WeatherService.getWeatherType(date.month, prevType, math.random)
        local temp   = WeatherService.getTemperature(date.month, wStart)
        local precip = (wType == 'RAIN' or wType == 'THUNDER') and math.random() * 0.8 + 0.2 or 0
        QueryBuilder.new('weather_forecast'):insert({
            window_start  = wStart,
            window_end    = wEnd,
            weather_type  = wType,
            temperature   = math.floor(temp * 10) / 10,
            precipitation = math.floor(precip * 100) / 100,
            wind_speed    = math.floor(math.random() * 30 * 10) / 10,
            generated_at  = now,
        })
        prevType = wType
    end
end

--- @return table[] array of window rows ordered by window_start asc
function WeatherService.getForecast()
    return QueryBuilder.new('weather_forecast')
        :orderBy('window_start', 'asc')
        :getSync()
end

--- @param now number unix epoch
--- @return table|nil current window row
function WeatherService.getCurrentWindow(now)
    return QueryBuilder.new('weather_forecast')
        :where('window_start', '<=', now)
        :where('window_end', '>', now)
        :firstSync()
end

--- Called on server boot. Clears stale forecast and regenerates if needed.
--- @param now number unix epoch
function WeatherService.boot(now)
    local latest = QueryBuilder.new('weather_forecast')
        :orderBy('window_end', 'desc')
        :firstSync()
    if not latest or latest.window_end < now + 86400 then
        QueryBuilder.new('weather_forecast'):delete()
        WeatherService.generateForecast(now)
    end
end

WeatherService._currentWindow = nil

--- Advance window if expired; sync to all clients.
--- @param now number unix epoch
function WeatherService.tick(now)
    local window = WeatherService.getCurrentWindow(now)
    if not window then return end
    if WeatherService._currentWindow and WeatherService._currentWindow.id == window.id then
        return  -- same window, no change
    end
    WeatherService._currentWindow = window
    TriggerClientEvent('oblsk:weather:sync', -1, {
        weather_type  = window.weather_type,
        temperature   = window.temperature,
        precipitation = window.precipitation,
        wind_speed    = window.wind_speed,
        window_start  = window.window_start,
        window_end    = window.window_end,
    })
    -- trim stale windows older than 1 day
    QueryBuilder.new('weather_forecast')
        :where('window_end', '<', now - 86400)
        :delete()
    -- extend forecast if lookahead drops below 1 day
    local farthest = QueryBuilder.new('weather_forecast')
        :orderBy('window_end', 'desc')
        :firstSync()
    if farthest and farthest.window_end < now + 86400 then
        WeatherService.generateForecast(farthest.window_end)
    end
end

--- Start the tick loop. Called once from bootstrap.
function WeatherService.startTick()
    CreateThread(function()
        while true do
            WeatherService.tick(os.time())
            Wait(30000)
        end
    end)
end
