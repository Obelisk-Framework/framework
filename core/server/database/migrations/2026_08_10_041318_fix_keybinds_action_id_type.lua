--- Migration: Fix keybinds.action_id to be the integer actions.id it always
--- claimed to be. The column was VARCHAR(100) storing the string actionId,
--- while loadPlayerKeybinds's query already joined ON k.action_id = a.id
--- (the integer PK), a join that never matched anything. See the item
--- module design spec (2026-08-10-item-module-design.md) for the full story.
return {
    up = function()
        Schema.table('keybinds', function(table)
            table:integer('action_id_int')
        end)

        local rows = Database.querySync('SELECT id, action_id FROM keybinds', {})
        for _, row in ipairs(rows or {}) do
            local action = Database.querySync('SELECT id FROM actions WHERE action_id = ?', {row.action_id})
            if action and action[1] then
                Database.updateSync('UPDATE keybinds SET action_id_int = ? WHERE id = ?', {action[1].id, row.id})
            else
                print('[Migration] WARNING: keybind #' .. row.id .. ' references unknown action_id "' .. tostring(row.action_id) .. '", leaving action_id_int NULL')
            end
        end

        Schema.dropColumn('keybinds', 'action_id')
        Schema.renameColumn('keybinds', 'action_id_int', 'action_id')

        print('[Migration] Converted keybinds.action_id to an integer FK against actions.id')
    end,

    down = function()
        error('This migration is not reversible: the original varchar action_id values are not recoverable once dropped.')
    end
}
