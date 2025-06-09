---
-- FunctionalComponent Module
--
-- Final version of FunctionalComponent with `css_helper` integration,
-- theming, scoped styles, light/dark mode support, and hot-reload ready.
-- Uses Lustache as the view engine.
--
-- @module FunctionalComponent
-- @author 
-- @license MIT
-- @see lustache_renderer
-- @see utils.css_helper
--
-- ### Features:
-- - Declarative component structure with `children` and `props`
-- - Scoped CSS styling via `css_helper`
-- - Theming support (e.g., light/dark)
-- - Hot-reload ready via `reload()` method
-- - Inline and class-based CSS support
-- - Compatible with Lustache-style templating
--
-- ### Usage:
-- ```lua
-- local FC = require("FunctionalComponent")
-- local comp = FC:extends()
-- comp:setView("my_template")
-- comp:setTheme("dark")
-- comp:init(function(children, props, style)
--   -- configure component here
-- end)
-- local html = comp:build()
-- ```

local viewEngine = require("lustache_renderer")
local css_helper = require("utils.css_helper")

local FunctionalComponent = {}

---
-- Creates a new instance of FunctionalComponent.
-- @param data table? Optional initial table to use as base.
-- @return FunctionalComponent
function FunctionalComponent:new(data)
    local instance = data or {}
    setmetatable(instance, { __index = self })
    return instance
end

---
-- Extends the FunctionalComponent prototype to create a new component.
-- Adds props, children, styles, theme, and rendering logic.
-- @return FunctionalComponent A new component instance.
function FunctionalComponent:extends()
    local new_component = {}
    new_component.children = {}
    new_component.props = {}
    new_component.viewEngine = viewEngine
    new_component.viewname = nil
    new_component.style = {
        inline = {},
        css = {}
    }
    new_component.scope_id = "c" .. tostring(math.random(100000, 999999)) -- optional unique class scope
    new_component.palette = "light" -- default theme mode

    setmetatable(new_component, { __index = self })

    ---
    -- Sets the template view name for rendering.
    -- @param viewName string The name of the view/template.
    function new_component:setView(viewName)
        self.viewname = viewName
    end

    ---
    -- Sets the theme mode and applies the corresponding palette.
    -- @param theme_name string? Theme name (e.g., "light", "dark"). Defaults to "light".
    function new_component:setTheme(theme_name)
        self.palette = theme_name or "light"
        css_helper.set_palette(css_helper.get_builtin_palette(theme_name))
    end

    ---
    -- Initializes the component with children, props, and styles via a callback.
    -- @param callback fun(children: table, props: table, style: table): void
    function new_component:init(callback)
        assert(type(callback) == "function", "Init Callback function needs to be provided")
        callback(self.children, self.props, self.style)
    end

    ---
    -- Builds the final HTML output using the view engine and current component state.
    -- Applies scoped class styles and inline styles.
    -- @return string Rendered HTML string.
    function new_component:build()
        assert(self.viewname, "ViewName needs to be provided.")
        assert(self.viewEngine and type(self.viewEngine.render) == "function", "View engine not valid")

        self.props.children = self.children

        -- 🌈 Apply class-based styles with scoped hashing
        local class_result = css_helper.style_to_class(self.style.css or {}, self.scope_id)
        if class_result.class and class_result.class ~= "" then
            self.props.class = (self.props.class or "") .. " " .. class_result.class
        end

        -- 💡 Apply inline styles
        if self.style.inline and next(self.style.inline) then
            self.props.style = css_helper.style_to_inline(self.style.inline)
        end

        -- 🖼 Render view with props
        local html_output = self.viewEngine:render(self.viewname, self.props or {})

        local final_html_output = css_helper.render_with_styles(html_output, false, self.scope_id)

        -- 🧠 Auto inject CSS collected styles and variables
        return final_html_output
    end

    ---
    -- Reloads the current view template (useful for development/hot-reload).
    function new_component:reload()
        package.loaded[self.viewname] = nil
        self.viewEngine:reloadTemplate(self.viewname)
    end

    return new_component
end

return FunctionalComponent
