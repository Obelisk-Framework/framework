return {
    up = function()
        Schema.create('shell_owners', function(table)
            table:id()
            table:foreignId('shell_id'):constrained('shells'):onDelete('CASCADE')
            table:integer('character_id')
            table:timestamps()

            table:index({'shell_id'})
            table:index({'character_id'})
        end)

        print('[Migration] Created shell_owners table')
    end,

    down = function()
        Schema.drop('shell_owners')
        print('[Migration] Dropped shell_owners table')
    end
}
