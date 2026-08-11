--- Migration: Create entities table
return {
    up = function()
        Schema.create('entities', function(table)
            table:id()
            table:enum('entity_type', {'ped', 'object', 'pickup', 'marker', 'blip'})
            table:string('model', 100):nullable()
            table:float('x')
            table:float('y')
            table:float('z')
            table:float('heading'):nullable()
            table:boolean('networked'):default(0)
            table:boolean('enabled'):default(1)
            table:string('owner_type', 30):nullable()
            table:integer('owner_id'):nullable()
            table:json('data'):nullable()
            table:timestamps()

            table:index({'x', 'y'})
        end)

        print('[Migration] Created entities table')
    end,

    down = function()
        Schema.drop('entities')
        print('[Migration] Dropped entities table')
    end
}
