AnimationService = {}

local _registry = {}

-- Register a named animation any plugin can play by id.
-- config: { dict, anim, blendIn?, blendOut?, duration?, flags? }
-- duration = -1 means looping; positive = one-shot ms.
function AnimationService.register(id, config)
    _registry[id] = {
        dict     = config.dict,
        anim     = config.anim,
        blendIn  = config.blendIn  or 4.0,
        blendOut = config.blendOut or 4.0,
        duration = config.duration or -1,
        flags    = config.flags    or 0,
    }
end

local function loadDict(dict)
    RequestAnimDict(dict)
    local waited = 0
    while not HasAnimDictLoaded(dict) do
        Wait(10)
        waited = waited + 10
        if waited > 5000 then return false end
    end
    return true
end

-- Play a registered animation on the local ped.
-- Looping anims (duration=-1) are skipped if already playing.
function AnimationService.play(id)
    local cfg = _registry[id]
    if not cfg then return end
    CreateThread(function()
        local ped = PlayerPedId()
        if not ped or ped == 0 then return end
        if not loadDict(cfg.dict) then return end
        if cfg.duration == -1 and IsEntityPlayingAnim(ped, cfg.dict, cfg.anim, 3) then return end
        TaskPlayAnim(ped, cfg.dict, cfg.anim, cfg.blendIn, cfg.blendOut, cfg.duration, cfg.flags, 0, false, false, false)
    end)
end

-- Stop a looping animation started via play().
function AnimationService.stop(id)
    local cfg = _registry[id]
    if not cfg then return end
    local ped = PlayerPedId()
    if not ped or ped == 0 then return end
    StopAnimTask(ped, cfg.dict, cfg.anim, 4.0)
end
