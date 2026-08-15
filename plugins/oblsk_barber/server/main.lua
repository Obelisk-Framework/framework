--- Barber Plugin - Server Main
print('[Barber] Loading...')

local function openForSource(source, chairId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end

    WebView.openPage(source, '/Barber')
    WebView.focus(source)
    Obelisk.emitClient('barber:server:sync', source, {
        chairId = chairId,
        sections = Config.Sections,
        hairPrice = Config.HairPrice,
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
Obelisk.onServer('barber:client:charge', function(touchedSectionIds, method, cardId, gender, appearanceChanges)
    local source = source
    local ok, totalOrReason = BarberService.charge(source, touchedSectionIds, method, cardId)
    if not ok then
        notifyFailure(source, totalOrReason)
        Obelisk.emitClient('barber:server:chargeResult', source, { ok = false })
        return
    end

    local persisted, resolvedOrReason = BarberService.applyAndPersist(source, gender, appearanceChanges)
    if not persisted then
        notifyFailure(source, resolvedOrReason)
        Obelisk.emitClient('barber:server:chargeResult', source, { ok = false })
        return
    end

    Obelisk.emitClient('barber:server:chargeResult', source, { ok = true, total = totalOrReason, appearance = resolvedOrReason })
end)

--- Owned/no-charge cut: skips BarberService.charge, still persists.
Obelisk.onServer('barber:client:applyFree', function(gender, appearanceChanges)
    local source = source
    local persisted, resolvedOrReason = BarberService.applyAndPersist(source, gender, appearanceChanges)
    if not persisted then
        notifyFailure(source, resolvedOrReason)
        Obelisk.emitClient('barber:server:chargeResult', source, { ok = false })
        return
    end
    Obelisk.emitClient('barber:server:chargeResult', source, { ok = true, total = 0, appearance = resolvedOrReason })
end)

Citizen.CreateThread(function()
    while not Database.isReady() do
        Citizen.Wait(200)
    end
    registerAllChairs()
    print('[Barber] Loaded successfully!')
end)
