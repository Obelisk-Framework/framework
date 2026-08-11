--- Migration: Create policies table
return {
    up = function()
        Schema.create('policies', function(table)
            table:id()
            table:string('policy_id', 100):unique()
            table:string('label', 255):nullable()
            table:text('description'):nullable()
            table:boolean('enabled'):default(1):nullable()
            table:timestamps()
        end)
        
        print('[Migration] Created policies table')
    end,
    
    down = function()
        Schema.drop('policies')
        print('[Migration] Dropped policies table')
    end
}
