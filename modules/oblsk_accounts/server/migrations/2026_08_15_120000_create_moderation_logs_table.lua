-- core/modules/oblsk_accounts/server/migrations/2026_08_15_120000_create_moderation_logs_table.lua
--- Migration: Create moderation_logs table — persists warn/kick history.
--- Bans already persist via the `bans` table (see
--- 2026_08_10_090623_create_bans_table.lua); this covers the two
--- moderation actions that had nowhere to live before.
return {
    up = function()
        Schema.create('moderation_logs', function(table)
            table:id()
            table:integer('account_id')
            table:string('type', 10) -- 'warn' | 'kick', enforced at the service layer
            table:text('reason')
            table:string('issued_by', 255)
            table:timestamps()

            table:index({'account_id'})
            table:foreign('account_id'):references('id'):on('accounts'):onDelete('CASCADE')
        end)

        print('[Migration] Created moderation_logs table')
    end,

    down = function()
        Schema.drop('moderation_logs')
        print('[Migration] Dropped moderation_logs table')
    end
}
