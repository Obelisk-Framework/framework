--- Migration: Create interactions table
return {
    up = function()
        Schema.create('interactions', function(table)
            table:id()
            table:float('x'):notNullable()
            table:float('y'):notNullable()
            table:float('z'):notNullable()
            table:float('range'):default(2.0)
            table:string('label', 255):notNullable()
            table:string('action_id', 100)
            table:json('options')
            table:boolean('enabled'):default(1)
            table:timestamps()
            
            table:index({'x', 'y', 'z'})
        end)
        
        print('[Migration] Created interactions table')
    end,
    
    down = function()
        Schema.drop('interactions')
        print('[Migration] Dropped interactions table')
    end
}
