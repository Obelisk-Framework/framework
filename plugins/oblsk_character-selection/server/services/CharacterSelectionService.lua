-- plugins/oblsk_character-selection/server/services/CharacterSelectionService.lua
--- CharacterSelectionService (plugin) - thin list/create/delete/select
--- wrapper over oblsk_characters' CharacterService, adding appearance
--- persistence (CharacterService.create doesn't accept an appearance blob;
--- this defaults or stores one via CharacterAppearance directly) and
--- joining appearance data onto listed characters for the roster UI. See
--- docs/superpowers/specs/2026-08-13-character-selection-plugin-design.md.
CharacterSelectionService = {}

--- Every character_appearances read/write goes through the CharacterAppearance
--- MODEL rather than a raw QueryBuilder, because `data` is declared as a
--- `json` cast on that model (see modules/oblsk_characters/server/models/
--- CharacterAppearance.lua) and the encode/decode only happens on
--- BaseModel's newFromQuery/save path. A raw QueryBuilder read hands back the
--- undecoded JSON string, and a raw write tries to bind a Lua table.
--- @param characterId number
--- @return CharacterAppearance|nil model instance with `data` decoded to a table
local function findAppearance(characterId)
    local row = CharacterAppearance:where('character_id', characterId):firstSync()
    if not row then
        return nil
    end
    return CharacterAppearance:newFromQuery(row)
end

--- @param accountId number
--- @return table[] each { character = <attrs table>, appearance = <data table> }
function CharacterSelectionService.listWithAppearance(accountId)
    local characters = CharacterService.list(accountId)
    local result = {}
    for _, character in ipairs(characters) do
        local appearance = findAppearance(character.id)
        result[#result + 1] = {
            character = character,
            appearance = appearance and appearance.attributes.data or nil,
        }
    end
    return result
end

--- @param accountId number
--- @param attributes table { first_name, last_name, gender, dob, bio, appearance? }
--- @return Character|nil
--- @return string|nil err
function CharacterSelectionService.createCharacter(accountId, attributes)
    local gender = attributes.gender == 'female' and 'female' or 'male'

    -- The Vue layer doesn't know GTA model names, so the ped model is derived
    -- from the chosen gender here rather than being required in the payload.
    if not attributes.ped_model then
        attributes.ped_model = gender == 'female' and 'mp_f_freemode_01' or 'mp_m_freemode_01'
    end

    local character, err = CharacterService.create(accountId, attributes)
    if not character then
        return nil, err
    end

    -- The creator submits PRESET INDICES (skin/eye/hair swatch positions,
    -- wardrobe option positions), never native IDs — resolve them here so the
    -- persisted blob is fully native-valued and can be applied to a ped as-is.
    local appearance = Appearance.resolvePresetAppearance(gender, attributes.appearance)

    -- CharacterService.create already inserted a blank CharacterAppearance
    -- row (data = {}) for this character, so this is always an update onto
    -- an existing row, never an insert.
    local appearanceModel = findAppearance(character.attributes.id)
    if appearanceModel then
        appearanceModel.attributes.data = appearance
        appearanceModel:saveSync()
    end

    return character
end

--- @param characterId number
function CharacterSelectionService.deleteCharacter(characterId)
    return CharacterService.delete(characterId)
end

--- @param source number
--- @param characterId number
--- @return table { vitals, appearance }
function CharacterSelectionService.selectCharacter(source, characterId)
    CharacterService.setActiveCharacterId(source, characterId)

    local appearance = findAppearance(characterId)

    return {
        vitals = CharacterService.getVitals(characterId),
        appearance = appearance and appearance.attributes.data or nil,
    }
end

--- Which account owns a character, for authorization checks on the
--- client-supplied character ids in server/main.lua.
--- @param characterId number
--- @return number|nil account_id, nil when the character doesn't exist
function CharacterSelectionService.getOwningAccountId(characterId)
    if characterId == nil then
        return nil
    end
    local character = Character:findSync(characterId)
    return character and character.attributes.account_id or nil
end

return CharacterSelectionService
