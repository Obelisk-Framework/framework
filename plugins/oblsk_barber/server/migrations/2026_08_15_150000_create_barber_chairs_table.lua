--- Migration: Create barber_chairs table
--- One row per physical barber chair, same interaction-FK shape as
--- cardealer_shops/tuner_shops.
return {
    up = function()
        Schema.create('barber_chairs', function(table)
            table:id()
            table:string('name', 100)
            table:foreignId('interaction_id'):constrained('interactions'):onDelete('CASCADE')
            table:timestamps()

            table:unique('interaction_id')
        end)

        print('[Migration] Created barber_chairs table')
    end,

    down = function()
        Schema.drop('barber_chairs')
        print('[Migration] Dropped barber_chairs table')
    end
}
