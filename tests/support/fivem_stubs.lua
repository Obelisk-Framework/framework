--- Minimal FiveM / CitizenFX global stubs.
--- These let the *pure* ORM layer (Database, QueryBuilder, Schema, BaseModel)
--- be loaded and unit tested under a vanilla Lua interpreter, without a running
--- FiveM server. Only the globals those files actually touch are stubbed;
--- network / native / NUI behaviour is intentionally out of scope.

_G.Citizen = _G.Citizen or {
    -- Run threads synchronously so async helpers are testable if needed.
    CreateThread = function(fn) fn() end,
    Wait = function() end,
}

_G.exports = _G.exports or setmetatable({}, {__index = function() return {} end})

-- No MySQL connector is present in tests. Tests that need query execution
-- install their own spy over Database.executeQuery / Database.querySync;
-- individual tests override GetResourceState when they exercise connector
-- detection.
_G.GetResourceState = _G.GetResourceState or function() return 'stopped' end
_G.GetConvar = _G.GetConvar or function(_, default) return default end
_G.GetConvarInt = _G.GetConvarInt or function(_, default) return default end
_G.IsDuplicityVersion = _G.IsDuplicityVersion or function() return true end
_G.RegisterNetEvent = _G.RegisterNetEvent or function() end
_G.AddEventHandler = _G.AddEventHandler or function() end
_G.TriggerEvent = _G.TriggerEvent or function() end
_G.TriggerServerEvent = _G.TriggerServerEvent or function() end
_G.TriggerClientEvent = _G.TriggerClientEvent or function() end

--- Minimal but real JSON encode/decode. Good enough for flat/simple-nested
--- fixtures in the test suite; not a general-purpose JSON library (no
--- unicode escapes, no scientific notation). Only exists here because the
--- real FXServer `json` global isn't available under a vanilla Lua
--- interpreter, and BaseModel's JSON casts (see BaseModel.lua) need
--- something that actually round-trips to be testable at all.
if not _G.json then
    local function encodeValue(v)
        local t = type(v)
        if v == nil then
            return 'null'
        elseif t == 'boolean' then
            return v and 'true' or 'false'
        elseif t == 'number' then
            return tostring(v)
        elseif t == 'string' then
            return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
        elseif t == 'table' then
            local n = 0
            local isArray = true
            for k in pairs(v) do
                n = n + 1
                if type(k) ~= 'number' or k ~= math.floor(k) or k < 1 then
                    isArray = false
                end
            end
            if n == 0 then
                return '{}'
            elseif isArray then
                local parts = {}
                for i = 1, n do
                    parts[i] = encodeValue(v[i])
                end
                return '[' .. table.concat(parts, ',') .. ']'
            else
                local parts = {}
                for k, val in pairs(v) do
                    table.insert(parts, '"' .. tostring(k) .. '":' .. encodeValue(val))
                end
                return '{' .. table.concat(parts, ',') .. '}'
            end
        end
        return 'null'
    end

    local decodeValue

    local function skipSpace(s, i)
        while i <= #s and s:sub(i, i):match('%s') do
            i = i + 1
        end
        return i
    end

    decodeValue = function(s, i)
        i = skipSpace(s, i)
        local c = s:sub(i, i)
        if c == '{' then
            local obj = {}
            i = skipSpace(s, i + 1)
            if s:sub(i, i) == '}' then
                return obj, i + 1
            end
            while true do
                local key, ni = decodeValue(s, i)
                i = skipSpace(s, ni)
                i = i + 1 -- skip ':'
                local val, ni2 = decodeValue(s, i)
                obj[key] = val
                i = skipSpace(s, ni2)
                if s:sub(i, i) == ',' then
                    i = skipSpace(s, i + 1)
                else
                    break
                end
            end
            return obj, i + 1
        elseif c == '[' then
            local arr = {}
            i = skipSpace(s, i + 1)
            if s:sub(i, i) == ']' then
                return arr, i + 1
            end
            while true do
                local val, ni = decodeValue(s, i)
                table.insert(arr, val)
                i = skipSpace(s, ni)
                if s:sub(i, i) == ',' then
                    i = skipSpace(s, i + 1)
                else
                    break
                end
            end
            return arr, i + 1
        elseif c == '"' then
            i = i + 1
            local buf = {}
            while s:sub(i, i) ~= '"' do
                if s:sub(i, i) == '\\' then
                    table.insert(buf, s:sub(i + 1, i + 1))
                    i = i + 2
                else
                    table.insert(buf, s:sub(i, i))
                    i = i + 1
                end
            end
            return table.concat(buf), i + 1
        elseif c == 't' then
            return true, i + 4
        elseif c == 'f' then
            return false, i + 5
        elseif c == 'n' then
            return nil, i + 4
        else
            local numStr = s:match('^%-?%d+%.?%d*', i)
            if not numStr then
                error('json.decode: unexpected character at position ' .. i)
            end
            return tonumber(numStr), i + #numStr
        end
    end

    _G.json = {
        encode = encodeValue,
        decode = function(s)
            if type(s) ~= 'string' or s == '' then
                error('json.decode: invalid input')
            end
            local value = decodeValue(s, 1)
            return value
        end,
    }
end

-- Resource-relative file natives, backed by a real temp directory so
-- core/server/Services/storage/local.lua's tests exercise real file I/O.
-- Not resource-name-aware (single global root) — fine for this test suite,
-- which only ever runs as one "resource" at a time.
local RESOURCE_FILE_ROOT = os.tmpname()
os.remove(RESOURCE_FILE_ROOT) -- os.tmpname() creates the file; we want it as a directory
os.execute('mkdir -p ' .. RESOURCE_FILE_ROOT)

_G.GetCurrentResourceName = _G.GetCurrentResourceName or function() return 'core' end

_G.GetResourcePath = _G.GetResourcePath or function(_) return RESOURCE_FILE_ROOT end

local function ensureParentDir(fullPath)
    local dir = fullPath:match('(.*/)')
    if dir then os.execute('mkdir -p ' .. dir) end
end

_G.SaveResourceFile = _G.SaveResourceFile or function(_, path, data, _len)
    local full = RESOURCE_FILE_ROOT .. '/' .. path
    ensureParentDir(full)
    local f = io.open(full, 'wb')
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

_G.LoadResourceFile = _G.LoadResourceFile or function(_, path)
    local full = RESOURCE_FILE_ROOT .. '/' .. path
    local f = io.open(full, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

_G.RemoveResourceFile = _G.RemoveResourceFile or function(_, path)
    local full = RESOURCE_FILE_ROOT .. '/' .. path
    return os.remove(full) ~= nil
end
