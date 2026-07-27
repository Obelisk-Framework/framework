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

if not _G.json then
    _G.json = {
        encode = function(v)
            local t = type(v)
            if t == 'string' then return '"' .. v .. '"' end
            if t == 'table' then
                return next(v) == nil and '{}' or '{...}'
            end
            return tostring(v)
        end,
        decode = function() return {} end,
    }
end
