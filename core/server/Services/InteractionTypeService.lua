--- InteractionTypeService - registry of plugin-declared interaction TYPES
--- (gas station, mechanic bay, ...), so oblsk_admin's Interactions tab can
--- render a generic CRUD sub-tab for each registered type instead of every
--- interaction-owning plugin needing bespoke admin-side handlers and Vue
--- markup. Purely a descriptor registry -- it does not itself place blips/
--- peds/markers or touch the database; that's each type's own `list`/
--- `create`/`update`/`delete` hooks (see plugins/oblsk_gasstation and
--- plugins/oblsk_mechanic's server/main.lua for real registrations).
InteractionTypeService = {}
InteractionTypeService.registry = {} -- typeKey -> descriptor

--- Register a new interaction type. Registering the same typeKey twice
--- overwrites the previous descriptor (with a warning) -- same convention as
--- ActionService.register for a duplicate actionId.
--- @param descriptor table {
---   typeKey: string,   -- e.g. 'gasstation', 'mechanic'
---   label: string,     -- e.g. 'Gas Station'
---   fields: table[],   -- [{key, label, type: 'text'|'number'|'select'|'organization'|'boolean', options?: table[], required?: boolean}]
---                       -- flat extra data beyond the base interaction's x/y/z/range/label. type='organization'
---                       -- means the admin UI should populate it from the existing organisations list, not a
---                       -- literal `options` array. type='select' uses the literal `options` array as [{value,label}].
---   blipRequirement: 'required'|'optional'|'none',  -- purely descriptive metadata for the admin UI (no blip
---                                                     -- spawning system exists yet, this doesn't build one)
---   pedRequirement: 'required'|'optional'|'none',
---   markerRequirement: 'required'|'optional'|'none',
---   list: function() -> table[],                -- e.g. GasStationService.listStationsForAdmin
---   create: function(data) -> table,             -- data = base fields + declared extra fields merged
---   update: function(id, data) -> boolean,
---   delete: function(id) -> boolean,
--- }
function InteractionTypeService.register(descriptor)
    if InteractionTypeService.registry[descriptor.typeKey] then
        print('[InteractionTypeService] Warning: Overwriting existing interaction type: ' .. descriptor.typeKey)
    end

    InteractionTypeService.registry[descriptor.typeKey] = descriptor
    print('[InteractionTypeService] Registered interaction type: ' .. descriptor.typeKey)
end

--- @param typeKey string
--- @return table|nil the full descriptor including its function hooks (server-side use only)
function InteractionTypeService.get(typeKey)
    return InteractionTypeService.registry[typeKey]
end

--- @return table[] every registered type's metadata WITHOUT the function hooks (list/create/update/delete
---   aren't meaningful to serialize to the client) - what the admin NUI actually receives.
function InteractionTypeService.listForAdmin()
    local out = {}
    for _, descriptor in pairs(InteractionTypeService.registry) do
        table.insert(out, {
            typeKey = descriptor.typeKey,
            label = descriptor.label,
            fields = descriptor.fields,
            blipRequirement = descriptor.blipRequirement,
            pedRequirement = descriptor.pedRequirement,
            markerRequirement = descriptor.markerRequirement,
        })
    end
    return out
end

return InteractionTypeService
