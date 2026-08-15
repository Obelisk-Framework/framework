--- Barber Plugin - Server Main
print('[Barber] Loading...')

-- source -> { chairId, x, y, z, range } for the currently-open barber
-- session. Required before either charge event is honored, so a client
-- can't fire barber:client:charge/applyFree without having actually
-- opened a chair's NUI first, and a distance check catches walking away
-- mid-browse. Cleared once the charge/applyFree event resolves (success
-- or failure) -- the player must re-open to buy again, matching how the
-- NUI naturally closes after a completed transaction.
local openSessions = {}

--- @param source number
--- @return boolean ok
local function validateSession(source)
    local session = openSessions[source]
    if not session then
        return false
    end
    local ped = GetPlayerPed(source)
    if ped == 0 then
        return false
    end
    local coords = GetEntityCoords(ped)
    local dx, dy, dz = coords.x - session.x, coords.y - session.y, coords.z - session.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    -- Generous margin over the interaction's own range: the player has
    -- already walked up to trigger the interaction and open the NUI, so
    -- this just catches "walked far away mid-browse", not exact
    -- positioning.
    return dist <= (session.range + 5.0)
end

local function openForSource(source, chairId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end

    local chair = QueryBuilder.new('barber_chairs'):where('id', chairId):firstSync()
    if not chair then return end
    local interaction = QueryBuilder.new('interactions'):where('id', chair.interaction_id):firstSync()
    if not interaction then return end

    openSessions[source] = {
        chairId = chairId,
        x = interaction.x,
        y = interaction.y,
        z = interaction.z,
        range = interaction.range or 2.0,
    }

    WebView.openPage(source, '/Barber')
    WebView.focus(source)
    Obelisk.emitClient('barber:server:sync', source, {
        chairId = chairId,
        sections = BarberConfig.Sections,
        hairPrice = BarberConfig.HairPrice,
        appearance = BarberService.getAppearance(source),
    })
end

ActionService.register('barber:open', function(source, data)
    local chairId = data and data.interaction and data.interaction.options and data.interaction.options.chairId
    if not chairId then return end
    openForSource(source, chairId)
end, { label = 'Sit in the chair' })

--- Registers every barber chair's interaction point.
--- Must be called exactly once, at boot — InteractionService.register does
--- NOT deduplicate, it allocates a fresh interaction id on every call.
local function registerAllChairs()
    local chairs = QueryBuilder.new('barber_chairs'):getSync()
    for _, chair in ipairs(chairs) do
        local interaction = QueryBuilder.new('interactions'):where('id', chair.interaction_id):firstSync()
        if interaction then
            InteractionService.register({
                x = interaction.x, y = interaction.y, z = interaction.z,
                range = interaction.range, label = interaction.label or chair.name,
                action = 'barber:open',
                options = { chairId = chair.id },
            })
        end
    end
end

local function notifyFailure(source, reason)
    NotificationService.notify(source, {
        type = 'error',
        title = 'Barber',
        description = reason or 'Could not complete the cut',
    })
end

--- @param touchedSectionIds string[]
--- @param method string 'cash'|'card'
--- @param cardId number|nil
--- @param gender string
--- @param appearanceChanges table
--- @param mult number|nil quality multiplier from the clipper minigame
Obelisk.onServer('barber:client:charge', function(touchedSectionIds, method, cardId, gender, appearanceChanges, mult)
    local source = source
    if not validateSession(source) then
        notifyFailure(source, 'Not at the barber chair')
        Obelisk.emitClient('barber:server:chargeResult', source, { ok = false })
        return
    end

    local ok, totalOrReason = BarberService.charge(source, touchedSectionIds, method, cardId, mult)
    if not ok then
        notifyFailure(source, totalOrReason)
        Obelisk.emitClient('barber:server:chargeResult', source, { ok = false })
        openSessions[source] = nil
        return
    end

    local validChanges, changeReason = BarberService.validateAppearanceChanges(appearanceChanges, touchedSectionIds)
    if not validChanges then
        notifyFailure(source, changeReason)
        Obelisk.emitClient('barber:server:chargeResult', source, { ok = false })
        openSessions[source] = nil
        return
    end

    local persisted, resolvedOrReason = BarberService.applyAndPersist(source, gender, appearanceChanges)
    if not persisted then
        notifyFailure(source, resolvedOrReason)
        Obelisk.emitClient('barber:server:chargeResult', source, { ok = false })
        openSessions[source] = nil
        return
    end

    openSessions[source] = nil
    Obelisk.emitClient('barber:server:chargeResult', source, { ok = true, total = totalOrReason, appearance = resolvedOrReason })
end)

--- Owned/no-charge cut: skips BarberService.charge, still persists.
--- No validateAppearanceChanges call here on purpose -- nothing is being
--- charged, so there is no under-payment to guard against. This path still
--- needs a real ownership model (it is currently client-asserted); that is
--- tracked separately and out of scope for this fix wave.
Obelisk.onServer('barber:client:applyFree', function(gender, appearanceChanges)
    local source = source
    if not validateSession(source) then
        notifyFailure(source, 'Not at the barber chair')
        Obelisk.emitClient('barber:server:chargeResult', source, { ok = false })
        return
    end

    local persisted, resolvedOrReason = BarberService.applyAndPersist(source, gender, appearanceChanges)
    if not persisted then
        notifyFailure(source, resolvedOrReason)
        Obelisk.emitClient('barber:server:chargeResult', source, { ok = false })
        openSessions[source] = nil
        return
    end
    openSessions[source] = nil
    Obelisk.emitClient('barber:server:chargeResult', source, { ok = true, total = 0, appearance = resolvedOrReason })
end)

--- Disconnect cleanup: drop any open barber session the leaving player
--- held, so a recycled source id can't inherit it.
AddEventHandler('playerDropped', function()
    local source = source
    openSessions[source] = nil
end)

Citizen.CreateThread(function()
    while not Database.isReady() do
        Citizen.Wait(200)
    end
    registerAllChairs()
    print('[Barber] Loaded successfully!')
end)
