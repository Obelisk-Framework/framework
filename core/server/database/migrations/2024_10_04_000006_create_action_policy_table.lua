--- Migration: Create action_policy pivot table
return {
    up = function()
        Schema.create('action_policy', function(table)
            table:id()
            table:string('action_id', 100):notNullable()
            table:string('policy_id', 100):notNullable()
            table:json('data')
            table:timestamps()
            
            table:index({'action_id'})
            table:index({'policy_id'})
            table:unique({'action_id', 'policy_id'})
        end)
        
        print('[Migration] Created action_policy table')
    end,
    
    down = function()
        Schema.drop('action_policy')
        print('[Migration] Dropped action_policy table')
    end
}
