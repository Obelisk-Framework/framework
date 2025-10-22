Hooks = {}
local registeredHooks = {}

--- Register a hook callback for a specific hook event.
-- @param hookName string: Event name to hook into.
-- @param callback function: Function to call when hook runs.
function Hooks.registerHook(hookName, callback)
    if not registeredHooks[hookName] then
        registeredHooks[hookName] = {}
    end
    table.insert(registeredHooks[hookName], callback)
end

--- Run all registered hook callbacks for a hook event.
-- Collect results in order of registration.
-- Supports synchronous and asynchronous (callback-based) hooks.
-- @param hookName string: Event name.
-- @param ... any: Arguments to pass to each hook callback.
-- @param finalCallback function(results): Called after all hooks run, with array of results.
function Hooks.runHook(hookName, finalCallback, ...)
    local hooks = registeredHooks[hookName] or {}

    local results = {}
    local index = 1
    local args = {...}

    local function runNext()
        if index > #hooks then
            finalCallback(results)
            return
        end

        local hook = hooks[index]
        index = index + 1

        -- Try to run hook; handle sync or async style
        local ok, result = pcall(hook, table.unpack(args))
        if not ok then
            print(("Hook '%s' handler error: %s"):format(hookName, result))
            results[#results + 1] = nil
            runNext()
            return
        end

        if type(result) == "function" then
            -- Assume async style: hook received a callback to call with result
            -- e.g. function(..., cb) return function(result) cb(result) end end
            result(function(res)
                results[#results + 1] = res
                runNext()
            end)
        else
            -- Synchronous result
            results[#results + 1] = result
            runNext()
        end
    end

    runNext()
end