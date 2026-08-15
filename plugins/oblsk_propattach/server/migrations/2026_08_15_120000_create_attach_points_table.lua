return {
    up = function()
        Schema.create('attach_points', function(table)
            table:id()
            table:string('model', 100)
            table:string('point_name', 60)
            table:integer('slot_index'):default(0)
            table:integer('bone_index')
            table:float('offset_x'):default(0)
            table:float('offset_y'):default(0)
            table:float('offset_z'):default(0)
            table:float('rot_x'):default(0)
            table:float('rot_y'):default(0)
            table:float('rot_z'):default(0)
            table:timestamps()

            table:index({'model', 'point_name'})
        end)

        print('[Migration] Created attach_points table')
    end,

    down = function()
        Schema.drop('attach_points')
        print('[Migration] Dropped attach_points table')
    end
}
