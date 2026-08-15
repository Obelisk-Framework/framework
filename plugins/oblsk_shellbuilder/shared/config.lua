Config = {}

-- Every shell's interior geometry is placed at this one shared, fixed
-- coordinate far below the map. FiveM routing buckets already make two
-- different shells' occupants invisible and non-colliding to each other at
-- identical coordinates, so no per-shell coordinate allocation is needed.
Config.Anchor = { x = -3000.0, y = -3000.0, z = -500.0, heading = 0.0 }

-- The single world interaction that opens the shell browser. Staff can
-- relocate this by editing the coordinates below (e.g. to a "shell
-- builder's office" prop) - no code change needed.
Config.EntryPoint = { x = 215.0, y = -810.0, z = 30.7, range = 2.5, label = 'Shell Access Point' }

-- Default shell_objects budget for a newly-created shell (design's own cap).
Config.DefaultObjectBudget = 900

return Config
