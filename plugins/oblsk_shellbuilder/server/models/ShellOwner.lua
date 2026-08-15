ShellOwner = BaseModel:extend('shell_owners')

ShellOwner.primaryKey = 'id'
ShellOwner.timestamps = true

ShellOwner.fillable = { 'shell_id', 'character_id' }
ShellOwner.hidden = {}
ShellOwner.casts = {}

return ShellOwner
