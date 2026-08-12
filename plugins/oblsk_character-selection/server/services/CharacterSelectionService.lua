-- plugins/oblsk_character-selection/server/services/CharacterSelectionService.lua
--- CharacterSelectionService (plugin) - thin list/create/delete/select
--- wrapper over oblsk_characters' CharacterService, adding appearance
--- persistence (CharacterService.create doesn't accept an appearance blob;
--- this defaults or stores one via CharacterAppearance directly) and
--- joining appearance data onto listed characters for the roster UI. See
--- docs/superpowers/specs/2026-08-13-character-selection-plugin-design.md.
CharacterSelectionService = {}

--- @param accountId number
--- @return table[] each { character = <attrs table>, appearance = <data table> }
function CharacterSelectionService.listWithAppearance(accountId)
    local characters = CharacterService.list(accountId)
    local result = {}
    for _, character in ipairs(characters) do
        local appearanceRow = QueryBuilder.new('character_appearances')
            :where('character_id', character.id)
            :firstSync()
        result[#result + 1] = {
            character = character,
            appearance = appearanceRow and appearanceRow.data or nil,
        }
    end
    return result
end

--- @param accountId number
--- @param attributes table { first_name, last_name, gender, dob, bio, appearance? }
--- @return Character|nil
--- @return string|nil err
function CharacterSelectionService.createCharacter(accountId, attributes)
    local character, err = CharacterService.create(accountId, attributes)
    if not character then
        return nil, err
    end

    -- CharacterService.create already inserted a blank CharacterAppearance
    -- row (data = {}) for this character, so this is always an update onto
    -- an existing row, never an insert.
    local appearance = attributes.appearance or Appearance.DEFAULT_APPEARANCE(attributes.gender or 'male')
    QueryBuilder.new('character_appearances')
        :where('character_id', character.attributes.id)
        :update({ data = appearance })

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

    local appearanceRow = QueryBuilder.new('character_appearances')
        :where('character_id', characterId)
        :firstSync()

    return {
        vitals = CharacterService.getVitals(characterId),
        appearance = appearanceRow and appearanceRow.data or nil,
    }
end

return CharacterSelectionService
