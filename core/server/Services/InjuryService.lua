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
    if not PlayerService then return { type = 'account', id = 0 } end
    local player = PlayerService.get(playerId)
    local accountId = player:getIdentifier('account')
    return { type = 'account', id = accountId }
end

--- @param playerId number
--- @return string state
function InjuryService.getState(playerId)
    local b = InjuryService.getBinding(playerId)
    local row = PlayerState:where('player_type', b.type)
        :where('player_id', b.id)
        :first()
    return row and row.state or 'healthy'
end

--- @param playerId number
--- @param newState string
function InjuryService.setState(playerId, newState)
    local b = InjuryService.getBinding(playerId)
    local now = Database.now()
    local existing = PlayerState:where('player_type', b.type)
        :where('player_id', b.id)
        :first()
    local oldState = existing and existing.state or 'healthy'
    if oldState == newState then return end
    if existing then
        PlayerState:where('player_type', b.type)
            :where('player_id', b.id)
            :update({ state = newState, updated_at = now })
    else
        PlayerState:newQuery():insert({
            player_type = b.type,
            player_id   = b.id,
            state       = newState,
            state_since = now,
            updated_at  = now,
        })
    end
    Obelisk.emit('oblsk:injury:state_changed', playerId, oldState, newState)
    for _, fn in ipairs(_listeners) do pcall(fn, playerId, oldState, newState) end
end

--- @param playerId number
--- @param zone string e.g. 'thorax', 'hand_r', 'lower_leg_l'
--- @param woundType string 'bullet'|'stab'|'blunt'|'burn'
--- @return number injury id
function InjuryService.addInjury(playerId, zone, woundType)
    local b = InjuryService.getBinding(playerId)
    local now = Database.now()
    local existing = PlayerInjury:where('player_type', b.type)
        :where('player_id', b.id)
        :where('zone', zone)
        :whereNull('treated_at')
        :first()
    local id
    if existing then
        -- original wound_type persists; subsequent hits increment hit_count only
        PlayerInjury:where('id', existing.id)
            :update({ hit_count = existing.hit_count + 1 })
        id = existing.id
    else
        id = PlayerInjury:newQuery():insert({
            player_type = b.type,
            player_id   = b.id,
            zone        = zone,
            hit_count   = 1,
            wound_type  = woundType,
            created_at  = now,
        })
    end
    Obelisk.emit('oblsk:injury:injury_added', playerId, {
        id = id, zone = zone, wound_type = woundType,
    })
    return id
end

--- @param playerId number
--- @param injuryId number
function InjuryService.treatInjury(playerId, injuryId)
    PlayerInjury:where('id', injuryId)
        :update({ treated_at = Database.now() })
    Obelisk.emit('oblsk:injury:injury_treated', playerId, injuryId)
end

--- @param playerId number
--- @return table[] active (untreated) injury rows
function InjuryService.getInjuries(playerId)
    local b = InjuryService.getBinding(playerId)
    return PlayerInjury:where('player_type', b.type)
        :where('player_id', b.id)
        :whereNull('treated_at')
        :get()
end

--- @param playerId number
--- @param illnessType string
--- @return number illness id
function InjuryService.addIllness(playerId, illnessType)
    local b = InjuryService.getBinding(playerId)
    local id = PlayerIllness:newQuery():insert({
        player_type          = b.type,
        player_id            = b.id,
        illness_type         = illnessType,
        stage                = 'incubating',
        exposure_accumulated = 0,
        onset_at             = Database.now(),
    })
    Obelisk.emit('oblsk:injury:illness_progressed', playerId,
        { id=id, illness_type=illnessType, stage='incubating' })
    return id
end

--- @param playerId number
--- @param illnessId number
--- @param stage string 'incubating'|'active'|'severe'|'lethal'
function InjuryService.progressIllness(playerId, illnessId, stage)
    PlayerIllness:where('id', illnessId):update({ stage = stage })
    local illness = PlayerIllness:where('id', illnessId):first()
    Obelisk.emit('oblsk:injury:illness_progressed', playerId, illness)
end

--- @param playerId number
--- @param illnessId number
function InjuryService.treatIllness(playerId, illnessId)
    PlayerIllness:where('id', illnessId)
        :update({ treated_at = Database.now() })
    Obelisk.emit('oblsk:injury:illness_treated', playerId, illnessId)
end

--- @param playerId number
--- @return table[] active (untreated) illness rows
function InjuryService.getIllnesses(playerId)
    local b = InjuryService.getBinding(playerId)
    return PlayerIllness:where('player_type', b.type)
        :where('player_id', b.id)
        :whereNull('treated_at')
        :get()
end

local _bleedTimers = {}
local _vitals = {}

--- Start bleed-out countdown. Fires bleed_out_available after `seconds`.
--- @param playerId number
--- @param seconds number
function InjuryService.startBleedTimer(playerId, seconds)
    InjuryService.cancelBleedTimer(playerId)
    _bleedTimers[playerId] = true
    CreateThread(function()
        Wait(seconds * 1000)
        if _bleedTimers[playerId] then
            _bleedTimers[playerId] = nil
            Obelisk.emit('oblsk:injury:bleed_out_available', playerId)
        end
    end)
end

--- @param playerId number
function InjuryService.cancelBleedTimer(playerId)
    _bleedTimers[playerId] = nil
end

--- @param playerId number
--- @param key string e.g. 'temperature', 'pulse', 'spo2'
--- @param value any
function InjuryService.setVital(playerId, key, value)
    if not _vitals[playerId] then _vitals[playerId] = {} end
    _vitals[playerId][key] = value
end

--- @param playerId number
--- @return table vitals map
function InjuryService.getVitals(playerId)
    return _vitals[playerId] or {}
end

--- Admin heal: clears all injuries, illnesses, sets state to healthy.
--- @param playerId number
function InjuryService.healAll(playerId)
    local b = InjuryService.getBinding(playerId)
    local now = Database.now()
    PlayerInjury:where('player_type', b.type)
        :where('player_id', b.id)
        :whereNull('treated_at')
        :update({ treated_at = now })
    PlayerIllness:where('player_type', b.type)
        :where('player_id', b.id)
        :whereNull('treated_at')
        :update({ treated_at = now })
    InjuryService.cancelBleedTimer(playerId)
    _vitals[playerId] = {}
    InjuryService.setState(playerId, 'healthy')
end
