-- core/server/Services/storage/upload_handler.lua
--- POST /storage/upload — the endpoint FiveM's screenshot-basic resource
--- (or any other client-side capture) posts multipart/form-data to. Only
--- writes to a key a server-minted token already named (Storage.
--- mintUploadToken/consumeUploadToken in StorageService.lua) — never a key
--- the client supplies directly, so this is not an open write-anything
--- endpoint. Registered from Storage.init() via SetHttpHandler.
---
--- GET /storage/<key> — serves files written by the local driver
--- (StorageLocal), for parity with S3 URLs being directly fetchable from the
--- bucket. Only implemented for the local driver: an S3-backed deployment's
--- StorageS3.url() already points straight at the bucket, so there's nothing
--- for this resource to serve in that case.

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

--- Guesses a Content-Type from a file extension. Good enough for the small
--- set of file types this endpoint actually serves (screenshots); anything
--- unrecognized falls back to application/octet-stream.
--- @param key string
--- @return string
local function guessContentType(key)
  local ext = key:match('%.([%w]+)$')
  ext = ext and ext:lower()
  if ext == 'jpg' or ext == 'jpeg' then
    return 'image/jpeg'
  elseif ext == 'png' then
    return 'image/png'
  elseif ext == 'webp' then
    return 'image/webp'
  elseif ext == 'webm' then
    return 'video/webm'
  end
  return 'application/octet-stream'
end

--- Handles GET /storage/<key> for the local driver only. Only called once
--- the caller has already confirmed Storage.driver == 'local'.
--- @param req table
--- @param res table
local function handleLocalGet(req, res)
  local key = req.path:sub(#'/storage/' + 1)
  -- Reject any '..' traversal attempt outright (e.g. GET /storage/../../
  -- server.cfg). Unlike Storage.put's key (always server-minted, never
  -- client-supplied), this key comes straight from the request path, so it
  -- needs its own defense-in-depth rather than relying on the token flow.
  if key:find('..', 1, true) then
    res:writeHead(404, {})
    res:send('')
    return
  end
  local basePath = StorageLocal.getBasePath()
  local bytes = LoadResourceFile(GetCurrentResourceName(), basePath .. '/' .. key)
  if not bytes then
    res:writeHead(404, {})
    res:send('')
    return
  end
  res:writeHead(200, { ['Content-Type'] = guessContentType(key) })
  res:send(bytes)
end

SetHttpHandler(function(req, res)
  if req.method == 'GET' and req.path:sub(1, #'/storage/') == '/storage/' and req.path ~= '/storage/upload' then
    if Storage.driver == 'local' then
      handleLocalGet(req, res)
    else
      res:writeHead(404, {})
      res:send('')
    end
    return
  end

  if req.path ~= '/storage/upload' then
    res:writeHead(404, {})
    res:send('')
    return
  end

  req:setDataHandler(function(body)
    Citizen.CreateThread(function()
      local boundary = parseBoundary(req.headers['content-type'])
      if not boundary then
        res:writeHead(400, {})
        res:send('missing multipart boundary')
        return
      end

      local parts = parseMultipart(body, boundary)
      -- screencapture's remoteUpload/startVideoCaptureUpload exports send
      -- exactly one file field plus custom headers - they cannot add a
      -- second multipart "token" field, so this endpoint also accepts the
      -- token via a header. The multipart-body field stays supported for any
      -- other caller.
      local token = (parts.token and parts.token.value) or req.headers['x-storage-token']
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

      local ok, urlOrErr = pcall(Storage.put, pending.key, file.value, pending.contentType)
      if not ok then
        print('[Storage] upload handler: Storage.put failed: ' .. tostring(urlOrErr))
        res:writeHead(502, {})
        res:send('upload failed')
        return
      end

      res:writeHead(200, { ['Content-Type'] = 'application/json' })
      res:send(json.encode({ url = urlOrErr }))
    end)
  end)
end)
