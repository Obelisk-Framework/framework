-- core/server/Services/storage/sigv4.lua
--- AWS Signature Version 4. Pure functions over strings — no I/O, no
--- knowledge of PerformHttpRequest. core/server/Services/storage/s3.lua
--- builds the actual request and calls these.
Sigv4 = {}

--- @param method string e.g. 'GET', 'PUT', 'DELETE'
--- @param canonicalUri string path, already URI-encoded, e.g. '/test.txt'
--- @param canonicalQuery string query string, already sorted/encoded, or ''
--- @param signedHeaderNames string[] lowercase header names, already sorted
--- @param headers table<string,string> lowercase name -> value, trimmed
--- @param payloadHash string sha256 hex of the request body ('' body -> the well-known empty-string hash)
--- @return string
function Sigv4.canonicalRequest(method, canonicalUri, canonicalQuery, signedHeaderNames, headers, payloadHash)
  local canonicalHeaders = {}
  for _, name in ipairs(signedHeaderNames) do
    canonicalHeaders[#canonicalHeaders + 1] = name .. ':' .. headers[name] .. '\n'
  end
  return table.concat({
    method,
    canonicalUri,
    canonicalQuery,
    table.concat(canonicalHeaders),
    table.concat(signedHeaderNames, ';'),
    payloadHash,
  }, '\n')
end

--- @param amzDate string e.g. '20130524T000000Z'
--- @param dateStamp string e.g. '20130524'
--- @param region string e.g. 'us-east-1'
--- @param service string e.g. 's3'
--- @param canonicalRequestHash string sha256 hex of the canonical request
--- @return string
function Sigv4.stringToSign(amzDate, dateStamp, region, service, canonicalRequestHash)
  local scope = dateStamp .. '/' .. region .. '/' .. service .. '/aws4_request'
  return table.concat({'AWS4-HMAC-SHA256', amzDate, scope, canonicalRequestHash}, '\n')
end

--- @param secretKey string
--- @param dateStamp string
--- @param region string
--- @param service string
--- @return string raw 32-byte signing key
function Sigv4.signingKey(secretKey, dateStamp, region, service)
  local kDate = Sha256.hmac('AWS4' .. secretKey, dateStamp)
  local kRegion = Sha256.hmac(kDate, region)
  local kService = Sha256.hmac(kRegion, service)
  return Sha256.hmac(kService, 'aws4_request')
end

--- @return string 64-char lowercase hex signature
function Sigv4.signature(secretKey, dateStamp, region, service, stringToSign)
  local key = Sigv4.signingKey(secretKey, dateStamp, region, service)
  return Sha256.hex(Sha256.hmac(key, stringToSign))
end
