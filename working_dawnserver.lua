package.path = package.path .. ";../?.lua;../utils/?.lua"
local uws = require("uwebsockets")
local Supervisor = require("runtime.loop")
local json = require('cjson')
local StreamingMultipartParser = require('multipart_parser') -- You are requiring this but not using it in the provided code
local uv = require("luv")
local URLParamExtractor = require("utils.query_extractor") -- Replace "your_module_name"
local tprint = require('tprint')

-- Create an instance of the class
local extractor = URLParamExtractor:new()

-- Initialize the server with configuration (optional)
local function timestamp()
    return os.date("[%Y-%m-%d %H:%M:%S]")
end

local Logger = {
    log = function(level, message, name)
        print(string.format("%s [%s] %s", timestamp(), level, name or "Logger"), message)
    end
}

local function extractHttpMethod(request_str)
    -- Extract the first line of the request
    local first_line = request_str:match("([^\r\n]+)")
    if first_line then
        -- Match the method (first word before a space)
        local method = first_line:match("^(%S+)")
        if method then
            return method:lower() -- return it in lowercase
        end
    end
    return "" -- if something fails
end


local TrieNode = {}

function TrieNode:new()
    local self = setmetatable({}, { __index = TrieNode })
    self.children = {}
    self.handler = nil
    self.isEndOfPath = false
    self.params = {}
    return self
end

function TrieNode:insert(method, route, handler)
    local node = self
    local parts = {}
    -- Normalize route path to lowercase
    local normalizedRoute = route:lower()
    for part in normalizedRoute:gmatch("([^/]+)") do
        table.insert(parts, part)
    end

    for i, part in ipairs(parts) do
        local paramName = nil
        if part:sub(1, 1) == ":" then
            paramName = part:sub(2)
            part = ":"
        elseif part == "*" then
            part = "*"
        end

        if not node.children[part] then
            node.children[part] = TrieNode:new()
        end
        node = node.children[part]
        if paramName then
            node.params[i] = paramName
        end
    end

    if node.isEndOfPath and node.handler then
        Logger.log("WARN", string.format("Route conflict: %s %s is being overridden.", method, route), "DawnServer")
    end
    node.isEndOfPath = true
    node.handler = { method = method, func = handler }
end

function TrieNode:search(method, path)
    local node = self
    local params = {}
    local parts = {}
    local normalizedPath = path:lower()
    print("Searching for method:", method, "normalizedPath:", normalizedPath) -- Added
    for part in normalizedPath:gmatch("([^/]+)") do
        table.insert(parts, part)
    end

    for i, part in ipairs(parts) do
        local child = node.children[part]
        if not child then
            child = node.children[":"]
            if not child then
                child = node.children["*"]
                if child then
                    params.splat = table.concat(parts, "/", i)
                    return child.handler and child.handler.func, params
                else
                    return nil, {}
                end
            else
                local paramName = child.params[i]
                if paramName then
                    params[paramName] = part
                end
            end
        end
        node = child
        if not node then
            print("  No child found for part:", part) -- Added
            return nil, {}
        end
    end

    if node and node.isEndOfPath and node.handler and node.handler.method == method then
        print("  Handler found!") -- Added
        return node.handler.func, params
    else
        print("  Handler not found at end of path.") -- Added
        return nil, {}
    end
end

local DawnServer = {}
DawnServer.__index = DawnServer

function DawnServer:new(config)
    local self = setmetatable({}, DawnServer)
    self.config = config or {}
    self.router = TrieNode:new()  -- IMPORTANT LINE
    self.middlewares = {}
    self.logger = Logger
    self.error_handlers = {
        middleware = nil,
        route = {}
    }
    self.supervisor = Supervisor:new("WebServerSupervisor", "one_for_one", self.logger)
    self.port = config.port or 3000
    self.running = false
    self.multipart_parser_options = config.multipart_parser_options or nil
    self.route_scopes = {}
    self.routes = {} -- this is critical
    self.request_parsers = {}
    -- To store scoped routes
    return self
end

function DawnServer:on_error(error_type, handler)
    assert(error_type == "middleware" or error_type == "route", "Invalid error handler type. Must be 'middleware' or 'route'.")
    assert(type(handler) == "function", "Error handler must be a function.")
    self.error_handlers[error_type] = handler
end

function DawnServer:on_route_error(route, handler)
    assert(type(route) == "string", "Route for error handler must be a string.")
    assert(type(handler) == "function", "Route error handler must be a function.")
    self.error_handlers.route[route:lower()] = handler
