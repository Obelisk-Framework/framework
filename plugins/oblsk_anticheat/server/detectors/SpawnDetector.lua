--- Pure ghost-item/weapon check: server is the source of truth for what a
--- player was granted (per the item bindings system — see
--- docs/superpowers/specs/2026-08-20-anticheat-design.md, "Weapon/item
--- spawning"). Anything the client reports holding that the server never
--- granted is flagged. The wiring task owns fetching
--- serverGrantedWeaponHashes from InventoryService.
SpawnDetector = SpawnDetector or {}

--- @param clientReportedWeaponHashes table array of weapon hashes the client says the ped currently has
--- @param serverGrantedWeaponHashes table array of weapon hashes InventoryService actually granted this character
--- @return table|nil {category='spawn', detail=string, severity='hard'} or nil
function SpawnDetector.check(clientReportedWeaponHashes, serverGrantedWeaponHashes)
    local granted = {}
    for _, hash in ipairs(serverGrantedWeaponHashes) do
        granted[hash] = true
    end

    for _, hash in ipairs(clientReportedWeaponHashes) do
        if not granted[hash] then
            return {
                category = 'spawn',
                detail = 'ungranted weapon hash ' .. tostring(hash),
                severity = 'hard',
            }
        end
    end

    return nil
end

return SpawnDetector
