--- Migration: Create actions table
return {
    up = function()
        Schema.create('actions', function(table)
            table:id()
            table:string('action_id', 100):unique():notNullable()
            table:string('label', 255)
            table:text('description')
            table:json('options')
            table:boolean('enabled'):default(1)
            table:timestamps()
        end)
        
        print('[Migration] Created actions table')
    end,
    
    down = function()
        Schema.drop('actions')
        print('[Migration] Dropped actions table')
    end
}
