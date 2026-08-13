-- plugins/oblsk_character-selection/client/services/CharacterCameraService.lua
--- Client CharacterCameraService - a single scripted camera framed on the
--- preview ped, used by both the select screen (head/torso/full framing)
--- and the creator screen (4 fixed rotation angles). No automated test
--- (camera natives aren't stubbed headless) -- verify manually.
CharacterCameraService = {}
CharacterCameraService.cam = nil
CharacterCameraService.pedCoords = nil

local FRAMINGS = {
    head  = { zOffset = 0.62, distance = 0.9,  fov = 30.0 },
    torso = { zOffset = 0.35, distance = 1.8,  fov = 40.0 },
    full  = { zOffset = -0.1, distance = 3.2,  fov = 45.0 },
}

--- Front/3-4/Side/Back, degrees offset from the ped's own heading.
local ANGLES = { 0.0, 45.0, 90.0, 180.0 }

--- @param pedCoords vector4 { x, y, z, heading } — the preview ped's spawn coords
function CharacterCameraService.start(pedCoords)
    CharacterCameraService.pedCoords = pedCoords
    CharacterCameraService.cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    CharacterCameraService.setFraming('full')
    SetCamActive(CharacterCameraService.cam, true)
    RenderScriptCams(true, false, 0, true, true)
end

function CharacterCameraService.stop()
    if CharacterCameraService.cam then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(CharacterCameraService.cam, false)
        CharacterCameraService.cam = nil
    end
end

local function place(zOffset, distance, angleDegrees, fov)
    local coords = CharacterCameraService.pedCoords
    local headingRad = math.rad(coords.heading + 180.0 + angleDegrees)
    local camX = coords.x + math.sin(headingRad) * distance
    local camY = coords.y - math.cos(headingRad) * distance
    local camZ = coords.z + 0.62 + zOffset

    SetCamCoord(CharacterCameraService.cam, camX, camY, camZ)
    PointCamAtCoord(CharacterCameraService.cam, coords.x, coords.y, coords.z + 0.62 + zOffset)
    SetCamFov(CharacterCameraService.cam, fov)
end

--- @param framing string 'head' | 'torso' | 'full'
function CharacterCameraService.setFraming(framing)
    if not CharacterCameraService.cam then return end
    local f = FRAMINGS[framing] or FRAMINGS.full
    place(f.zOffset, f.distance, 0.0, f.fov)
end

--- @param angleIndex number 0-3, indexes ANGLES (Front/3-4/Side/Back)
function CharacterCameraService.setAngle(angleIndex)
    if not CharacterCameraService.cam then return end
    local angle = ANGLES[angleIndex + 1] or ANGLES[1]
    place(FRAMINGS.full.zOffset, FRAMINGS.full.distance, angle, FRAMINGS.full.fov)
end

return CharacterCameraService
