--- A fake QueryBuilder.new that operates on in-memory Lua tables instead of
--- real SQL. See core/tests/permission_service_spec.lua for how this is
--- swapped in for the real global QueryBuilder around each test.
local FakeQueryBuilder = {}
FakeQueryBuilder.__index = FakeQueryBuilder

local function rowMatches(row, wheres, whereNulls)
    for _, w in ipairs(wheres) do
        if row[w.column] ~= w.value then return false end
    end
    for _, col in ipairs(whereNulls) do
        if row[col] ~= nil then return false end
    end
    return true
end

function FakeQueryBuilder:where(column, a, b)
    local value = b ~= nil and b or a
    table.insert(self.wheres, { column = column, value = value })
    return self
end

function FakeQueryBuilder:whereNull(column)
    table.insert(self.whereNulls, column)
    return self
end

function FakeQueryBuilder:orderBy(column, direction)
    self.orderByColumn = column
    self.orderByDirection = direction or 'asc'
    return self
end

function FakeQueryBuilder:limit(n)
    self.limitCount = n
    return self
end

function FakeQueryBuilder:firstSync()
    for _, row in ipairs(self.rows) do
        if rowMatches(row, self.wheres, self.whereNulls) then
            return row
        end
    end
    return nil
end

function FakeQueryBuilder:getSync()
    local results = {}
    for _, row in ipairs(self.rows) do
        if rowMatches(row, self.wheres, self.whereNulls) then
            table.insert(results, row)
        end
    end

    if self.orderByColumn then
        local column, descending = self.orderByColumn, self.orderByDirection == 'desc'
        table.sort(results, function(a, b)
            if a[column] == b[column] then
                if descending then return a.id > b.id end
                return a.id < b.id
            end
            if descending then return a[column] > b[column] end
            return a[column] < b[column]
        end)
    end

    if self.limitCount and #results > self.limitCount then
        local limited = {}
        for i = 1, self.limitCount do
            limited[i] = results[i]
        end
        results = limited
    end

    return results
end

function FakeQueryBuilder:insert(data)
    self.nextIds[self.tableName] = (self.nextIds[self.tableName] or 0) + 1
    local id = self.nextIds[self.tableName]
    local row = { id = id }
    for k, v in pairs(data) do row[k] = v end
    table.insert(self.rows, row)
    return id
end

function FakeQueryBuilder:update(data)
    local affected = 0
    for _, row in ipairs(self.rows) do
        if rowMatches(row, self.wheres, self.whereNulls) then
            for k, v in pairs(data) do
                if v == Database.NULL then row[k] = nil else row[k] = v end
            end
            affected = affected + 1
        end
    end
    return affected
end

function FakeQueryBuilder:delete()
    local kept, removed = {}, 0
    for _, row in ipairs(self.rows) do
        if rowMatches(row, self.wheres, self.whereNulls) then
            removed = removed + 1
        else
            table.insert(kept, row)
        end
    end
    for i = #self.rows, 1, -1 do
        table.remove(self.rows, i)
    end
    for _, row in ipairs(kept) do
        table.insert(self.rows, row)
    end
    return removed
end

--- @param tables table tableName -> array of row tables (shared, mutated in place across calls)
--- @return table a QueryBuilder-shaped module (has .new(tableName))
local function makeFakeQueryBuilderModule(tables)
    local nextIds = {}
    local Module = {}
    function Module.new(tableName)
        tables[tableName] = tables[tableName] or {}
        return setmetatable({
            tableName = tableName,
            rows = tables[tableName],
            nextIds = nextIds,
            wheres = {},
            whereNulls = {},
        }, FakeQueryBuilder)
    end
    return Module
end

return makeFakeQueryBuilderModule
