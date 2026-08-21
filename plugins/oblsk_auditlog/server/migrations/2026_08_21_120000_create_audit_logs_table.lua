return {
    up = function()
        Schema.create('audit_logs', function(table)
            table:id()
            table:string('table_name', 64)
            table:integer('row_id')
            table:string('action', 10)
            table:string('actor_type', 10)
            table:integer('actor_id'):nullable()
            table:string('field', 64)
            table:text('old_value'):nullable()
            table:text('new_value'):nullable()
            table:timestamp('created_at')
        end)

        print('[Migration] Created audit_logs table')
    end,

    down = function()
        Schema.drop('audit_logs')
        print('[Migration] Dropped audit_logs table')
    end
}
