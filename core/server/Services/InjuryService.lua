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

--- @param playerId number
--- @param zone string e.g. 'thorax', 'hand_r', 'lower_leg_l'
--- @param woundType string 'bullet'|'stab'|'blunt'|'burn'
--- @return number injury id
function InjuryService.addInjury(playerId, zone, woundType)
    local b = InjuryService.getBinding(playerId)
    local now = Database.now()
    local existing = QueryBuilder.new('player_injuries')
        :where('player_type', b.type)
        :where('player_id', b.id)
        :where('zone', zone)
        :whereNull('treated_at')
        :firstSync()
    local id
    if existing then
        QueryBuilder.new('player_injuries')
            :where('id', existing.id)
            :update({ hit_count = existing.hit_count + 1 })
        id = existing.id
    else
        id = QueryBuilder.new('player_injuries'):insert({
            player_type = b.type,
            player_id   = b.id,
            zone        = zone,
            hit_count   = 1,
            wound_type  = woundType,
            created_at  = now,
        })
    end
    TriggerEvent('oblsk:injury:injury_added', playerId, {
        id = id, zone = zone, wound_type = woundType,
    })
    return id
end

--- @param playerId number
--- @param injuryId number
function InjuryService.treatInjury(playerId, injuryId)
    QueryBuilder.new('player_injuries')
        :where('id', injuryId)
        :update({ treated_at = Database.now() })
    TriggerEvent('oblsk:injury:injury_treated', playerId, injuryId)
end

--- @param playerId number
--- @return table[] active (untreated) injury rows
function InjuryService.getInjuries(playerId)
    local b = InjuryService.getBinding(playerId)
    return QueryBuilder.new('player_injuries')
        :where('player_type', b.type)
        :where('player_id', b.id)
        :whereNull('treated_at')
        :getSync()
end
