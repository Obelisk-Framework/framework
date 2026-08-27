AuditLog = BaseModel:extend('audit_logs')

AuditLog.primaryKey = 'id'
AuditLog.timestamps = false
AuditLog.fillable = {
    'table_name', 'row_id', 'action', 'actor_type', 'actor_id',
    'field', 'old_value', 'new_value', 'created_at',
}
AuditLog.hidden = {}

return AuditLog
