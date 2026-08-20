--- Derives one-time net event names from a per-player session secret.
--- Pure function — no state, no I/O. Callers (SecureEventService on both
--- sides) own the counter bookkeeping; this module only computes the name
--- for a given (secret, logicalEvent, direction, counter) tuple, and it
--- must produce byte-identical output on client and server for the same
--- inputs, since both sides derive the same name independently.
EventNaming = EventNaming or {}

--- @param sessionSecret string per-player secret exchanged at handshake
--- @param logicalEvent string the plugin-facing event name, e.g. 'garage:server:open'
--- @param direction string 'client_to_server' or 'server_to_client'
--- @param counter integer how many times this (logicalEvent, direction) pair has been sent this session
--- @return string a 23-char name: 'ob_' + 20 lowercase hex chars
function EventNaming.deriveName(sessionSecret, logicalEvent, direction, counter)
    local material = logicalEvent .. ':' .. direction .. ':' .. tostring(counter)
    local digest = Sha256.hex(Sha256.hmac(sessionSecret, material))
    return 'ob_' .. digest:sub(1, 20)
end

return EventNaming
