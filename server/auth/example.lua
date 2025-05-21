-- example.lua

local jwt = require("purejwt")

-- Secret key used to sign/verify the token
local secret = "my_super_secret_key"

-- Sample payload
local payload = {
    sub = "user_42",
    role = "admin",
    iss = "dawnserver",
    aud = "test_client",
    iat = os.time(),
    exp = os.time() + 3600 -- Expires in 1 hour
}

-- 🔐 Encode the token
local token = jwt.encode(payload, secret)
print("🔐 JWT Token:")
print(token)

-- Wait a moment (simulate verification later)
print("\n🔍 Verifying token...\n")

-- 🔎 Decode + Verify the token
local decoded, err = jwt.decode(token, secret, {
    verify_exp = true,
    verify_iss = true,
    issuer = "dawnserver",
    verify_aud = true,
    audience = "test_client",
    custom_claims = {
        role = "admin"
    }
})

if decoded then
    print("✅ Token is valid. Decoded payload:")
    for k, v in pairs(decoded) do
        print("  " .. k .. ":", v)
    end
else
    print("❌ Token verification failed:")
    for k, v in pairs(err) do
        print("  " .. k .. ":", v)
    end
end
