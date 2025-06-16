-- auth/jwt_protect.lua

local jwt = require("auth.purejwt")
local cjson = require("dkjson")

return function(options)
    assert(options and options.secret, "JWT middleware requires a 'secret'")

    return function(req, res, next)
        local auth_header = ""
        if req._raw then 
         auth_header = req._raw:getHeader("authorization") or ""
        end
        local token = auth_header:match("Bearer%s+(.+)")

        if not token then
            return res:writeStatus(401):send(cjson.encode({ error = "Missing token" }))
        end

        local decoded, err = jwt.decode(token, options.secret, {
            verify_exp = true,
            verify_iss = options.issuer,
            verify_aud = options.audience,
            custom_claims = options.custom_claims
        })

        if not decoded then
            return res:writeStatus(401):send(cjson.encode({ error = err.message or "Invalid token" }))
        end

        if decoded.type and decoded.type ~= "access" then
            return res:writeStatus(401):send(cjson.encode({ error = "Not an access token" }))
        end

        req.jwt = decoded
        next()
    end
end