end


function DawnServer:use(middleware, route)
    assert(type(middleware) == "function", "Middleware must be a function")
    table.insert(self.middlewares, {
        func = middleware,
        route = route,
        global = route == nil
    })
end

function DawnServer:addRoute(method, path, handler, opts)
    if not self.routes[method] then
        self.routes[method] = {}
    end

    -- Register in flat list
    table.insert(self.routes[method], {
        path = path,
        handler = handler,
        opts = opts or {}
    })

    -- ✅ Register into trie router (THIS IS WHAT YOU NEED)
    self.router:insert(method, path, handler)
end


function DawnServer:scope(prefix, func)
    table.insert(self.route_scopes, prefix)
    func(self)
    table.remove(self.route_scopes)  -- Reset after scope ends
end

for _, method in ipairs({"get", "post", "put", "delete", "patch", "head", "options"}) do
    DawnServer[method] = function(self, route, handler)
        -- Prepend the current scope prefix to the route
        local scoped_route = table.concat(self.route_scopes, "") .. route
        self:addRoute(method, scoped_route, handler)
    end
end

function DawnServer:ws(route, handler)
    -- Prepend the current scope prefix to the route
    local scoped_route = table.concat(self.route_scopes, "") .. route
    self:addRoute("WS", scoped_route, handler)
end

-- Query Parsing
local function parseQuery(url)
    return extractor:extract_from_url_like_string(url)
end

-- Route Debug Printer
function DawnServer:printRoutes()
    self.logger:log("INFO", "Registered Routes:", "DawnServer")
    local function printNodeRoutes(node, prefix)
        if node.handler then
            self.logger:log("INFO", "  " .. node.handler.method .. " " .. prefix, "DawnServer")
        end
        for path, child in pairs(node.children) do
            local slashCount = select(2, prefix:gsub("/", ""))
            local param = child.params[slashCount + 1] or ""
            local segment = (path == ":" and "/:" .. param) or (path == "*" and "/*") or ("/" .. path)
            printNodeRoutes(child, prefix .. segment)
        end
    end
    printNodeRoutes(self.router, "")
end

local function log_invisible_chars(str, label)
    local has_invisible = false
    local output = ""
    for i = 1, #str do
        local byte = str:byte(i) -- More efficient way to get byte
        if byte < 32 or byte > 126 then
            has_invisible = true
            output = output .. string.format("[%d]", byte)
        end
    end
    if has_invisible then
        print("DEBUG", label .. " contains invisible characters (byte codes): " .. output, "DawnServer")
        else
          print("label doens't have invisoblle characters")
    end
end

-- CORS Preflight Handling
local function handleCORS(req, res)
    if req.method == "OPTIONS" then
        res:writeHeader("Access-Control-Allow-Origin", "*")
        res:writeHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS")
        res:writeHeader("Access-Control-Allow-Headers", "Content-Type, Authorization")
        res:writeHeader("Access-Control-Max-Age", "86400")
        res:writeStatus(200):send()
        return false
    end
    return true
end

-- Graceful Shutdown
local function setupGracefulShutdown(self)
    local sigint = uv.new_signal()
    uv.signal_start(sigint, "sigint", function()
        self:stop()
        os.exit(0)
    end)
    local sigterm = uv.new_signal()
    uv.signal_start(sigterm, "sigterm", function()
        self:stop()
        os.exit(0)
    end)
end

