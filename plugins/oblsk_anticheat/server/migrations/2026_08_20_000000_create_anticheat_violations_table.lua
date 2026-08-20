return {
    up = function()
        Schema.create('anticheat_violations', function(table)
            table:id()
            table:integer('player_id')
            table:string('category', 30)
            table:string('detail', 255)
            table:string('severity', 10)
            table:timestamps()

            table:index({'player_id', 'created_at'})
        end)

        print('[Migration] Created anticheat_violations table')
    end,

    down = function()
        Schema.drop('anticheat_violations')
        print('[Migration] Dropped anticheat_violations table')
    end
}
