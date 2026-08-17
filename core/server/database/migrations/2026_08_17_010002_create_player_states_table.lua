return {
    up = function()
        Schema.create('player_states', function(t)
            t:id()
            t:string('player_type', 16)
            t:integer('player_id')
            t:string('state', 16):default('healthy')
            t:integer('state_since')
            t:integer('updated_at')
            t:unique({'player_type', 'player_id'})
        end)
    end,
    down = function() Schema.drop('player_states') end,
}
