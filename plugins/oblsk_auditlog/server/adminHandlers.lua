-- plugins/oblsk_auditlog/server/adminHandlers.lua
--- Audit log tab NUI handlers. Mirrors the isAdmin guard pattern used
--- elsewhere in this codebase (core/server/Policies/IsAdminPolicy.lua:
--- IsPlayerAceAllowed(player:getSource(), 'admin'), source 0 == console)
--- and the request/reply event-naming convention.
local function isAdmin(player)
    local source = player:getSource()
    return source == 0 or IsPlayerAceAllowed(source, 'admin')
end

local PAGE_SIZE = 50

--- @param filters table|nil { table_name, actor_type, actor_id, action, from, to }
--- @param page number 1-based
local function queryAuditLogs(filters, page)
    filters = filters or {}
    page = page or 1

    local query = AuditLog:newQuery()
    if filters.table_name then query = query:where('table_name', filters.table_name) end
    if filters.actor_type then query = query:where('actor_type', filters.actor_type) end
    if filters.actor_id then query = query:where('actor_id', filters.actor_id) end
    if filters.action then query = query:where('action', filters.action) end
    if filters.from then query = query:where('created_at', '>=', filters.from) end
    if filters.to then query = query:where('created_at', '<=', filters.to) end

    -- QueryBuilder:get() is async (callback-style); this handler needs a
    -- synchronous result to build its reply payload, so use :getSync() and
    -- hydrate the raw rows into model instances the same way
    -- BaseModel:all() does, so :toTable() (hidden-field stripping) is
    -- available below.
    local rows = query
        :orderBy('created_at', 'desc')
        :limit(PAGE_SIZE)
        :offset((page - 1) * PAGE_SIZE)
        :getSync()

    local result = {}
    for _, row in ipairs(rows) do
        table.insert(result, AuditLog:newFromQuery(row):toTable())
    end
    return result
end

Obelisk.onClient('admin:server:audit-log-query', function(player, data)
    if not isAdmin(player) then return end
    player:emit('admin:client:audit-log-query-reply', {
        rows = queryAuditLogs(data and data.filters, data and data.page),
        watchedTables = (function()
            local names = {}
            for modelName in pairs(AuditLogConfig.Watch) do
                table.insert(names, _G[modelName].table)
            end
            table.sort(names)
            return names
        end)(),
    })
end)
