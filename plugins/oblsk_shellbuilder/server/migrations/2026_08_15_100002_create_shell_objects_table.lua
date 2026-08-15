return {
    up = function()
        Schema.create('shell_objects', function(table)
            table:id()
            table:foreignId('shell_id'):constrained('shells'):onDelete('CASCADE')
            table:string('item_key', 60)
            table:float('x')
            table:float('y')
            table:float('z')
            table:float('heading'):default(0)
            table:integer('floor_level'):default(0)
            table:boolean('locked'):default(0)
            table:integer('placed_by_character_id'):nullable()
            table:json('color_data'):nullable()
            table:timestamps()

            table:index({'shell_id'})
        end)

        print('[Migration] Created shell_objects table')
    end,

    down = function()
        Schema.drop('shell_objects')
        print('[Migration] Dropped shell_objects table')
    end
}
