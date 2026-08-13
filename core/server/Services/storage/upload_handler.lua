-- core/server/Services/storage/upload_handler.lua
--- POST /storage/upload — the endpoint FiveM's screenshot-basic resource
--- (or any other client-side capture) posts multipart/form-data to. Only
--- writes to a key a server-minted token already named (Storage.
--- mintUploadToken/consumeUploadToken in StorageService.lua) — never a key
--- the client supplies directly, so this is not an open write-anything
--- endpoint. Registered from Storage.init() via SetHttpHandler.

--- Extracts the boundary token from a `Content-Type: multipart/form-data;
--- boundary=XYZ` header value.
--- @param contentType string
--- @return string|nil boundary
local function parseBoundary(contentType)
  return contentType and contentType:match('boundary=([^;]+)')
end

--- Splits a multipart body into its named parts. Returns a table keyed by
--- the `name="..."` in each part's Content-Disposition header, each value
--- `{ value = string, filename = string|nil, contentType = string|nil }`.
--- Minimal by design: handles exactly the shape screenshot-basic and this
--- endpoint's own tests produce (no nested multipart, no header folding).
--- @param body string
--- @param boundary string
--- @return table<string, table>
local function parseMultipart(body, boundary)
  local parts = {}
  local delimiter = '--' .. boundary
  for chunk in (body .. '\r\n' .. delimiter .. '--'):gmatch('(.-)\r\n' .. delimiter:gsub('%p', '%%%1')) do
    if chunk ~= '' and chunk ~= '--' then
      local headerBlock, value = chunk:match('^\r?\n?(.-)\r\n\r\n(.*)$')
      if headerBlock then
        local name = headerBlock:match('name="([^"]*)"')
        local filename = headerBlock:match('filename="([^"]*)"')
        local contentType = headerBlock:match('Content%-Type:%s*([^\r\n]+)')
        if name then
          parts[name] = { value = value, filename = filename, contentType = contentType }
        end
      end
    end
  end
  return parts
end

SetHttpHandler(function(req, res)
  if req.path ~= '/storage/upload' then
    res:writeHead(404, {})
    res:send('')
    return
  end

  req:setDataHandler(function(body)
    local boundary = parseBoundary(req.headers['content-type'])
    if not boundary then
      res:writeHead(400, {})
      res:send('missing multipart boundary')
      return
    end

    local parts = parseMultipart(body, boundary)
    local token = parts.token and parts.token.value
    local pending = token and Storage.consumeUploadToken(token)
    if not pending then
      res:writeHead(403, {})
      res:send('invalid or expired token')
      return
    end

    local file = parts['files[]']
    if not file or not file.value or #file.value == 0 then
      res:writeHead(400, {})
      res:send('missing file')
      return
    end

    local url = Storage.put(pending.key, file.value, pending.contentType)
    res:writeHead(200, { ['Content-Type'] = 'application/json' })
    res:send(json.encode({ url = url }))
  end)
end)
