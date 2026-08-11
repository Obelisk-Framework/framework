--- Entity Model - a streamable world entity (ped/object/pickup/marker/blip)
--- placed by an admin or a plugin. See
--- docs/superpowers/specs/2026-08-12-entity-streamer-design.md.
Entity = BaseModel:extend('entities')

Entity.primaryKey = 'id'
Entity.timestamps = true
Entity.fillable = {
    'entity_type', 'model', 'x', 'y', 'z', 'heading',
    'networked', 'enabled', 'owner_type', 'owner_id', 'data',
}
Entity.hidden = {}

--- `data` holds the type-specific fields (scenario/sprite/markerType/...) that
--- EntityStreamerService.register flattens onto the runtime entity record, so
--- it has to arrive as a table rather than a raw JSON string.
Entity.casts = { data = 'json' }

return Entity
