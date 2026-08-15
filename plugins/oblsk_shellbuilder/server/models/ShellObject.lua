ShellObject = BaseModel:extend('shell_objects')

ShellObject.primaryKey = 'id'
ShellObject.timestamps = true

ShellObject.fillable = {
    'shell_id', 'item_key', 'x', 'y', 'z', 'heading', 'floor_level',
    'locked', 'placed_by_character_id', 'color_data',
}

ShellObject.hidden = {}
ShellObject.casts = {
    color_data = 'json',
}

return ShellObject
