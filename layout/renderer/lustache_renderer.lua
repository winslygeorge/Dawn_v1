
 local lustache = require("lustache")
local M = {}
local TEMPLATE_DIR = "./../../views/"
local CACHED_TEMPLATES = {} -- Simple in-memory cache for template content

-- Function to get a template path
local function get_template_path(name)
    -- Sanitize 'name' to prevent directory traversal attacks
    local sanitized_name = name:gsub('%.%.[/\\]', ''):gsub('[/\\]+', '/')
    return TEMPLATE_DIR .. sanitized_name .. ".mustache"
end

-- Loads and caches template content
local function load_template_content(template_path)
    if CACHED_TEMPLATES[template_path] then
        return CACHED_TEMPLATES[template_path]
    end

    local file = io.open(template_path, "r")
    if not file then
        error("Template file not found: " .. template_path)
    end
    local content = file:read("*a")
    file:close()

    CACHED_TEMPLATES[template_path] = content
    return content
end

-- Resolves partials for Lustache. This is crucial for component-based rendering.
-- Lustache calls this function when it encounters a partial tag (e.g., {{> navbar}}).
local function partial_resolver(name)
    -- Prioritize components, then layouts, then generic partials
    local paths_to_try = {
        "components/" .. name,
        "layouts/" .. name,
        "partials/" .. name,
        name -- Try raw name last
    }

    for _, p_name in ipairs(paths_to_try) do
        local p_path = get_template_path(p_name)
        local file = io.open(p_path, "r")
        if file then
            local content = file:read("*a")
            file:close()
            return content
        end
    end
    -- Handle missing partials gracefully, e.g., by returning an empty string or an error message
    -- For development, you might want to error:
    -- error("Partial not found: " .. name)
    return ""
end

-- Renders a template with provided data
-- Renders a template with provided data
function M:render(template_name, data)
    local template_path = get_template_path(template_name)
    local template_content = load_template_content(template_path)

    local success, result = xpcall(function()
        return lustache:render(template_content, data or {}, {
            -- Pass the custom partial_resolver function within an options table
            partial_resolver = partial_resolver
        })
    end, debug.traceback)

    if not success then
        error("Lustache rendering error for " .. template_name .. ":\n" .. result)
    end
    return result
end

-- In development, you might want to clear the cache for hot-reloading
function M.clear_cache()
    CACHED_TEMPLATES = {}
end

return M
