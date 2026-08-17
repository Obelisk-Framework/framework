InjuryService = {}

local _listeners = {}

--- @param fn function(playerId, oldState, newState)
function InjuryService.onStateChange(fn)
    _listeners[#_listeners+1] = fn
end

--- Resolve player binding at runtime.
--- @param playerId number FiveM server ID
--- @return { type: string, id: integer }
function InjuryService.getBinding(playerId)
    if CharacterService then
        local char = CharacterService.getActiveCharacter(playerId)
        if char then return { type = 'character', id = char.id } end
    end
    local player = PlayerService.get(playerId)
    local accountId = player:getIdentifier('account')
    return { type = 'account', id = accountId }
end

--- @param playerId number
--- @return string state
function InjuryService.getState(playerId)
    local b = InjuryService.getBinding(playerId)
    local row = QueryBuilder.new('player_states')
        :where('player_type', b.type)
        :where('player_id', b.id)
        :firstSync()
    return row and row.state or 'healthy'
end

--- @param playerId number
--- @param newState string
function InjuryService.setState(playerId, newState)
    local b = InjuryService.getBinding(playerId)
    local now = Database.now()
    local existing = QueryBuilder.new('player_states')
        :where('player_type', b.type)
        :where('player_id', b.id)
        :firstSync()
    local oldState = existing and existing.state or 'healthy'
    if existing then
        QueryBuilder.new('player_states')
            :where('player_type', b.type)
            :where('player_id', b.id)
            :update({ state = newState, updated_at = now })
    else
        QueryBuilder.new('player_states'):insert({
            player_type = b.type,
            player_id   = b.id,
            state       = newState,
            state_since = now,
            updated_at  = now,
        })
    end
    TriggerEvent('oblsk:injury:state_changed', playerId, oldState, newState)
    for _, fn in ipairs(_listeners) do pcall(fn, playerId, oldState, newState) end
end
