return {
    up = function()
        Schema.create('weather_forecast', function(t)
            t:id()
            t:integer('window_start')
            t:integer('window_end')
            t:string('weather_type', 32)
            t:float('temperature')
            t:float('precipitation'):default(0)
            t:float('wind_speed'):default(0)
            t:integer('generated_at')
        end)
    end,
    down = function() Schema.drop('weather_forecast') end,
}
