--- Migration: rename actions.action_id to actions.name. The old name read
--- like a foreign key to itself; this column is the action's own string
--- business key (e.g. "gasstation:refill"), not a reference to anything.
return {
    up = function()
        Schema.renameColumn('actions', 'action_id', 'name')
        print('[Migration] Renamed actions.action_id to actions.name')
    end,

    down = function()
        Schema.renameColumn('actions', 'name', 'action_id')
    end
}
