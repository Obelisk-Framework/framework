--- WeatherForecast Model - a single generated forecast window. Rows are
--- generated in bulk by WeatherService.generateForecast and pruned as they
--- go stale; no created_at/updated_at columns (the table already carries
--- its own `generated_at`), so timestamps are off.
WeatherForecast = BaseModel:extend('weather_forecast')

WeatherForecast.primaryKey = 'id'
WeatherForecast.timestamps = false
WeatherForecast.fillable = {
    'window_start', 'window_end', 'weather_type',
    'temperature', 'precipitation', 'wind_speed', 'generated_at',
}
WeatherForecast.hidden = {}

return WeatherForecast
