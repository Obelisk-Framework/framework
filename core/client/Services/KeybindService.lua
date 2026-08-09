--- Client KeybindService - Handles keybind registration and triggering
KeybindService = {}
KeybindService.keybinds = {}
KeybindService.keyMap = {} -- Map key codes to keybind IDs

--- Sync keybinds from server
Obelisk.onClient('core:server:keybinds-sync', function(keybinds)
    KeybindService.keybinds = keybinds
    KeybindService.keyMap = {}
    
    -- Build key map for quick lookup
    for _, keybind in ipairs(keybinds) do
        if not KeybindService.keyMap[keybind.key_code] then
            KeybindService.keyMap[keybind.key_code] = {}
        end
        table.insert(KeybindService.keyMap[keybind.key_code], keybind)
    end
    
    print('[KeybindService] Loaded ' .. #keybinds .. ' keybinds')
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
function KeybindService.checkKeyPress(keyCode)
    local keybinds = KeybindService.keyMap[keyCode]
    
    if not keybinds then return end
    
    for _, keybind in ipairs(keybinds) do
        if keybind.action_id then
            -- Parse data if JSON string
            local data = keybind.data
            if type(data) == 'string' then
                data = json.decode(data)
            end
            
            -- Trigger action on server
            Obelisk.emitServer('core:client:keybinds-pressed', keybind.action_id, data or {})
        end
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
