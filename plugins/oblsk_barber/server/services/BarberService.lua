--- BarberService - pricing, charge, and appearance-persistence logic for
--- oblsk_barber. Split from server/main.lua so it's testable headless, same
--- convention as ShopService/TerminalService.
BarberService = {}

--- @param sectionId string
--- @return number|nil price, nil if sectionId is neither 'hair' nor a Config.Sections entry
function BarberService.priceFor(sectionId)
    if sectionId == 'hair' then
        return Config.HairPrice
    end
    for _, section in ipairs(Config.Sections) do
        if section.id == sectionId then
            return section.price
        end
    end
    return nil
end

--- @param touchedSectionIds string[]
--- @return number total, unknown ids contribute 0
function BarberService.total(touchedSectionIds)
    local total = 0
    for _, id in ipairs(touchedSectionIds) do
        total = total + (BarberService.priceFor(id) or 0)
    end
    return total
end

--- @param source number
--- @param touchedSectionIds string[]
--- @param method string 'cash'|'card'
--- @param cardId number|nil required when method == 'card'
--- @return boolean ok
--- @return number|string totalOrReason total charged on success, reason string on failure
function BarberService.charge(source, touchedSectionIds, method, cardId)
    local total = BarberService.total(touchedSectionIds)
    if total <= 0 then
        return false, 'Nothing to charge'
    end

    if method == 'cash' then
        local cash = ItemService.binding('currency.cash')
        if not cash then
            return false, 'Cash purchases are not available on this server'
        end
        local cashAmount = math.floor(total + 0.5)
        if not ItemService.has(source, cash, cashAmount) then
            return false, 'Not enough cash'
        end
        local removed, removeReason = ItemService.remove(source, cash, cashAmount)
        if not removed then
            return false, removeReason
        end
    elseif method == 'card' then
        local charged, chargeReason = BankingService.charge(source, cardId, total, 'Barber shop')
        if not charged then
            return false, chargeReason
        end
    else
        return false, 'Unknown payment method'
    end

    return true, total
end

--- Merges the given appearance keys into the active character's
--- character_appearances.data row and returns the fully resolved appearance
--- so the caller can also apply it to the live ped.
--- @param source number
--- @param gender string 'male' | 'female'
--- @param appearanceChanges table partial appearance keys to merge, e.g.
---   { hairStyle = 4, hairColor = 2, hairHighlight = 2 }
--- @return boolean ok
--- @return table|string resolvedAppearanceOrReason
function BarberService.applyAndPersist(source, gender, appearanceChanges)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return false, 'No active character'
    end

    local row = CharacterAppearance:where('character_id', characterId):firstSync()
    if not row then
        return false, 'No appearance row for this character'
    end
    local appearanceModel = CharacterAppearance:newFromQuery(row)

    local data = appearanceModel.attributes.data or {}
    for key, value in pairs(appearanceChanges) do
        data[key] = value
    end
    appearanceModel.attributes.data = data
    appearanceModel:saveSync()

    return true, data
end

--- Read-only: the active character's current fully-resolved appearance, for
--- sending to the client as a live-preview base (see server/main.lua's
--- openForSource). Always a complete Appearance.DEFAULT_APPEARANCE-shaped
--- table, never sparse -- CharacterSelectionService.createCharacter always
--- initializes this row from Appearance.DEFAULT_APPEARANCE.
--- @param source number
--- @return table|nil appearance data, nil if no active character or no row
function BarberService.getAppearance(source)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return nil
    end
    local row = CharacterAppearance:where('character_id', characterId):firstSync()
    if not row then
        return nil
    end
    local appearanceModel = CharacterAppearance:newFromQuery(row)
    return appearanceModel.attributes.data
end

return BarberService
