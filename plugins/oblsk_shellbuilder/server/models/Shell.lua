Shell = BaseModel:extend('shells')

Shell.primaryKey = 'id'
Shell.timestamps = true

Shell.fillable = {
    'name', 'entry_x', 'entry_y', 'entry_z', 'entry_heading', 'interior_heading',
    'object_budget', 'timecycle', 'created_by_character_id',
}

Shell.hidden = {}
Shell.casts = {}

return Shell
