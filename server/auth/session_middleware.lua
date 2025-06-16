local cjson = require("dkjson")
local uuid = require("utils.uuid")

local function parse_cookies(cookie_header)
    local cookies = {}
    for pair in string.gmatch(cookie_header or "", "[^;]+") do
        local key, val = pair:match("^%s*(.-)%s*=%s*(.-)%s*$")
        if key and val then cookies[key] = val end
    end
    return cookies
end

return function(options)
    options = options or {}
    local cookie_name = options.cookie_name or "dawn_sid"
    local session_store = options.store or {}

    return function(req, res, next)
        local cookies = parse_cookies(req._raw:getHeader("cookie"))
        local sid = cookies[cookie_name]

        if not sid or not session_store[sid] then
            sid = uuid()
            session_store[sid] = {}
            local cookie_flags = "HttpOnly; Path=/; SameSite=Lax"
            if options.secure then
                cookie_flags = cookie_flags .. "; Secure"
            end
            res:writeHeader("Set-Cookie", string.format("%s=%s; %s", cookie_name, sid, cookie_flags))
        end

        req.session_id = sid
        req.session = session_store[sid]

        res.saveSession = function()
            session_store[sid] = req.session
        end

        next()
    end
end
