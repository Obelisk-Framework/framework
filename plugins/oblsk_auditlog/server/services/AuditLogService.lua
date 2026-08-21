--- AuditLogService - registers BaseModel afterSave/afterDelete hooks for
--- every model listed in AuditLogConfig.Watch, diffs before/after
--- attributes per configured field, and persists one audit_logs row per
--- changed field.
AuditLogService = {}

--- Player source attributed to writes made during the current
--- `withActor` scope, or nil (writes attribute to actor_type='system').
--- Single value, not a stack -- nested withActor calls save/restore the
--- previous value around their own scope, so this is reentrant.
AuditLogService.currentActor = nil

local function fieldsFor(modelName, watch, model)
    if watch.fields == '*' then
        return model.fillable
    end
    return watch.fields
end

local function resolveActor()
    if AuditLogService.currentActor ~= nil then
        return 'player', AuditLogService.currentActor
    end
    return 'system', nil
end

local function stringify(value)
    if value == nil then
        return nil
    end
    if type(value) == 'table' then
        return json.encode(value)
    end
    return tostring(value)
end

local function writeRow(tableName, rowId, action, field, oldValue, newValue)
    local actorType, actorId = resolveActor()
    AuditLog:create({
        table_name = tableName,
        row_id = rowId,
        action = action,
        actor_type = actorType,
        actor_id = actorId,
        field = field,
        old_value = stringify(oldValue),
        new_value = stringify(newValue),
        created_at = Database.now(),
    })
end

local function makeSaveHandler(modelName, watch, model)
    return function(instance, ctx)
        local fields = fieldsFor(modelName, watch, model)
        local rowId = instance.attributes[instance.primaryKey]

        if ctx.action == 'insert' then
            for _, field in ipairs(fields) do
                local value = ctx.after[field]
                if value ~= nil then
                    writeRow(instance.table, rowId, 'insert', field, nil, value)
                end
            end
        else
            for _, field in ipairs(fields) do
                local before, after = ctx.before[field], ctx.after[field]
                if before ~= after then
                    writeRow(instance.table, rowId, 'update', field, before, after)
                end
            end
        end
    end
end

local function makeDeleteHandler(modelName, watch, model)
    return function(instance, ctx)
        local fields = fieldsFor(modelName, watch, model)
        local rowId = instance.attributes[instance.primaryKey]

        for _, field in ipairs(fields) do
            local value = ctx.before[field]
            if value ~= nil then
                writeRow(instance.table, rowId, 'delete', field, value, nil)
            end
        end
    end
end

--- Register hooks for every model in AuditLogConfig.Watch. Call once at
--- boot, after all models (and this plugin's config) have loaded.
function AuditLogService.init()
    for modelName, watch in pairs(AuditLogConfig.Watch) do
        local model = _G[modelName]
        assert(model, ("AuditLogConfig.Watch references unknown model %q"):format(modelName))
        model.hooks:afterSave(makeSaveHandler(modelName, watch, model))
        model.hooks:afterDelete(makeDeleteHandler(modelName, watch, model))
    end
end

--- Run `fn()` with audit rows written during it attributed to
--- `actor_type='player', actor_id=source`. Restores the previous actor
--- (nil, or an outer withActor's source) once fn() returns or errors.
--- @param source number player source
--- @param fn function
function AuditLogService.withActor(source, fn)
    local previous = AuditLogService.currentActor
    AuditLogService.currentActor = source
    local ok, err = pcall(fn)
    AuditLogService.currentActor = previous
    if not ok then
        error(err, 0)
    end
end

return AuditLogService
