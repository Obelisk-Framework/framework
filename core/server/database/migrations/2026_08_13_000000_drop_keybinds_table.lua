--- Migration: Drop keybinds table — replaced by the default/account/character
--- resolution model (actions.options.default_key + oblsk_preferences rows).
--- See docs/superpowers/specs/2026-08-13-keybind-layering-design.md.
return {
    up = function()
        Schema.drop('keybinds')
        print('[Migration] Dropped keybinds table')
    end,

    down = function()
        Schema.create('keybinds', function(table)
            table:id()
            table:string('key_code', 50)
            table:string('action_id', 100)
            table:integer('action_id_int'):nullable()
            table:json('data'):nullable()
            table:boolean('is_global'):default(0):nullable()
            table:string('player_identifier', 100):nullable()
            table:boolean('enabled'):default(1):nullable()
            table:timestamps()

            table:index({'key_code'})
            table:index({'player_identifier'})
            table:index({'is_global'})
        end)
        print('[Migration] Recreated keybinds table')
    end
}
