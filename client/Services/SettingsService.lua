--- Exposes the shared Settings.format table (core/shared/Settings.lua) to
--- the web/NUI layer. Answered directly from the client's own copy — no
--- server round-trip needed, since Settings is a shared script.
RegisterNUICallback('core:client:getFormatSettings', function(_data, cb)
    cb(Settings.format)
end)