local function executeMiddleware(self, req, res, route, middlewares, index)
    index = index or 1
    if index > #middlewares then return true end
    local mw = middlewares[index]
    local matchesScope = mw.global or (mw.route and route:sub(1, #mw.route) == mw.route)
    if matchesScope then
        local nextCalled = false
        local function next()
            nextCalled = true
            return executeMiddleware(self, req, res, route, middlewares, index + 1)
        end

        local ok, err = pcall(function()
            mw.func(req, res, next)
        end)

        if not ok then
            Logger.log("ERROR", "Error in middleware: " .. tostring(err), "DawnServer")
            if type(self.error_handlers.middleware) == "function" then
                self.error_handlers.middleware(req, res, err)
            else
                res:writeHeader("Content-Type", "text/plain")
                    :writeStatus(500)
                    :send("Internal Server Error")
            end
            return false
        end

        if not nextCalled then return false end
        return true
    else
        return executeMiddleware(self, req, res, route, middlewares, index + 1)
    end
end

-- In your DawnServer module (at the top)

function DawnServer:run()
    if self.running then return end
    self.running = true
    uws.create_app()
    local self_ref = self -- Capture self for use in callbacks

    local function decodeURIComponent(str)
        str = str:gsub('+', ' ')
        str = str:gsub('%%(%x%x)', function(h)
            return string.char(tonumber(h, 16))
        end)
        return str
    end

    -- Handle routes and CORS
    local function handleRequest(_req, res, chunk, is_last)
        local path = _req:getUrl():match("^[^?]*")
        -- Normalize path to remove trailing slash
        if path ~= "/" and path:sub(-1) == "/" then
            path = path:sub(1, -2)
        end
        local method = extractHttpMethod(_req.method)
        -- print("method : ", method, " path : ", path, " chunk: ", chunk, " is_last: ", is_last)
        local handler_info, params = self_ref.router:search(method, path)
        local req = { -- Create a wrapper table
            _raw = _req, -- Store the original uwebsockets req
            params = params,
            method = method -- Add the method to the request object
        }
        self_ref.logger:log("DEBUG", string.format("Method: %s, Path: %s, Handler Found: %s, Params: %s", method, path, tostring(handler_info ~= nil), json.encode(params)), "DawnServer")

        if not handleCORS(req, res) then return end -- Pass the wrapper req

        if handler_info then
            local handler = handler_info -- handler_info is already the function
            local query_params = parseQuery(_req.url)
            -- Call executeMiddleware as a method on 'self'
            if executeMiddleware(self_ref, req, res, path, self_ref.middlewares, 1) then
                method = string.upper(method)
                if method == "WS" then
                    -- WebSocket upgrade logic should be handled by the ws route
                    res:writeStatus(404):send("Not Found")
                elseif method == "GET" or method == "DELETE" or method == "HEAD" or method == "OPTIONS" then
                    local ok, err = pcall(function()
                        handler(req, res, query_params) -- Pass the wrapper req
                    end)
                    if not ok then
                        self_ref.logger:log("ERROR", string.format("Error in route handler for %s %s: %s", method, path, tostring(err)), "DawnServer")
                        local route_error_handler = self_ref.error_handlers.route[path:lower()]
                        if type(route_error_handler) == "function" then
                            route_error_handler(req, res, err)
                        else
                            res:writeHeader("Content-Type", "text/plain")
                                :writeStatus(500)
                                :send("Internal Server Error")
                        end
                    end
                elseif method == "POST" or method == "PUT" or method == "PATCH" then
                    local content_type = (_req:getHeader("content-type") or ""):lower()
                    -- local content_type = (_req:getHeader("content-type") or ""):lower()
                    -- print("check content type? : ", content_type)
                    local multipart_marker = "multipart/form-data"
                    -- print("direct comparison (start): ", (content_type:sub(1, #multipart_marker) == multipart_marker))
                    -- print("content type is multipart? ", content_type:match(multipart_marker))
                    -- print("check content type? : ", content_type )
                    

                    if (content_type:sub(1, #multipart_marker) == multipart_marker) then

                        req.form_data_parser = req.form_data_parser or StreamingMultipartParser.new(content_type, function(part)
                            req.form_data = req.form_data or {}
                            req.form_data[part.name] = part.is_file and part or part.body
                        end, self_ref.multipart_parser_options) -- Use configured options

                        req.form_data_parser:feed(chunk or "") -- Feed the current chunk

                        if is_last then
                            -- All chunks have been processed, call the handler with the parsed form data
                            print("passed data : ", req.form_data)
                            local ok, err = pcall(handler, req, res, req.form_data)
                            if not ok then
                                self_ref.logger:log("ERROR", string.format("Error in multipart route handler for %s %s: %s", method, path, tostring(err)), "DawnServer")
                                local route_error_handler = self_ref.error_handlers.route[path:lower()]
                                if type(route_error_handler) == "function" then
                                    route_error_handler(req, res, err)
                                else
                                    res:writeHeader("Content-Type", "text/plain")
                                        :writeStatus(500)
                                        :send("Internal Server Error")
                                end
                            end
                        end
                    else
                        -- Handle other content types (like application/json or url-encoded) as before
                        if chunk then
                            req.body = (req.body or "") .. chunk
                        end
                        if is_last then
                            local parsed_body = nil
                            local parse_error = nil

                            if content_type:find("application/json") then
                                parsed_body = json.decode(req.body)
                            elseif content_type:find("application/x-www-form-urlencoded") then
                                parsed_body = {}
                                for key, value in (req.body or ""):gmatch("([^&=]+)=([^&=]*)") do
                                    local decoded_key = decodeURIComponent(key)
                                    local decoded_value = decodeURIComponent(value)
                                    parsed_body[decoded_key] = decoded_value
                                end
                            else
                                parsed_body = req.body
                            end

                            local ok, err = pcall(handler, req, res, parsed_body, parse_error)
                            if not ok then
                                self_ref.logger:log("ERROR", string.format("Error in route handler for %s %s: %s", method, path, tostring(err)), "DawnServer")
                                local route_error_handler = self_ref.error_handlers.route[path:lower()]
                                if type(route_error_handler) == "function" then
                                    route_error_handler(req, res, err)
                                else
                                    res:writeHeader("Content-Type", "text/plain")
                                        :writeStatus(500)
                                        :send("Internal Server Error")
                                end
                            end
                        end
                    end
                end
            end
        else
            res:writeStatus(404):send("Not Found")
        end
    end

    -- Register handlers for each route based on the method
    local function registerRouteHandlers(node, prefix)
        if node.handler then
            local method = node.handler.method:lower()
            local routePath = prefix
            if method == "ws" then
                uws.ws(routePath, function(ws)
                    ws:onOpen(function()
                        local ok, err = pcall(node.handler.func, ws, "open")
                        if not ok then
                            self_ref.logger:log("ERROR", string.format("Error in WebSocket open handler for %s: %s", routePath, tostring(err)), "DawnServer")
                            ws:close(1011, "Internal Server Error")
                        end
                    end)
                    ws:onMessage(function(message, opcode)
                        local ok, err = pcall(node.handler.func, ws, "message", message, opcode)
                        if not ok then
                            self_ref.logger:log("ERROR", string.format("Error in WebSocket message handler for %s: %s", routePath, tostring(err)), "DawnServer")
                            ws:send("Error processing message.")
                        end
                    end)
                    ws:onClose(function(code, message)
                        local ok, err = pcall(node.handler.func, ws, "close", code, message)
                        if not ok then
                            self_ref.logger:log("ERROR", string.format("Error in WebSocket close handler for %s: %s", routePath, tostring(err)), "DawnServer")
                        end
                    end)
                end)
            elseif method == "get" or method == "delete" or method == "head" or method == "options" then
                uws[method](routePath, handleRequest) -- Now handleRequest will have access to 'self' indirectly
            elseif method == "post" or method == "put" or method == "patch" then
                uws[method](routePath, handleRequest)
            end
        end
        --  local slashCount = select(2, prefix:gsub("/", ""))

        for path, child in pairs(node.children) do
            local slashCount = select(2, prefix:gsub("/", ""))
            local param = child.params[slashCount + 1] or ""
            local nextPrefix = prefix .. (
                path == ":" and "/:" .. param or
                (path == "*" and "/*" or "/" .. path)
            )
            registerRouteHandlers(child, nextPrefix)
        end

    end
    registerRouteHandlers(self.router, "")

    self:printRoutes()
    uws.listen(self.port, function(token)
        if token then
            self.logger:log("INFO", "Server started on port " .. self.port, "DawnServer")
        else
            self.logger:log("ERROR", "Failed to start server on port " .. self.port, "DawnServer")
        end
    end)

end

function DawnServer:stop()
    if self.running then
        self.running = false
        uv.stop()
    end
end

function DawnServer:start()

    local dawnProcessChild = {
        name = "DawnServer_Supervisor",
        start = function()
            self.logger:log("INFO", "Dawn Server connection  started".. self.port, "DawnServer")
            self:run()
            local ok, err = pcall(uws.run) -- uws.run doesn't take arguments
            if not ok then
                self.logger:log("ERROR", "Fatal server error: " .. tostring(err), "DawnServer")
            end
            return true
        end,
        stop = function()
            self.logger:log("INFO", "Dawn Server connection stopped", "DawnServer")
            setupGracefulShutdown(self)
            return true
        end,
        restart = function()
            self.logger:log("WARN", "Dawn Server connection restarted on port ".. self.port, "DawnServer")
            return true
        end,
        restart_policy = "transient",
        restart_count = 5,
        backoff = 5000
    }
    --  self.supervisor:addChild(dawnProcessChild)
    self.supervisor:startChild(dawnProcessChild)
end
return DawnServer