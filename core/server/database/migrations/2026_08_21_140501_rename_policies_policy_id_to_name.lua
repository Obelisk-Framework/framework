--- Migration: rename policies.policy_id to policies.name, for the same
--- reason as actions.action_id -> actions.name. The policies table itself
--- is currently unused (PolicyService keeps its registry in memory), but
--- the column is renamed for consistency in case it's read from directly.
return {
    up = function()
        Schema.renameColumn('policies', 'policy_id', 'name')
        print('[Migration] Renamed policies.policy_id to policies.name')
    end,

    down = function()
        Schema.renameColumn('policies', 'name', 'policy_id')
    end
}
