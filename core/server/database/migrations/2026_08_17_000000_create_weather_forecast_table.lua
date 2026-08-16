return {
    up = function()
        Database.query([[
            CREATE TABLE IF NOT EXISTS weather_forecast (
                id              INTEGER PRIMARY KEY AUTO_INCREMENT,
                window_start    INTEGER NOT NULL,
                window_end      INTEGER NOT NULL,
                weather_type    VARCHAR(32) NOT NULL,
                temperature     FLOAT NOT NULL,
                precipitation   FLOAT NOT NULL DEFAULT 0,
                wind_speed      FLOAT NOT NULL DEFAULT 0,
                generated_at    INTEGER NOT NULL
            )
        ]])
    end,
    down = function()
        Database.query('DROP TABLE IF EXISTS weather_forecast')
    end,
}
