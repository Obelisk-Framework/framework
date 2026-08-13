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

--- Key label -> Win32 virtual-key code, covering every key the oblsk_keybinds
--- settings UI (Keybinds.vue's KB_ROWS/kbNameFor) can produce. Uses
--- IsRawKeyPressed (raw OS keyboard state) rather than IsControlJustPressed
--- because most of these keys (F-keys, punctuation, brackets, ...) have no
--- native GTA5 control mapping at all.
local KEY_TO_VK = {
    Space = 0x20, CapsLock = 0x14, Tab = 0x09, Enter = 0x0D, Backspace = 0x08,
    Shift = 0xA0, RShift = 0xA1, Ctrl = 0xA2, RCtrl = 0xA3, Alt = 0xA4, RAlt = 0xA5,
    [','] = 0xBC, ['.'] = 0xBE, ['/'] = 0xBF, [';'] = 0xBA, ["'"] = 0xDE,
    ['['] = 0xDB, [']'] = 0xDD, ['\\'] = 0xDC, ['-'] = 0xBD, ['='] = 0xBB, ['`'] = 0xC0,
}
for i = 1, 12 do KEY_TO_VK['F' .. i] = 0x6F + i end
for i = 0, 25 do KEY_TO_VK[string.char(65 + i)] = 0x41 + i end -- A-Z
for i = 0, 9 do KEY_TO_VK[tostring(i)] = 0x30 + i end -- 0-9

--- Main thread to monitor key presses
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)

        -- Don't dispatch while NUI has focus (e.g. rebinding in the
        -- Keybinds settings screen itself) - raw key state fires
        -- regardless of NUI focus, unlike IsControlJustPressed.
        if not WebView.state.focus then
            for keyName in pairs(KeybindService.keyMap) do
                local vk = KEY_TO_VK[keyName]
                if vk and IsRawKeyPressed(vk) then
                    KeybindService.checkKeyPress(keyName)
                end
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
