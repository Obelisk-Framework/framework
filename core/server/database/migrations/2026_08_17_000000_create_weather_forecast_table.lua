return {
    up = function()
        Schema.create('weather_forecast', function(table)
            table:id()
            table:integer('window_start')
            table:integer('window_end')
            table:string('weather_type', 32)
            table:float('temperature')
            table:float('precipitation'):default(0)
            table:float('wind_speed'):default(0)
            table:integer('generated_at')
        end)
    end,
    down = function()
        Schema.drop('weather_forecast')
    end,
}
