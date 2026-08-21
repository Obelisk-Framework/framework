AuditLogConfig = {}

--- Which models to audit and which of their fields to watch.
--- `fields = '*'` audits every field in that model's `fillable` list.
--- Empty by default -- consuming plugins/operators opt models in here.
AuditLogConfig.Watch = {
    -- BankAccount = { fields = { 'balance', 'owner_id' } },
    -- BankTransaction = { fields = '*' },
}
