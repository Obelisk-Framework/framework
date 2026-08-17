return {
    up = function()
        Database.query([[
            CREATE TABLE IF NOT EXISTS player_states (
                id          INTEGER PRIMARY KEY AUTO_INCREMENT,
                player_type VARCHAR(16) NOT NULL,
                player_id   INTEGER NOT NULL,
                state       VARCHAR(16) NOT NULL DEFAULT 'healthy',
                state_since INTEGER NOT NULL,
                updated_at  INTEGER NOT NULL,
                UNIQUE(player_type, player_id)
            )
        ]])
    end,
    down = function() Database.query('DROP TABLE IF EXISTS player_states') end,
}
