-- dawn_server.lua

local uws = require("uwebsockets")
local Supervisor = require("runtime.loop")
local json = require('dkjson')
local StreamingMultipartParser = require('multipart_parser')
local uv = require("luv")
local URLParamExtractor = require("utils.query_extractor")
local log_level = require('utils.logger').LogLevel
local TokenCleaner = require("auth.token_cleaner")

local extractor = URLParamExtractor:new()

local function timestamp()
    return os.date("[%Y-%m-%d %H:%M:%S]")
end

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

function TrieNode:new(logger)
    local self = setmetatable({}, { __index = TrieNode })
    self.children = {}
    self.handler = nil
    self.isEndOfPath = false
    self.params = {}
    self.log = logger
    return self
end

function TrieNode:insert(method, route, handler)
    local node = self
    local parts = {}
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
        self.log:log(log_level.WARN, string.format("Route conflict: %s %s is being overridden.", method, route), "DawnServer")
    end
    node.isEndOfPath = true
    node.handler = { method = method, func = handler }
end

function TrieNode:search(method, path)
    local node = self
    local params = {}
    local parts = {}
    local normalizedPath = path:lower()
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
            return nil, {}
        end
    end

    if node and node.isEndOfPath and node.handler and node.handler.method == method then
        return node.handler.func, params
    else
        print("  Handler not found at end of path.")
        return nil, {}
    end
end

local DawnServer = {}
DawnServer.__index = DawnServer

function DawnServer:new(config)
    local self = setmetatable({}, DawnServer)
    self.config = config or {}
    self.logger = config.logger
    self.router = TrieNode:new(self.logger)
    self.middlewares = {}
    self.error_handlers = { middleware = nil, route = {} }
    self.supervisor = Supervisor:new("WebServerSupervisor", "one_for_one", self.logger)
    self.port = config.port or 3000
    self.running = false
    self.multipart_parser_options = config.multipart_parser_options or nil
    self.token_store = config.token_store or {
        store = nil,  cleanup_interval =  1800
    }
    self.route_scopes = {}
    self.routes = {}
    self.request_parsers = {}
    self.shared_state = {
        sessions = {},
        players = {},
        metrics = {},
    }
    -- New member to store static file configurations
    self.static_configs = config.static_configs or {} -- <--- Add this line

    local DawnSockets = require("dawn_sockets")
    self.dawn_sockets_handler = DawnSockets:new(self.supervisor, self.shared_state, self.config.state_management_options or {})
    if self.token_store.store then
        self.logger:log(log_level.INFO, "SETTING UP LOGGER", 'dawn_server', 345)

        local cleaner = TokenCleaner:new("TokenCleaner", self.token_store.cleanup_interval, self.supervisor.scheduler)
        self.supervisor:startChild(cleaner)
    end

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

    table.insert(self.routes[method], {
        path = path,
        handler = handler,
        opts = opts or {}
    })

    self.router:insert(method, path, handler)
end

function DawnServer:scope(prefix, func)
    table.insert(self.route_scopes, prefix)
    func(self)
    table.remove(self.route_scopes)
end

for _, method in ipairs({"get", "post", "put", "delete", "patch", "head", "options"}) do
    DawnServer[method] = function(self, route, handler)
        local scoped_route = table.concat(self.route_scopes, "") .. route
        self:addRoute(method, scoped_route, handler)
    end
end

function DawnServer:ws(route, handler)
    local scoped_route = table.concat(self.route_scopes, "") .. route
    self:addRoute("WS", scoped_route, handler)
end

-- New function to add static file serving configuration
function DawnServer:serveStatic(route_prefix, directory_path) -- <--- Add this function
    assert(type(route_prefix) == "string", "Route prefix for static serving must be a string.")
    assert(type(directory_path) == "string", "Directory path for static serving must be a string.")
    table.insert(self.static_configs, {
        route_prefix = route_prefix,
        directory_path = directory_path
    })
end


local function parseQuery(url)
    return extractor:extract_from_url_like_string(url)
end

function DawnServer:printRoutes()
    self.logger:log(log_level.INFO, "Registered Routes:", "DawnServer")
    local function printNodeRoutes(node, prefix)
        if node.handler then
            self.logger:log(log_level.INFO, "  " .. node.handler.method .. " " .. prefix, "DawnServer")
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
        local byte = str:byte(i)
        if byte < 32 or byte > 126 then
            has_invisible = true
            output = output .. string.format("[%d]", byte)
        end
    end
    if has_invisible then
        print("DEBUG", label .. " contains invisible characters (byte codes): " .. output, "DawnServer")
    else
        print("label doesn't have invisible characters")
    end
end

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
            self.logger:log(log_level.ERROR, "Error in middleware: " .. tostring(err), "DawnServer")
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


