---
-- Controller Base Class
--
-- Provides a lightweight base for HTTP controllers with support for:
-- - Request/response context injection
-- - Lifecycle hooks (before/after/authorize)
-- - Action dispatching with error handling
-- - JSON and HTML rendering
-- - Request validation and redirection
--
-- @module Controller
-- @author
-- @license MIT
-- @see lustache_renderer
--

local viewEngine = require("layout.renderer.lustache_renderer")
local cjson = require("dkjson")

local Controller = {}

---
-- Creates a new base Controller instance.
-- @param data table? Optional initial object to use as base.
-- @return Controller
function Controller:new(data)
    local instance = data or {}
    setmetatable(instance, { __index = self })
    return instance
end

---
-- Extends the Controller class to create a new concrete controller.
-- Sets up request/response context and optional view engine.
-- @return Controller A new controller instance.
function Controller:extends()
    local new_controller = {}
    setmetatable(new_controller, { __index = self })
    new_controller.viewEngine = viewEngine
    new_controller.req = nil
    new_controller.res = nil

    ---
    -- Called when the controller is created. Override to initialize state.
    function new_controller:init() end

    if new_controller.init then new_controller:init() end

    ---
    -- Sets the HTTP request and response context.
    -- @param req table Request object
    -- @param res table Response object
    function new_controller:setContext(req, res)
        self.req = req
        self.res = res
    end

    ---
    -- Dispatches a controller action with hooks and error handling.
    -- @param action string Action method name
    -- @param ... any Additional arguments to pass to the action
    function new_controller:dispatch(action, ...)
        local action_args = ...

        print("Dispatching action: " .. action)

        local ok, err = pcall(function()
            if self.beforeAction then self:beforeAction(action, action_args) end
            if self.authorize then self:authorize(action, action_args) end

            assert(self[action], "Action '" .. action .. "' not found in controller")
            local result = self[action](self, action_args)

            if self.afterAction then self:afterAction(action, action_args) end

            if result ~= nil then
                self:respond(result)
            end
        end)

        if not ok then
            self:handleError(err)
        end
    end

    ---
    -- Hook: Called before any action.
    -- Override to apply request preconditions or logging.
    -- @param action string Action name
    -- @param ... any Additional arguments
    function new_controller:beforeAction(action, ...) end

    ---
    -- Hook: Called after any action.
    -- Override for audit/logging or cleanup.
    -- @param action string Action name
    -- @param ... any Additional arguments
    function new_controller:afterAction(action, ...) end

    ---
    -- Hook: Authorization logic before executing an action.
    -- Override to apply role-based or permission logic.
    -- @param action string Action name
    -- @param ... any Additional arguments
    function new_controller:authorize(action, ...)
        if self.req.user and self.req.user.role == "banned" then
            error({ status = 403, message = "Access denied" })
        end
    end

    ---
    -- Handles errors thrown during dispatch.
    -- @param err any Error object or message
    function new_controller:handleError(err)
        local status = 500
        local errorMessage = "Internal Server Error"
        local detailedMessage = tostring(err)

        if type(err) == "table" and err.status and err.message then
            status = err.status
            errorMessage = err.message
            detailedMessage = err.message
        end

        self.res:writeStatus(status)
        self.res:writeHeader("Content-Type", "application/json")
        self.res:send(cjson.encode({
            error = errorMessage,
            message = detailedMessage
        }))
    end

    ---
    -- Validates incoming JSON payload against a rule schema.
    -- Supports `required`, `number`, `email`, `min`, `regex` rules.
    -- @param rules table Validation rule map
    -- @return table Validated input data
    function new_controller:validate(rules)
        local data = self.req:json() or {}
        local errors = {}

        local function isEmail(str)
            return type(str) == "string" and str:match("^[%w._%%+-]+@[%w.-]+%.[a-zA-Z]{2,}$")
        end

        for field, ruleList in pairs(rules) do
            local value = data[field]

            for _, rule in ipairs(ruleList) do
                if rule == "required" and (value == nil or value == '') then
                    table.insert(errors, field .. " is required")
                elseif rule == "number" and type(value) ~= "number" then
                    table.insert(errors, field .. " must be a number")
                elseif rule == "email" and not isEmail(value) then
                    table.insert(errors, field .. " must be a valid email")
                elseif type(rule) == "table" and rule.min and #tostring(value) < rule.min then
                    table.insert(errors, field .. " must be at least " .. rule.min .. " characters")
                elseif type(rule) == "table" and rule.regex then
                    if not string.match(tostring(value), rule.regex) then
                        table.insert(errors, field .. " format is invalid")
                    end
                end
            end
        end

        if #errors > 0 then
            self.res:writeStatus(422)
            self.res:writeHeader("Content-Type", "application/json")
            self.res:send(cjson.encode({ errors = errors }))
            error("Validation failed: " .. cjson.encode(errors))
        end

        return data
    end

    ---
    -- Transforms the output data for responses.
    -- Override to customize structure.
    -- @param data any Response data
    -- @return table Transformed response
    function new_controller:transformResponse(data)
        return { status = "success", data = data }
    end

    ---
    -- Sends a JSON response with optional transformation.
    -- @param data any Raw or transformed data
    function new_controller:respond(data)
        local transformed = self:transformResponse(data)
        self:json(transformed)
    end

    ---
    -- Sends a JSON response with optional status code.
    -- @param data table Response body
    -- @param status number? Optional HTTP status code (default: 200)
    function new_controller:json(data, status)
        status = status or 200
        self.res:writeStatus(status)
        self.res:writeHeader("Content-Type", "application/json")
        self.res:send(cjson.encode(data))
    end

    ---
    -- Renders an HTML view and sends it to the client.
    -- @param viewName string View template name
    -- @param data table? Data to pass to the view
    function new_controller:render(output)
        if not self.viewEngine or type(self.viewEngine.render) ~= "function" then
            error("View engine not provided or does not have a 'render' method for controller:render")
        end
        self.res:send(output)
    end

    ---
    -- Redirects the client to a different URL.
    -- @param url string Target URL
    -- @param status number? Optional HTTP status code (default: 302)
    function new_controller:redirect(url, status)
        status = status or 302
        self.res:writestatus(status)
        self.res:writeHeader("Location", url)
        self.res:send("")
    end

    return new_controller
end

return Controller
