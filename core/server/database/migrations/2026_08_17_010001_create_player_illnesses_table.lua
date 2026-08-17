return {
    up = function()
        Schema.create('player_illnesses', function(t)
            t:id()
            t:string('player_type', 16)
            t:integer('player_id')
            t:string('illness_type', 32)
            t:string('stage', 16):default('incubating')
            t:float('exposure_accumulated'):default(0)
            t:integer('onset_at')
            t:integer('treated_at'):nullable()
            t:index({'player_type', 'player_id'})
        end)
    end,
    down = function() Schema.drop('player_illnesses') end,
}
