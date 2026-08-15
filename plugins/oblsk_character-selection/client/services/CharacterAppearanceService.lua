--- Client CharacterAppearanceService - applies a Task 4-shaped appearance
--- table to any ped via GTA natives. Used for both the select/creator
--- preview ped and, on confirm, the real player ped. No automated test
--- (native calls aren't stubbed headless) -- verify manually per the plan's
--- end-to-end checklist.
CharacterAppearanceService = {}

--- @param ped number ped handle
--- @param appearance table shaped per Appearance.DEFAULT_APPEARANCE
--- @param gender string 'male' | 'female'
function CharacterAppearanceService.apply(ped, appearance, gender)
    local hb = appearance.headBlend
    SetPedHeadBlendData(ped,
        hb.shapeFirst, hb.shapeSecond, hb.shapeThird,
        hb.skinFirst, hb.skinSecond, hb.skinThird,
        hb.shapeMix, hb.skinMix, hb.thirdMix,
        false)

    for featureIndex, value in pairs(appearance.faceFeatures) do
        SetPedFaceFeature(ped, featureIndex, value)
    end

    SetPedComponentVariation(ped, 2, appearance.hairStyle, 0, 0)
    SetPedHairColor(ped, appearance.hairColor, appearance.hairHighlight)
    SetPedEyeColor(ped, appearance.eyeColor)

    for componentId, variation in pairs(appearance.components) do
        SetPedComponentVariation(ped, componentId, variation.drawable, variation.texture or 0, 0)
    end

    for propId, variation in pairs(appearance.props) do
        if variation.drawable == -1 then
            ClearPedProp(ped, propId)
        else
            SetPedPropIndex(ped, propId, variation.drawable, variation.texture or 0, true)
        end
    end

    for _, overlay in pairs(appearance.overlays or {}) do
        SetPedHeadOverlay(ped, overlay.overlayId, overlay.styleIndex, overlay.opacity or 1.0)
        if overlay.colorId ~= nil then
            SetPedHeadOverlayColor(ped, overlay.overlayId, overlay.colorType or 1, overlay.colorId, overlay.colorId)
        end
    end
end

--- Convenience: apply one wardrobe slot's chosen option (from
--- Appearance.WARDROBE[gender][slotKey][optionIndex]) directly to a ped,
--- for live preview as the creator's Wardrobe step changes selection.
--- @param ped number
--- @param gender string
--- @param slotKey string e.g. 'top', 'jacket'
--- @param optionIndex number 1-based index into Appearance.WARDROBE[gender][slotKey]
function CharacterAppearanceService.applyWardrobeSlot(ped, gender, slotKey, optionIndex)
    local slots = Appearance.WARDROBE[gender] and Appearance.WARDROBE[gender][slotKey]
    local option = slots and slots[optionIndex]
    if not option then
        return
    end
    if option.drawable == -1 then
        ClearPedProp(ped, option.component)
    elseif slotKey == 'hat' then
        SetPedPropIndex(ped, option.component, option.drawable, option.texture, true)
    else
        SetPedComponentVariation(ped, option.component, option.drawable, option.texture, 0)
    end
end

return CharacterAppearanceService
