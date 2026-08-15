return {
    up = function()
        Schema.create('shells', function(table)
            table:id()
            table:string('name', 100)
            table:float('entry_x')
            table:float('entry_y')
            table:float('entry_z')
            table:float('entry_heading'):default(0)
            table:float('interior_heading'):default(0)
            table:integer('object_budget'):default(900)
            table:string('timecycle', 40):default('Neutral')
            table:integer('created_by_character_id')
            table:timestamps()
        end)

        print('[Migration] Created shells table')
    end,

    down = function()
        Schema.drop('shells')
        print('[Migration] Dropped shells table')
    end
}
