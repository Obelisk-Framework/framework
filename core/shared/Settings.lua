--- Global date/number/currency formatting settings, read from server.cfg
--- convars. Shared across client and server (see fxmanifest.lua's
--- shared_scripts glob) so both sides format identically.
Settings = {}

local DEFAULTS = {
    dateFormat = 'YYYY-MM-DD',
    decimalSep = '.',
    thousandsSep = ',',
    currencySymbol = '$',
    currencyPosition = 'before',
    timezoneOffsetMinutes = 0,
}

Settings.format = {}

function Settings.init()
    Settings.format = {
        dateFormat = GetConvar('date_format', DEFAULTS.dateFormat),
        decimalSep = GetConvar('number_decimal_sep', DEFAULTS.decimalSep),
        thousandsSep = GetConvar('number_thousands_sep', DEFAULTS.thousandsSep),
        currencySymbol = GetConvar('currency_symbol', DEFAULTS.currencySymbol),
        currencyPosition = GetConvar('currency_position', DEFAULTS.currencyPosition),
        timezoneOffsetMinutes = GetConvarInt('timezone_offset_minutes', DEFAULTS.timezoneOffsetMinutes),
    }
end

--- @param timestamp number unix timestamp (seconds, UTC)
--- @return string
function Settings.formatDate(timestamp)
    local shifted = timestamp + Settings.format.timezoneOffsetMinutes * 60
    local t = os.date('!*t', shifted)
    local tokens = {
        YYYY = string.format('%04d', t.year),
        MM = string.format('%02d', t.month),
        DD = string.format('%02d', t.day),
        HH = string.format('%02d', t.hour),
        mm = string.format('%02d', t.min),
        ss = string.format('%02d', t.sec),
    }
    return (Settings.format.dateFormat:gsub('YYYY', tokens.YYYY):gsub('MM', tokens.MM):gsub('DD', tokens.DD)
        :gsub('HH', tokens.HH):gsub('mm', tokens.mm):gsub('ss', tokens.ss))
end

--- @param n number
--- @return string
function Settings.formatNumber(n)
    local sign = ''
    if n < 0 then
        sign = '-'
        n = -n
    end

    local intPart, fracPart = math.floor(n), n - math.floor(n)
    local intStr = tostring(intPart)

    local sep = Settings.format.thousandsSep
    local grouped = intStr:reverse():gsub('(%d%d%d)', '%1' .. sep):reverse()
    if grouped:sub(1, #sep) == sep then
        grouped = grouped:sub(#sep + 1)
    end

    if fracPart == 0 then
        return sign .. grouped
    end

    local fracStr = string.format('%.2f', fracPart):sub(3)
    return sign .. grouped .. Settings.format.decimalSep .. fracStr
end

--- @param n number
--- @return string
function Settings.formatCurrency(n)
    local formatted = Settings.formatNumber(n)
    if Settings.format.currencyPosition == 'after' then
        return formatted .. Settings.format.currencySymbol
    end
    return Settings.format.currencySymbol .. formatted
end

Settings.init()
