--- Migration: Create keybinds table
return {
    up = function()
        Schema.create('keybinds', function(table)
            table:id()
            table:string('key_code', 50):notNullable()
            table:string('action_id', 100):notNullable()
            table:json('data')
            table:boolean('is_global'):default(0)
            table:string('player_identifier', 100)
            table:boolean('enabled'):default(1)
            table:timestamps()
            
            table:index({'key_code'})
            table:index({'player_identifier'})
            table:index({'is_global'})
        end)
        
        print('[Migration] Created keybinds table')
    end,
    
    down = function()
        Schema.drop('keybinds')
        print('[Migration] Dropped keybinds table')
    end
}
