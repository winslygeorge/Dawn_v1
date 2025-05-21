#!/usr/bin/env luajit
package.path = package.path .. ";../?.lua;../utils/?.lua"

local jwt = require("server.auth.purejwt")
local json = require("cjson.safe")

local args = {...}
local command = args[1]

if command == "generate" then
    local payload = {
        sub = args[2] or "anonymous",
        role = args[3] or "user",
        iat = os.time(),
        exp = os.time() + (tonumber(args[4]) or 3600)
    }
    local secret = args[5] or "secret"
    print(jwt.encode(payload, secret))

elseif command == "inspect" then
    local token = args[2]
    local secret = args[3] or "secret"
    local decoded, err = jwt.decode(token, secret)
    if decoded then
        print("✅ Valid JWT:")
        print(json.encode(decoded, { indent = true }))
    else
        print("❌ Invalid:", err.message)
    end
else
    print([[
Usage:
  jwtcli.lua generate <sub> <role> <exp_seconds> <secret>
  jwtcli.lua inspect <token> <secret>
]])
end
