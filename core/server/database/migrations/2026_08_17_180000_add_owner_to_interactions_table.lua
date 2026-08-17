return {
    up = function()
        Schema.table('interactions', function(table)
            table:string('owner_type', 50):nullable()
            table:integer('owner_id'):nullable()
            table:unique({'owner_type', 'owner_id'})
        end)
        print('[Migration] Added owner_type/owner_id to interactions')
    end,

    down = function()
        Database.query('ALTER TABLE `interactions` DROP INDEX `interactions_owner_type_owner_id_index`', {})
        Schema.dropColumn('interactions', 'owner_id')
        Schema.dropColumn('interactions', 'owner_type')
        print('[Migration] Dropped owner_type/owner_id from interactions')
    end
}
