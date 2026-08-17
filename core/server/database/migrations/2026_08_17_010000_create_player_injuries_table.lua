return {
    up = function()
        Database.query([[
            CREATE TABLE IF NOT EXISTS player_injuries (
                id           INTEGER PRIMARY KEY AUTO_INCREMENT,
                player_type  VARCHAR(16) NOT NULL,
                player_id    INTEGER NOT NULL,
                zone         VARCHAR(32) NOT NULL,
                hit_count    INTEGER NOT NULL DEFAULT 1,
                wound_type   VARCHAR(16) NOT NULL,
                created_at   INTEGER NOT NULL,
                treated_at   INTEGER
            )
        ]])
    end,
    down = function() Database.query('DROP TABLE IF EXISTS player_injuries') end,
}
