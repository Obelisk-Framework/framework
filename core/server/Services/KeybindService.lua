--- KeybindService - Keybind management with database persistence
--- Links keys to actions, syncs to clients on connect
KeybindService = {}

--- Load all keybinds for a player from database
--- @param source number Player server ID
--- @param callback function Receives keybinds array
function KeybindService.loadPlayerKeybinds(source, callback)
    local identifier = GetPlayerIdentifier(source, 0) -- Get player identifier
    
    -- Query player keybinds from database
    local sql = [[
        SELECT k.*, a.id as action_id, a.label as action_label
        FROM keybinds k
        LEFT JOIN actions a ON k.action_id = a.id
        WHERE k.player_identifier = ? OR k.player_identifier IS NULL
        ORDER BY k.is_global DESC, k.id ASC
    ]]
    
    Database.query(sql, {identifier}, function(keybinds)
        callback(keybinds or {})
    end)
end

--- Load all keybinds synchronously
--- @param source number
--- @return table
function KeybindService.loadPlayerKeybindsSync(source)
    local identifier = GetPlayerIdentifier(source, 0)
    
    local sql = [[
        SELECT k.*, a.id as action_id, a.label as action_label
        FROM keybinds k
        LEFT JOIN actions a ON k.action_id = a.id
        WHERE k.player_identifier = ? OR k.player_identifier IS NULL
        ORDER BY k.is_global DESC, k.id ASC
    ]]
    
    return Database.querySync(sql, {identifier}) or {}
end

--- Send keybinds to client
--- @param source number Player server ID
function KeybindService.syncToClient(source)
    KeybindService.loadPlayerKeybinds(source, function(keybinds)
        TriggerClientEvent('obelisk:keybinds:sync', source, keybinds)
        print('[KeybindService] Synced ' .. #keybinds .. ' keybinds to player ' .. source)
    end)
end

--- Register a global keybind (applies to all players)
--- @param key string Key code (e.g., 'E', 'F', etc.)
--- @param actionId string Action to trigger
--- @param data table Optional default data
--- @return number keybindId
function KeybindService.registerGlobal(key, actionId, data)
    local sql = [[
        INSERT INTO keybinds (key_code, action_id, data, is_global, player_identifier)
        VALUES (?, ?, ?, 1, NULL)
    ]]
    
    local jsonData = data and json.encode(data) or nil
    local keybindId = Database.insertSync(sql, {key, actionId, jsonData})
    
    print('[KeybindService] Registered global keybind: ' .. key .. ' -> ' .. actionId)
    
    -- Sync to all connected clients
    TriggerClientEvent('obelisk:keybinds:requestSync', -1)
    
    return keybindId
end

--- Register a player-specific keybind
--- @param source number Player server ID
--- @param key string Key code
--- @param actionId string Action to trigger
--- @param data table Optional data
--- @return number keybindId
function KeybindService.registerPlayer(source, key, actionId, data)
    local identifier = GetPlayerIdentifier(source, 0)
    
    local sql = [[
        INSERT INTO keybinds (key_code, action_id, data, is_global, player_identifier)
        VALUES (?, ?, ?, 0, ?)
    ]]
    
    local jsonData = data and json.encode(data) or nil
    local keybindId = Database.insertSync(sql, {key, actionId, jsonData, identifier})
    
    print('[KeybindService] Registered player keybind for ' .. source .. ': ' .. key .. ' -> ' .. actionId)
    
    -- Sync to player
    KeybindService.syncToClient(source)
    
    return keybindId
end

--- Update a keybind
--- @param keybindId number
--- @param data table Fields to update
function KeybindService.update(keybindId, data)
    local setClauses = {}
    local values = {}
    
    for field, value in pairs(data) do
        if field == 'data' then
            value = json.encode(value)
        end
        table.insert(setClauses, field .. ' = ?')
        table.insert(values, value)
    end
    
    table.insert(values, keybindId)
    
    local sql = 'UPDATE keybinds SET ' .. table.concat(setClauses, ', ') .. ' WHERE id = ?'
    Database.updateSync(sql, values)
    
    -- Sync to all clients (global) or specific player
    TriggerClientEvent('obelisk:keybinds:requestSync', -1)
end

--- Delete a keybind
--- @param keybindId number
function KeybindService.delete(keybindId)
    local sql = 'DELETE FROM keybinds WHERE id = ?'
    Database.updateSync(sql, {keybindId})
    
    print('[KeybindService] Deleted keybind #' .. keybindId)
    
    -- Sync to all clients
    TriggerClientEvent('obelisk:keybinds:requestSync', -1)
end

--- Handle keybind press from client
--- Client sends the action ID to trigger
--- @param source number Player server ID
--- @param actionId string
--- @param keybindData table
function KeybindService.handlePress(source, actionId, keybindData)
    -- Verify action exists
    if not ActionService.exists(actionId) then
        print('[KeybindService] Error: Action not found: ' .. actionId)
        return
    end
    
    -- Execute the action
    ActionService.execute(source, actionId, keybindData)
end

--- Net event: Client requests keybind sync
RegisterNetEvent('obelisk:keybinds:requestSync')
AddEventHandler('obelisk:keybinds:requestSync', function()
    local source = source
    KeybindService.syncToClient(source)
end)

--- Net event: Client pressed a keybind
RegisterNetEvent('obelisk:keybinds:pressed')
AddEventHandler('obelisk:keybinds:pressed', function(actionId, keybindData)
    local source = source
    KeybindService.handlePress(source, actionId, keybindData)
end)

--- On player connect, sync keybinds
AddEventHandler('playerJoining', function()
    local source = source
    -- Delay slightly to ensure player is fully loaded
    SetTimeout(1000, function()
        KeybindService.syncToClient(source)
    end)
end)

return KeybindService
