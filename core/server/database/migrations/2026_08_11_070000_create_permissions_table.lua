--- Migration: Create permissions table
--- One generic polymorphic permission-grant table, reusable by any entity
--- type any module registers with PermissionService. See
--- docs/superpowers/specs/2026-08-11-organizations-and-permissions-design.md.
return {
    up = function()
        Schema.create('permissions', function(table)
            table:id()
            table:string('owner_type', 50)
            table:integer('owner_id')
            table:string('permission_key', 150)
            table:timestamps()

            table:unique({'owner_type', 'owner_id', 'permission_key'})
            table:index({'owner_type', 'owner_id'})
        end)

        print('[Migration] Created permissions table')
    end,

    down = function()
        Schema.drop('permissions')
        print('[Migration] Dropped permissions table')
    end
}
