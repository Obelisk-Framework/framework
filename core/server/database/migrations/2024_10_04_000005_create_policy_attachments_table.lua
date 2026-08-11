--- Migration: Create policy_attachments table (polymorphic n-n)
return {
    up = function()
        Schema.create('policy_attachments', function(table)
            table:id()
            table:string('policy_id', 100)
            table:string('resource_type', 50) -- 'interaction', 'action', etc.
            table:string('resource_id', 100)
            table:json('config'):nullable() -- Pivot data for policy configuration
            table:timestamps()
            
            table:index({'policy_id'})
            table:index({'resource_type', 'resource_id'})
            table:unique({'policy_id', 'resource_type', 'resource_id'})
        end)
        
        print('[Migration] Created policy_attachments table')
    end,
    
    down = function()
        Schema.drop('policy_attachments')
        print('[Migration] Dropped policy_attachments table')
    end
}
