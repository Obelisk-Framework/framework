--- Migration: Add base_items.is_presentable, the flag ContextMenu.vue's new
--- "Present" button (Task 8) checks. Lives here rather than in oblsk_items
--- because oblsk_licenses is the first (and so far only) consumer — the
--- generic step/data columns already on base_items are enough for every
--- other plugin's item type.
return {
    up = function()
        Schema.table('base_items', function(table)
            table:boolean('is_presentable'):default(0):nullable()
        end)

        print('[Migration] Added is_presentable to base_items table')
    end,

    down = function()
        Schema.dropColumn('base_items', 'is_presentable')
        print('[Migration] Dropped is_presentable from base_items table')
    end
}
