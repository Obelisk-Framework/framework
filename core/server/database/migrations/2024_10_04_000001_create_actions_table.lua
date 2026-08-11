--- Migration: Create actions table
return {
    up = function()
        Schema.create('actions', function(table)
            table:id()
            table:string('action_id', 100):unique()
            table:string('label', 255):nullable()
            table:text('description'):nullable()
            table:json('options'):nullable()
            table:boolean('enabled'):default(1):nullable()
            table:timestamps()
        end)
        
        print('[Migration] Created actions table')
    end,
    
    down = function()
        Schema.drop('actions')
        print('[Migration] Dropped actions table')
    end
}
