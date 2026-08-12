--- Client KeybindService - keeps a local {keyCode -> [actionId]} map in
--- sync with the server's resolved keybinds and dispatches key presses.
KeybindService = {}
KeybindService.keyMap = {} -- {keyCode -> actionId[]}

--- Sync keybinds from server: resolved is {actionId -> key}
Obelisk.onClient('core:server:keybinds-sync', function(resolved)
    local keyMap = {}
    local count = 0
    for actionId, key in pairs(resolved) do
        if key then
            keyMap[key] = keyMap[key] or {}
            table.insert(keyMap[key], actionId)
            count = count + 1
        end
    end
    KeybindService.keyMap = keyMap

    print('[KeybindService] Loaded ' .. count .. ' resolved keybinds')
end)

--- Request keybinds from server
function KeybindService.requestSync()
    Obelisk.emitServer('core:client:keybinds-requestSync')
end

--- Server told us a keybind changed (an override was set/cleared) elsewhere;
--- re-request our own list so it reflects the change.
Obelisk.onClient('core:server:keybinds-requestSync', function()
    KeybindService.requestSync()
end)

--- Check if key is pressed and trigger every action bound to it. More than
--- one action can share a key (e.g. B for both seatbelt and point) -- all
--- of them fire, there's no first-match-wins behavior.
--- @param keyCode string
function KeybindService.checkKeyPress(keyCode)
    local actionIds = KeybindService.keyMap[keyCode]
    if not actionIds then return end

    for _, actionId in ipairs(actionIds) do
        Obelisk.emitServer('core:client:keybinds-pressed', actionId)
    end
end

--- Main thread to monitor key presses
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)

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
