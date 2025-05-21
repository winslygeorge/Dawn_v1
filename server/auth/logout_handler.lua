-- auth/logout_handler.lua

local jwt = require("auth.purejwt")
local store = require("auth.token_store")

return function(options)
    assert(options and options.secret, "Logout handler requires a 'secret'")

    return function(req, res)
        local auth = req._raw:getHeader("authorization") or ""
        local token = auth:match("Bearer%s+(.+)")
        if not token then
            return res:writeStatus(401):send("Missing token")
        end

        local decoded = jwt.decode(token, options.secret)
        if decoded and decoded.sub then
            store.revoke_refresh_token(decoded.sub)
        end

        res:send("Logged out")
    end
end
