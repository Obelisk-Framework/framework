--- UseInteraction Action - Triggers when player presses interaction key
--- This is the default action bound to the 'E' key

return function(data)
    -- This action is client-side triggered but handled on server
    -- The InteractionService.useClosest() is called from KeybindService
    
    -- Trigger the closest interaction
    if InteractionService and InteractionService.closestInteraction then
        TriggerServerEvent('obelisk:interaction:use', InteractionService.closestInteraction.id)
    else
        -- No interaction nearby
        print('[UseInteraction] No interaction in range')
    end
end
