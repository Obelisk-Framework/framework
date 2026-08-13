--- Client KeybindService - Handles keybind registration and triggering
KeybindService = {}
KeybindService.keybinds = {} -- {actionId -> key}
KeybindService.keyMap = {} -- Map key name (e.g. 'G') -> list of actionIds bound to it

--- Sync keybinds from server. Payload is the resolved {actionId -> key}
--- map from KeybindService.resolveAll (server), not a row array.
Obelisk.onClient('core:server:keybinds-sync', function(resolved)
    KeybindService.keybinds = resolved
    KeybindService.keyMap = {}

    local count = 0
    for actionId, key in pairs(resolved) do
        count = count + 1
        if key then
            if not KeybindService.keyMap[key] then
                KeybindService.keyMap[key] = {}
            end
            table.insert(KeybindService.keyMap[key], actionId)
        end
    end

    print('[KeybindService] Loaded ' .. count .. ' keybinds')
end)

--- Request keybinds from server
function KeybindService.requestSync()
    Obelisk.emitServer('core:client:keybinds-requestSync')
end

--- Server told us a keybind changed (register/update/delete) elsewhere;
--- re-request our own list so it reflects the change.
Obelisk.onClient('core:server:keybinds-requestSync', function()
    KeybindService.requestSync()
end)

--- Check if key is pressed and trigger associated actions
--- @param keyName string e.g. 'G' - matches the key strings resolved server-side
function KeybindService.checkKeyPress(keyName)
    local actionIds = KeybindService.keyMap[keyName]

    if not actionIds then return end

    for _, actionId in ipairs(actionIds) do
        Obelisk.emitServer('core:client:keybinds-pressed', actionId)
    end
end

--- Main thread to monitor key presses
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        
        -- Check for common keys
        local commonKeys = {
            ['E'] = 38,      -- E key
            ['F'] = 23,      -- F key
            ['G'] = 47,      -- G key
            ['X'] = 73,      -- X key
            ['Y'] = 246,     -- Y key
            ['U'] = 303,     -- U key
            ['SPACE'] = 22,  -- Space
            ['ENTER'] = 18,  -- Enter
            ['ESC'] = 322    -- Escape
        }
        
        for keyName, controlId in pairs(commonKeys) do
            if IsControlJustPressed(0, controlId) then
                KeybindService.checkKeyPress(keyName)
            end
        end
    end
end)

--- Request keybinds on script start
Citizen.CreateThread(function()
    Wait(2000) -- Wait for player to fully load
    KeybindService.requestSync()
end)

return KeybindService
