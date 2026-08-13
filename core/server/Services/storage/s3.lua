-- core/server/Services/storage/s3.lua
--- S3-compatible storage provider (AWS S3, MinIO, R2, Spaces — anything
--- speaking the S3 API at a path-style endpoint). Signs every request with
--- AWS SigV4 (core/server/Services/storage/sigv4.lua). Uses
--- PerformHttpRequest wrapped in a promise/Citizen.Await pair to present a
--- synchronous call, matching Database.querySync's sync-over-async style.
StorageS3 = {}

local config = { endpoint = '', bucket = '', accessKey = '', secretKey = '', region = 'us-east-1' }

--- @param cfg table { endpoint, bucket, accessKey, secretKey, region }
function StorageS3.configure(cfg)
  for k, v in pairs(cfg) do config[k] = v end
end

--- Minimal percent-encoding for building a SigV4 canonicalUri: encodes
--- everything except the unreserved characters (A-Z a-z 0-9 . _ ~ -) and the
--- path separator '/', which SigV4 canonical URIs use to delimit segments.
--- Not a general-purpose URL encoder (query strings, IRIs, etc. are out of
--- scope) — just enough to keep a signed key with spaces/non-ASCII bytes
--- correct.
--- @param s string
--- @return string
local function uriEncodePath(s)
  return (s:gsub('[^%w._~/-]', function(c)
    return string.format('%%%02X', c:byte())
  end))
end

local function amzDateNow()
  -- os.date with '!' formats in UTC, required by SigV4.
  return os.date('!%Y%m%dT%H%M%SZ'), os.date('!%Y%m%d')
end

--- @param method string
--- @param key string
--- @param body string
--- @return string url, table headers
local function signedRequest(method, key, body)
  local url = config.endpoint .. '/' .. config.bucket .. '/' .. key
  local host = url:match('^https?://([^/]+)')
  local amzDate, dateStamp = amzDateNow()
  local payloadHash = Sha256.hex(Sha256.digest(body or ''))

  local headers = {
    host = host,
    ['x-amz-content-sha256'] = payloadHash,
    ['x-amz-date'] = amzDate,
  }
  local signedHeaderNames = {'host', 'x-amz-content-sha256', 'x-amz-date'}
  table.sort(signedHeaderNames)

  local canonicalUri = uriEncodePath('/' .. config.bucket .. '/' .. key)
  local canonicalRequest = Sigv4.canonicalRequest(method, canonicalUri, '', signedHeaderNames, headers, payloadHash)
  local canonicalRequestHash = Sha256.hex(Sha256.digest(canonicalRequest))
  local stringToSign = Sigv4.stringToSign(amzDate, dateStamp, config.region, 's3', canonicalRequestHash)
  local signature = Sigv4.signature(config.secretKey, dateStamp, config.region, 's3', stringToSign)

  local credentialScope = dateStamp .. '/' .. config.region .. '/s3/aws4_request'
  local authorization = string.format(
    'AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s',
    config.accessKey, credentialScope, table.concat(signedHeaderNames, ';'), signature
  )

  local outHeaders = {
    host = host,
    ['x-amz-date'] = amzDate,
    ['x-amz-content-sha256'] = payloadHash,
    ['Authorization'] = authorization,
  }
  return url, outHeaders
end

--- Wraps PerformHttpRequest in a promise so callers get a synchronous call,
--- matching this framework's Database.querySync convention.
local function httpSync(method, url, body, headers)
  local p = promise.new()
  PerformHttpRequest(url, function(status, respBody, respHeaders)
    p:resolve({ status = status, body = respBody, headers = respHeaders })
  end, method, body or '', headers)
  return Citizen.Await(p)
end

--- @param key string
--- @param bytes string
--- @param contentType string
--- @return string url
function StorageS3.put(key, bytes, contentType)
  local url, headers = signedRequest('PUT', key, bytes)
  headers['Content-Type'] = contentType
  local result = httpSync('PUT', url, bytes, headers)
  if result.status < 200 or result.status >= 300 then
    error(string.format('[StorageS3] put failed for key "%s": HTTP %d %s', key, result.status, tostring(result.body)), 2)
  end
  return url
end

--- @param key string
--- @return boolean
function StorageS3.delete(key)
  local url, headers = signedRequest('DELETE', key, '')
  local result = httpSync('DELETE', url, '', headers)
  -- 404 counts as success: the end state ("this key has no object") matches
  -- what the caller wanted, same as StorageLocal.delete not erroring on a
  -- missing file.
  return (result.status >= 200 and result.status < 300) or result.status == 404
end

--- @param key string
--- @return string url
function StorageS3.url(key)
  return config.endpoint .. '/' .. config.bucket .. '/' .. key
end
