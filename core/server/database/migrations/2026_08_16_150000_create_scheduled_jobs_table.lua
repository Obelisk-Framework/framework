--- Migration: Create scheduled_jobs table
--- Admin-configured schedule for an existing ActionService-registered
--- action. action_id references actions.action_id (string), not a
--- foreign key to actions.id -- actions can be registered after this
--- migration runs (they're code-registered at plugin/module load time),
--- so there's nothing to FK against at migration time.
return {
    up = function()
        Schema.create('scheduled_jobs', function(table)
            table:id()
            table:string('action_id', 100)
            table:string('schedule_type', 20) -- 'interval' | 'cron'
            table:integer('interval_seconds'):nullable()
            table:string('cron_expression', 100):nullable()
            table:boolean('enabled'):default(1)
            table:integer('last_run_at'):nullable() -- unix epoch seconds, NOT a DATETIME string (Database.now() format) -- SchedulerService.isDue does plain numeric arithmetic against os.time()
            table:timestamps()

            table:index({'action_id'})
        end)

        print('[Migration] Created scheduled_jobs table')
    end,

    down = function()
        Schema.drop('scheduled_jobs')
        print('[Migration] Dropped scheduled_jobs table')
    end
}
