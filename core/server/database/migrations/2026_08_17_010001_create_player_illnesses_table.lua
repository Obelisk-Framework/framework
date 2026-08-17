return {
    up = function()
        Database.query([[
            CREATE TABLE IF NOT EXISTS player_illnesses (
                id                   INTEGER PRIMARY KEY AUTO_INCREMENT,
                player_type          VARCHAR(16) NOT NULL,
                player_id            INTEGER NOT NULL,
                illness_type         VARCHAR(32) NOT NULL,
                stage                VARCHAR(16) NOT NULL DEFAULT 'incubating',
                exposure_accumulated FLOAT NOT NULL DEFAULT 0,
                onset_at             INTEGER NOT NULL,
                treated_at           INTEGER
            )
        ]])
        Database.query('CREATE INDEX IF NOT EXISTS idx_player_illnesses_player ON player_illnesses (player_type, player_id)')
    end,
    down = function() Database.query('DROP TABLE IF EXISTS player_illnesses') end,
}
