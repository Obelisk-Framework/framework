return {
    up = function()
        Schema.create('instance_buckets', function(table)
            table:id()
            table:string('key', 120):unique()
            table:integer('bucket_id')
            table:timestamps()
        end)

        print('[Migration] Created instance_buckets table')
    end,

    down = function()
        Schema.drop('instance_buckets')
        print('[Migration] Dropped instance_buckets table')
    end
}
