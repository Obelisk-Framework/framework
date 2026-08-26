AuditLogConfig = {}

--- Which models to audit and which of their fields to watch.
--- `fields = '*'` audits every field in that model's `fillable` list
--- (minus any `hidden` fields, see AuditLogService.fieldsFor).
--- Empty by default -- consuming plugins/operators opt models in here.
--- NOTE: AuditLogService.withActor() only reliably attributes actor for
--- bare save()/delete(); see its doc comment before wiring a model here
--- that writes via saveAsync()/deleteAsync().
AuditLogConfig.Watch = {
    -- BankAccount = { fields = { 'balance', 'owner_id' } },
    -- BankTransaction = { fields = '*' },
}
