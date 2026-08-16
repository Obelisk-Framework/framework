WeatherConfig = {
    algorithm       = true,
    window_duration = 7200,
    lookahead_days  = 14,
    climate = {
        base_temp_c       = 18,
        temp_amplitude    = 12,
        rain_probability  = 0.3,
        hot_threshold_c   = 35,
        cold_threshold_c  = 10,
    },
    seasons = {
        snow_months     = {11, 12, 1},
        summer_months   = {6, 7, 8},
        blizzard_chance = 0.1,
    },
    exposure = {
        cold_rate        = 1.0,
        rain_multiplier  = 1.5,
        heat_rate        = 1.0,
        tick_interval    = 60,
    },
}
