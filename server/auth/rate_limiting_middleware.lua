local rate_limit_store = {}

return  function ()
    return function (req, res, next)
    local ip = req._raw:getRemoteAddressAsText()
    local now = os.time()
    local window = 10 -- seconds
    local max_requests = 5

    local record = rate_limit_store[ip] or { count = 0, last = now }
    if now - record.last > window then
        record = { count = 1, last = now }
    else
        record.count = record.count + 1
    end

    if record.count > max_requests then
        print("too many requests")
        res:writeStatus(429):send("Too Many Requests")
        return
    end

    rate_limit_store[ip] = record
    next()
end

end
