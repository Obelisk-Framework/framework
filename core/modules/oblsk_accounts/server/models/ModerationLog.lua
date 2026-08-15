-- core/modules/oblsk_accounts/server/models/ModerationLog.lua
--- ModerationLog Model - warn/kick history. Bans stay in their own `bans`
--- table (older, already has expires_at/revoked_at); this is only for the
--- two moderation actions that don't have a lifecycle to track.
ModerationLog = BaseModel:extend('moderation_logs')

ModerationLog.primaryKey = 'id'
ModerationLog.timestamps = true
ModerationLog.fillable = { 'account_id', 'type', 'reason', 'issued_by' }
ModerationLog.hidden = {}

function ModerationLog:accountRelation()
    return self:belongsTo(Account, 'account_id', 'id')
end

return ModerationLog
