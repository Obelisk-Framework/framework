return {
    up = function()
        Schema.create('attachments', function(table)
            table:id()
            table:string('prop_model', 100)
            table:enum('parent_entity_type', {'vehicle', 'ped', 'player', 'object'})
            table:integer('parent_net_id')
            table:string('point_name', 60)
            table:integer('slot_index'):default(0)
            table:string('owner_type', 30):nullable()
            table:integer('owner_id'):nullable()
            table:json('data'):nullable()
            table:timestamps()

            table:index({'parent_entity_type', 'parent_net_id'})
        end)

        print('[Migration] Created attachments table')
    end,

    down = function()
        Schema.drop('attachments')
        print('[Migration] Dropped attachments table')
    end
}
