--- @module layout.Model
--- Base class for all layout renderer models with controller integration and Lustache rendering.
--- Supports automatic lifecycle execution, named hooks, coroutine compatibility, and error logging.

local Model = {}

--- Creates a new instance of a model.
--- @param data table? Optional table of initial instance properties.
--- @return table The new model instance.
function Model:new(data)
    local instance = data or {}
    setmetatable(instance, { __index = self })
    return instance
end

--- Internal helper to safely run a hook (supports coroutines, logs errors).
--- @param name string Hook name (e.g., "before_render_hook")
--- @param callback function Hook function to run
--- @param self table The model instance
local function run_hook(name, callback, self)
    if type(callback) ~= "function" then return end

    local function runner()
        local ok, err = pcall(function()
            local co = coroutine.create(callback)
            local resumed, msg = coroutine.resume(co, self)
            if not resumed then error(msg) end
        end)
        if not ok then
            local log = self._log or print
            log(string.format("[Model] Error in %s: %s", name, err))
        end
    end

    runner()
end

--- Extends the base model to create a new class with controller and lifecycle hooks.
--- @param server_obj table Server object containing `.req` and `.res`.
--- @param controller table Controller instance to use for logic dispatching.
--- @param props table? Optional model-specific properties.
--- @return table A new extended model class.
function Model:extend(server_obj, controller, props)
    local new_model = {}
    setmetatable(new_model, { __index = self })

    new_model._controller = controller
    new_model._props = props or {}
    new_model._req = server_obj.req or nil
    new_model._res = server_obj.res or nil
    new_model._log = print -- default logger

    --- Hook for setup before render (can yield).
    --- @type fun(self:table)?
    new_model.before_render_hook = nil

    --- Hook after rendering (can yield).
    --- @type fun(self:table)?
    new_model.after_render_hook = nil

    --- Cleanup hook (can yield).
    --- @type fun(self:table)?
    new_model.on_destroy_hook = nil

    --- Hook to inject logic before render (calls `before_render_hook` internally).
    function new_model:before_render()
        run_hook("before_render_hook", self.before_render_hook, self)
    end

    --- Rendering logic via controller dispatch.
    function new_model:on_render()
        assert(self._controller, "Controller must be specified for rendering")
        assert(self._req, "Request object cannot be nil")
        assert(self._res, "Response object cannot be nil")

        local ctrl = self._controller:new()
        ctrl:setContext(self._req, self._res)
        ctrl:dispatch("index")
    end

    --- Post-render hook execution (calls `after_render_hook` internally).
    function new_model:after_render()
        run_hook("after_render_hook", self.after_render_hook, self)
    end

    --- Cleanup hook execution (calls `on_destroy_hook` internally).
    function new_model:on_destroy()
        run_hook("on_destroy_hook", self.on_destroy_hook, self)
    end

    --- Executes the full model lifecycle with built-in hooks and error handling.
    function new_model:render()
        self:before_render()
        self:on_render()
        self:after_render()
        self:on_destroy()
    end

    return new_model
end

return Model
