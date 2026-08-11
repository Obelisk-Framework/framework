--- Migration: Create interaction_policy pivot table
return {
    up = function()
        Schema.create('interaction_policy', function(table)
            table:id()
            table:integer('interaction_id')
            table:string('policy_id', 100)
            table:json('data'):nullable()
            table:timestamps()
            
            table:index({'interaction_id'})
            table:index({'policy_id'})
            table:unique({'interaction_id', 'policy_id'})
        end)
        
        print('[Migration] Created interaction_policy table')
    end,
    
    down = function()
        Schema.drop('interaction_policy')
        print('[Migration] Dropped interaction_policy table')
    end
}
