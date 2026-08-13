--- Migration: Add admin-panel fields to organizations, and a contact
--- numbers table. Additive only — see
--- docs/superpowers/specs/2026-08-13-admin-panel-organisations-design.md.
return {
    up = function()
        Schema.table('organizations', function(table)
            table:string('short_code', 10):nullable()
            table:string('colour', 7):nullable()
            table:string('type', 20):default('Government')
        end)

        Schema.create('organization_contact_numbers', function(table)
            table:id()
            table:integer('organization_id')
            table:string('number', 20)
            table:string('label', 50)
            table:boolean('enabled'):default(1)
            table:timestamps()

            table:index({'organization_id'})
            table:foreign('organization_id'):references('id'):on('organizations'):onDelete('CASCADE')
        end)

        print('[Migration] Added admin fields to organizations and created organization_contact_numbers table')
    end,

    down = function()
        Schema.drop('organization_contact_numbers')
        Schema.dropColumn('organizations', 'short_code')
        Schema.dropColumn('organizations', 'colour')
        Schema.dropColumn('organizations', 'type')
        print('[Migration] Reverted admin fields and dropped organization_contact_numbers table')
    end
}
