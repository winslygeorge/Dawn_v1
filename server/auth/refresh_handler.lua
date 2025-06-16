-- auth/refresh_handler.lua

local jwt = require("auth.purejwt")
local store = require("auth.token_store")
local cjson = require("dkjson")

return function(options)
    assert(options and options.secret, "Refresh handler requires a 'secret'")

    return function(req, res)
        local auth = req._raw:getHeader("authorization") or ""
        local token = auth:match("Bearer%s+(.+)")
        if not token then
            return res:writeStatus(401):send("Missing refresh token")
        end

        local decoded, err = jwt.decode(token, options.secret, { verify_exp = true })
        if not decoded or decoded.type ~= "refresh" then
            return res:writeStatus(401):send("Invalid refresh token")
        end

        local user_id = decoded.sub
        if not store.verify(user_id, token) then
            return res:writeStatus(401):send("Refresh token has been revoked")
        end

        -- Issue new tokens
        local now = os.time()
        local access_token = jwt.encode({
            sub = user_id,
            role = decoded.role,
            type = "access",
            iat = now,
            exp = now + (options.access_exp or 60)
        }, options.secret)

        local refresh_token = jwt.encode({
            sub = user_id,
            type = "refresh",
            iat = now,
            exp = now + (options.refresh_exp or 86400)
        }, options.secret)

        store.save_refresh_token(user_id, refresh_token)

        res:writeHeader("Content-Type", "application/json")
        res:send(cjson.encode({
            access_token = access_token,
            refresh_token = refresh_token
        }))
    end
end