function DawnServer:run()
    if self.running then return end
    self.running = true
    uws.create_app()
    local self_ref = self

    local function decodeURIComponent(str)
        str = str:gsub('+', ' ')
        str = str:gsub('%%(%x%x)', function(h)
            return string.char(tonumber(h, 16))
        end)
        return str
    end

    local function handleRequest(_req, res, chunk, is_last)
        local path = _req:getUrl():match("^[^?]*")
        if path ~= "/" and path:sub(-1) == "/" then
            path = path:sub(1, -2)
        end
        local method = extractHttpMethod(_req.method)

        -- Important: Before router.search, check if the request should be handled by static serving
        -- This logic needs to be outside the route handler loop, handled by uWS itself
        -- The C++ shim will handle this by registering the wildcard route `/static/*`

        local handler_info, params = self_ref.router:search(method, path)
        local req = {
            _raw = _req,
            params = params,
            method = method
        }
        self_ref.logger:log(log_level.DEBUG, string.format("Method: %s, Path: %s, Handler Found: %s, Params: %s", method, path, tostring(handler_info ~= nil), json.encode(params)), "DawnServer")

        if not handleCORS(req, res) then return end

        if handler_info then
            local handler = handler_info
            local query_params = parseQuery(_req.url)
            if executeMiddleware(self_ref, req, res, path, self_ref.middlewares, 1) then
                method = string.upper(method)
                if method == "WS" then
                    res:writeStatus(404):send("Not Found")
                elseif method == "GET" or method == "DELETE" or method == "HEAD" or method == "OPTIONS" then
                    local ok, err = pcall(function()
                        handler(req, res, query_params)
                    end)
                    if not ok then
                        self_ref.logger:log(log_level.ERROR, string.format("Error in route handler for %s %s: %s", method, path, tostring(err)), "DawnServer")
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
                    local multipart_marker = "multipart/form-data"

                    if (content_type:sub(1, #multipart_marker) == multipart_marker) then
                        req.form_data_parser = req.form_data_parser or StreamingMultipartParser.new(content_type, function(part)
                            req.form_data = req.form_data or {}
                            req.form_data[part.name] = part.is_file and part or part.body
                        end, self_ref.multipart_parser_options)

                        req.form_data_parser:feed(chunk or "")

                        if is_last then
                            local ok, err = pcall(handler, req, res, req.form_data)
                            if not ok then
                                self_ref.logger:log(log_level.ERROR, string.format("Error in multipart route handler for %s %s: %s", method, path, tostring(err)), "DawnServer")
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
                        if chunk then
                            req.body = (req.body or "") .. chunk
                        end
                        if is_last then
                            local parsed_body = nil
                            local parse_error = nil

                            if content_type:find("application/json") then
                                parsed_body = json.decode(req.body)
                                if not parsed_body then
                                    parse_error = "Failed to parse JSON body"
                                    self_ref.logger:log(log_level.ERROR, string.format("Error parsing JSON body for %s %s: %s", method, path, parse_error), "DawnServer")
                                end
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
                                self_ref.logger:log(log_level.ERROR, string.format("Error in route handler for %s %s: %s", method, path, tostring(err)), "DawnServer")
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
            -- If no specific Lua route handler is found, the C++ `serve_static` might still catch it.
            -- If it's not caught by `serve_static`, then it's a true 404.
            res:writeStatus(404):send("Not Found")
        end
    end

    local function registerRouteHandlers(node, prefix)
        if node.handler then
            local method = node.handler.method:lower()
            local routePath = prefix
            if method == "ws" then
                uws.ws(routePath, function(ws, event, message, code, reason)
                    if event == "open" then
                        local fake_req = {
                            method = "WS",
                            url = routePath,
                            headers = {}
                        }
                        local fake_res = {}
                        fake_res.writeHeader = function() return fake_res end
                        fake_res.writeStatus = function() return fake_res end
                        fake_res.send = function(...)
                            print( "[WS Middleware] Blocking upgrade:", ..., " : dawn_server")
                            ws:close()
                        end
                        local ok = executeMiddleware(self_ref, fake_req, fake_res, routePath, self_ref.middlewares, 1)
                        if ok then
                            self_ref.dawn_sockets_handler:handle_open( ws, message)
                        else
                            print("[WS] Connection rejected by middleware:", routePath)
                        end
                    elseif event == "message" then
                        self_ref.dawn_sockets_handler:handle_message( ws, message, code)
                    elseif event == "close" then
                        self_ref.dawn_sockets_handler:handle_close( ws, code, reason)
                    end
                end)
            elseif method == "get" or method == "delete" or method == "head" or method == "options" then
                uws[method](routePath, handleRequest)
            elseif method == "post" or method == "put" or method == "patch" then
                uws[method](routePath, handleRequest)
            end
        end
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

    -- Register static file serving using the new uws.serve_static function
    for _, config in ipairs(self_ref.static_configs) do
        self_ref.logger:log(log_level.INFO, string.format("Serving static files from '%s' at route '%s'", config.directory_path, config.route_prefix), "DawnServer")
        uws.serve_static(config.route_prefix, config.directory_path) -- <--- Call the new C++ function here
    end

    self:printRoutes()
    uws.listen(self.port, function(token)
        if token then
            self.logger:log(log_level.INFO, "Server started on port " .. self.port, "DawnServer")
        else
            self.logger:log(log_level.ERROR, "Failed to start server on port " .. self.port, "DawnServer")
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
            self.logger:log(log_level.INFO, "Dawn Server connection started".. self.port, "DawnServer")
            self:run()
            local ok, err = pcall(uws.run)
            if not ok then
                self.logger:log(log_level.ERROR, "Fatal server error: " .. tostring(err), "DawnServer")
            end
            return true
        end,
        stop = function()
            self.logger:log(log_level.INFO, "Dawn Server connection stopped", "DawnServer")
            setupGracefulShutdown(self)
            self.logger:Shutdown()
            return true
        end,
        restart = function()
            self.logger:log(log_level.WARN, "Dawn Server connection restarted on port ".. self.port, "DawnServer")
            return true
        end,
        restart_policy = "transient",
        restart_count = 5,
        backoff = 5000
    }
    self.supervisor:startChild(dawnProcessChild)
end
return DawnServer