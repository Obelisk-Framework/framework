--- Given a directory of migration files, loads and runs each one's up()
--- against the already-loaded Schema/Database globals (Database.executeQuery
--- stubbed to a no-op per file, which covers querySync/insertSync/insert
--- alike since they all funnel through it), returning which passed/failed.
--- Reused by both migration_audit_spec.lua (core's own migrations) and the
--- per-repo audit tasks that verify modules'/plugins' migrations after
--- rewriting them (invoked the same way, pointed at a different directory).
local AuditMigrations = {}

--- @param directoryPath string absolute or relative path to a flat directory of *.lua migration files
--- @return table { passed: string[], failed: {file: string, error: string}[] }
function AuditMigrations.run(directoryPath)
    local passed, failed = {}, {}

    local pfile = io.popen('ls "' .. directoryPath .. '"/*.lua 2>/dev/null')
    local files = {}
    for line in pfile:lines() do
        table.insert(files, line)
    end
    pfile:close()

    for _, path in ipairs(files) do
        local originalExecuteQuery = Database.executeQuery
        Database.executeQuery = function() return {} end

        local ok, err = pcall(function()
            local migration = dofile(path)
            if type(migration) ~= 'table' or type(migration.up) ~= 'function' then
                error('migration file does not return { up = function() ... end }')
            end
            migration.up()
        end)

        Database.executeQuery = originalExecuteQuery

        if ok then
            table.insert(passed, path)
        else
            table.insert(failed, { file = path, error = tostring(err) })
        end
    end

    return { passed = passed, failed = failed }
end

return AuditMigrations
