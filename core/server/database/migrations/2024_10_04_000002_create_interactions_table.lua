--- Migration: Create interactions table
return {
    up = function()
        Schema.create('interactions', function(table)
            table:id()
            table:float('x')
            table:float('y')
            table:float('z')
            table:float('range'):default(2.0):nullable()
            table:string('label', 255)
            table:string('action_id', 100):nullable()
            table:json('options'):nullable()
            table:boolean('enabled'):default(1):nullable()
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
