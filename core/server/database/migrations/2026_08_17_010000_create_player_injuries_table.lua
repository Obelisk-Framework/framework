return {
    up = function()
        Schema.create('player_injuries', function(t)
            t:id()
            t:string('player_type', 16)
            t:integer('player_id')
            t:string('zone', 32)
            t:integer('hit_count'):default(1)
            t:string('wound_type', 16)
            t:integer('created_at')
            t:integer('treated_at'):nullable()
            t:index({'player_type', 'player_id'})
        end)
    end,
    down = function() Schema.drop('player_injuries') end,
}
