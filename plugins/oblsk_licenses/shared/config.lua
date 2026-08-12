Config = {}

-- Years of validity granted to the auto-issued state ID on character create.
Config.StateIdValidYears = 6

-- Radius (metres) scanned for nearby players when a license is presented.
Config.PresentRadius = 3.0

-- Per-department theme/authority overrides applied to a `license_duty`
-- instance at issue time (Task 3). Any dept code not listed here falls back
-- to the license_duty base item's own seeded defaults (Task 2).
Config.DutyDeptPresets = {
    LSPD = {
        theme = { a = '#1b3763', b = '#080f1c', ink = '#e8f0ff', accent = '#6ea8ff' },
        authority = 'Los Santos Police Department',
    },
    LSMD = {
        theme = { a = '#14494a', b = '#06191b', ink = '#e7fbfa', accent = '#3ed6c8' },
        authority = 'Los Santos Medical Department',
    },
    DOJ = {
        theme = { a = '#4a3a12', b = '#1a1406', ink = '#fdf3dd', accent = '#e0b64a' },
        authority = 'Department of Justice',
    },
}

return Config
