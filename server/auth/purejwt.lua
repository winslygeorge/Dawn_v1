-- utils/purejwt.lua
local M = {}
local bit = require("bit") -- LuaJIT/5.1-compatible bit library
local json = require("dkjson") -- works in LuaJIT / 5.1
local sha2 = require("auth.sha256")

-- Helpers
local function hex_to_bin(hex)
    return (hex:gsub('..', function(cc)
        return string.char(tonumber(cc, 16))
    end))
end

local function sha256hex(msg)
    return sha2.sha256_hex(msg)
end

local function sha256(msg)
    return hex_to_bin(sha256hex(msg))
end

local function hmac_sha256(key, message)
    local blocksize = 64
    if #key > blocksize then key = sha256(key) end
    key = key .. string.rep('\0', blocksize - #key)

    local o_key_pad, i_key_pad = {}, {}
    for i = 1, blocksize do
        local b = key:byte(i)
        o_key_pad[i] = string.char(bit.bxor(b, 0x5c))
        i_key_pad[i] = string.char(bit.bxor(b, 0x36))
    end

    local o_pad = table.concat(o_key_pad)
    local i_pad = table.concat(i_key_pad)

    return sha256(o_pad .. sha256(i_pad .. message))
end

-- Pure Lua Base64URL encode/decode
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local b64enc_map = {}
for i = 1, #b64chars do
    b64enc_map[i - 1] = b64chars:sub(i, i)
end

local function base64_encode(data)
    local result = {}
    for i = 1, #data, 3 do
        local b1, b2, b3 = data:byte(i, i + 2)
        local n = (b1 or 0) * 65536 + (b2 or 0) * 256 + (b3 or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        result[#result + 1] = b64enc_map[c1]
        result[#result + 1] = b64enc_map[c2]
        result[#result + 1] = b64enc_map[b3 and c3 or 64] or '='
        result[#result + 1] = b64enc_map[b3 and c4 or 64] or '='
    end
    return table.concat(result)
end

local function base64url_encode(data)
    return base64_encode(data):gsub('+', '-'):gsub('/', '_'):gsub('=', '')
end

local b64decode_map = {}
for i = 1, #b64chars do
    b64decode_map[b64chars:sub(i, i)] = i - 1
end

local function base64url_decode(data)
    data = data:gsub('-', '+'):gsub('_', '/')
    while #data % 4 ~= 0 do data = data .. '=' end

    local bytes = {}
    local n = 0
    local accum = 0

    for c in data:gmatch('.') do
        if c ~= '=' then
            accum = accum * 64 + b64decode_map[c]
            n = n + 1
            if n == 4 then
                table.insert(bytes, string.char(bit.band(bit.rshift(accum, 16), 0xFF)))
                table.insert(bytes, string.char(bit.band(bit.rshift(accum, 8), 0xFF)))
                table.insert(bytes, string.char(bit.band(accum, 0xFF)))
                n, accum = 0, 0
            end
        end
    end

    if n == 3 then
        accum = accum * 64
        table.insert(bytes, string.char(bit.band(bit.rshift(accum, 16), 0xFF)))
        table.insert(bytes, string.char(bit.band(bit.rshift(accum, 8), 0xFF)))
    elseif n == 2 then
        accum = accum * 64 * 64
        table.insert(bytes, string.char(bit.band(bit.rshift(accum, 16), 0xFF)))
    end

    return table.concat(bytes)
end



-- JWT Encode
function M.encode(payload, secret)
    local header = { alg = "HS256", typ = "JWT" }
    local header_json = json.encode(header)
    local payload_json = json.encode(payload)

    local header_b64 = base64url_encode(header_json)
    local payload_b64 = base64url_encode(payload_json)
    local signing_input = header_b64 .. "." .. payload_b64
    local signature = base64url_encode(hmac_sha256(secret, signing_input))

    return signing_input .. "." .. signature
end

-- JWT Decode + optional verification
function M.decode(token, secret, options)
    local parts = {}
    for part in token:gmatch("[^.]+") do
        parts[#parts + 1] = part
    end
    if #parts ~= 3 then
        return nil, { error = "invalid_token", message = "Expected header.payload.signature" }
    end

    local header_b64, payload_b64, signature_b64 = parts[1], parts[2], parts[3]
    local signing_input = header_b64 .. "." .. payload_b64
    local expected_sig = base64url_encode(hmac_sha256(secret, signing_input))

    if expected_sig ~= signature_b64 then
        return nil, { error = "invalid_signature", message = "JWT signature mismatch" }
    end

    local payload_json = base64url_decode(payload_b64)
    local payload = json.decode(payload_json)
    if not payload then
        return nil, { error = "invalid_payload", message = "Could not decode JSON payload" }
    end

    -- Optional claim checks
    if options then
        local now = os.time()

        if options.verify_exp and payload.exp and now >= payload.exp then
            return nil, { error = "token_expired", message = "Token expired" }
        end
        if options.verify_nbf and payload.nbf and now < payload.nbf then
            return nil, { error = "token_not_yet_valid", message = "Token not yet valid" }
        end
        if options.verify_iss and options.issuer and payload.iss ~= options.issuer then
            return nil, { error = "invalid_issuer", message = "Issuer mismatch" }
        end
        if options.verify_aud and options.audience then
            local aud = payload.aud
            if type(aud) == "string" then
                if aud ~= options.audience then
                    return nil, { error = "invalid_audience", message = "Audience mismatch" }
                end
            elseif type(aud) == "table" then
                local found = false
                for _, a in ipairs(aud) do
                    if a == options.audience then found = true break end
                end
                if not found then
                    return nil, { error = "invalid_audience", message = "Audience not found" }
                end
            else
                return nil, { error = "invalid_audience", message = "Invalid audience format" }
            end
        end
        if options.custom_claims then
            for claim, expected in pairs(options.custom_claims) do
                if payload[claim] ~= expected then
                    return nil, { error = "invalid_claim", message = "Mismatch in " .. claim }
                end
            end
        end
    end

    return payload, nil
end

return M
