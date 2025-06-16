-- css_helper.lua

-- It's good practice to define external dependencies clearly.
-- Assuming 'server.auth.sha256' exists and provides a sha256_hex function.
local sha256 = require("auth.sha256")

local css_helper = {}

-- Define a constant for units to make it easier to manage
local DEFAULT_UNIT = "px"

-- Properties that typically require a unit when a number is provided.
-- Using a set (table with boolean values) for O(1) lookup performance.
local css_properties_with_units = {
  width = true, height = true, top = true, left = true, right = true, bottom = true,
  margin = true, marginTop = true, marginBottom = true, marginLeft = true, marginRight = true,
  padding = true, paddingTop = true, paddingBottom = true, paddingLeft = true, paddingRight = true,
  fontSize = true, borderWidth = true, borderRadius = true,
  maxWidth = true, maxHeight = true, minWidth = true, minHeight = true,
}

-- Helper function to check if a property typically requires a unit.
-- This is now O(1) thanks to the set-like `css_properties_with_units` table.
local function has_unit_property(prop)
  return css_properties_with_units[prop] == true
end

-- Converts camelCase to kebab-case (e.g., "fontSize" to "font-size").
local function to_kebab_case(str)
  -- The pattern `%u` matches uppercase characters.
  -- The function replaces each uppercase character with a hyphen followed by its lowercase version.
  return str:gsub("%u", function(c) return "-" .. c:lower() end)
end

-- Formats a CSS property value based on its type and property name.
local function format_value(prop, val)
  -- If it's a number and the property needs a unit, append the default unit.
  if type(val) == "number" and has_unit_property(prop) then
    return tostring(val) .. DEFAULT_UNIT
  end
  -- If it's a table, concatenate its elements with spaces. Useful for 'font' shorthand.
  if type(val) == "table" then
    return table.concat(val, " ")
  end
  -- Handle boolean values, converting them to "true" or "false" strings.
  if type(val) == "boolean" then
    return val and "true" or "false"
  end
  -- Handle palette references (e.g., "@primary").
  -- It tries to resolve the key from `_palette`; otherwise, it returns the original value.
  if type(val) == "string" and val:sub(1, 1) == "@" then
    local key = val:sub(2)
    -- Ensure _palette is initialized before accessing it.
    return css_helper._palette and css_helper._palette[key] or val
  end
  -- For all other types, convert to string.
  return tostring(val)
end

--- Converts a Lua table representing CSS styles into an inline CSS string.
-- @param tbl table A table where keys are CSS property names (camelCase) and values are property values.
-- @return string An inline CSS string (e.g., "width: 100px; color: red;").
function css_helper.style_to_inline(tbl)
  local props = {}
  -- Iterate through the table, format each property and value, and add to `props`.
  for k, v in pairs(tbl) do
    local prop = to_kebab_case(k) -- Convert property name to kebab-case.
    local val = format_value(k, v) -- Format the value.
    table.insert(props, string.format("%s: %s", prop, val))
  end
  -- Join all formatted properties with a semicolon and space.
  return table.concat(props, "; ")
end

-- Hashes a Lua table to generate a short, unique identifier.
-- This is used for generating class names.
local function hash_table(tbl)
  local keys = {}
  -- Collect all keys from the table.
  for k, _ in pairs(tbl) do
    table.insert(keys, k)
  end
  table.sort(keys) -- Sort keys for consistent hashing.

  local parts = {}
  -- Create "key=value" pairs. `tostring` is important for consistent serialization.
  for _, k in ipairs(keys) do
    -- If the value is a table, it needs to be serialized recursively or handled appropriately
    -- for a consistent hash. For simplicity, we'll just use tostring for now.
    -- For more robust hashing of nested tables, you'd need a deeper serialization.
    table.insert(parts, k .. "=" .. tostring(tbl[k]))
  end
  local concatenated = table.concat(parts, ";")
  -- Generate SHA256 hash and take the first 8 characters.
  local hash = sha256.sha256_hex(concatenated)
  return hash:sub(1, 8)
end

-- Initialize internal state for CSS helper.
css_helper._styles = {}        -- Stores dynamically generated styles.
css_helper._palette = {}       -- Stores color palette or theme variables.
css_helper._text_theme = {}    -- Stores predefined text themes.
css_helper._theme_mode = "light" -- Current theme mode (e.g., "light" or "dark").

--- Sets the global CSS palette.
-- @param tbl table A table representing the palette (e.g., `{primary = "#007bff"}`).
function css_helper.set_palette(tbl)
  css_helper._palette = tbl or {}
end

--- Sets the global text themes.
-- @param tbl table A table representing text themes (e.g., `{h1 = {fontSize = 24}}`).
function css_helper.set_text_theme(tbl)
  css_helper._text_theme = tbl or {}
end

--- Sets the current theme mode.
-- @param mode string The theme mode (e.g., "light", "dark").
function css_helper.set_theme_mode(mode)
  css_helper._theme_mode = mode
end

--- Retrieves and resolves a predefined text theme.
-- @param name string The name of the text theme.
-- @return table A table of resolved CSS properties for the text theme.
function css_helper.use_text_theme(name)
  local theme = css_helper._text_theme[name]
  if not theme then error("Text theme '" .. name .. "' not found") end
  local resolved = {}
  -- Format each value in the theme.
  for k, v in pairs(theme) do
    resolved[k] = format_value(k, v)
  end
  return resolved
end

--- Creates a media query string.
-- @param str string The media query condition (e.g., "(min-width: 640px)").
-- @return string The full media query string (e.g., "@media (min-width: 640px)").
function css_helper.media_query(str)
  return "@media " .. str
end

-- Predefined media query breakpoints.
css_helper.media = {
  sm = function() return "@media (min-width: 640px)" end,
  md = function() return "@media (min-width: 768px)" end,
  lg = function() return "@media (min-width: 1024px)" end,
  xl = function() return "@media (min-width: 1280px)" end,
  ["2xl"] = function() return "@media (min-width: 1536px)" end,
  query = css_helper.media_query -- Allow custom media queries.
}

local MAX_RECURSION_DEPTH = 30 -- Safeguard for deeply nested styles.

--- Recursively resolves nested CSS styles.
-- This function handles nested selectors and media queries.
-- @param styles table The current styles table to process.
-- @param parent_selector string The accumulated parent selector.
-- @param acc table The accumulator table for resolved styles.
-- @param depth number Current recursion depth.
-- @return table The accumulated and resolved styles.
local function resolve_nested_styles(styles, parent_selector, acc, depth)
  acc = acc or {}
  depth = depth or 0
  parent_selector = parent_selector or ""

  if depth > MAX_RECURSION_DEPTH then
    error("Max recursion depth reached in resolve_nested_styles. This may indicate a circular reference or overly complex nesting.")
  end

  for selector, rules in pairs(styles) do
    if type(rules) ~= "table" then
      -- If `rules` is not a table, it's a direct property-value pair.
      acc[parent_selector] = acc[parent_selector] or {}
      -- Only add if the property hasn't been explicitly defined as a nested selector.
      -- This handles cases where a property might be at the same level as a nested selector.
      -- The original code implicitly treated non-table rules as properties of the parent_selector.
      -- We need to ensure `rules` itself isn't meant to be a selector.
      -- The original code's logic here is a bit ambiguous for a property named like a selector.
      -- For now, assume `rules` *is* the value for `selector` under `parent_selector`.
      acc[parent_selector][selector] = rules
    elseif selector:sub(1, 1) == "@" then
      -- Handle at-rules like `@media`.
      -- Media queries and other at-rules don't concatenate with parent selectors directly.
      acc[selector] = acc[selector] or {}
      -- Recursively resolve styles within the at-rule, keeping `parent_selector` for its children.
      local inner_resolved_styles = resolve_nested_styles(rules, parent_selector, {}, depth + 1)
      for sel, val in pairs(inner_resolved_styles) do
        acc[selector][sel] = val
      end
    -- Check if the selector starts with a CSS specific character or a word character.
    -- This helps differentiate between nested selectors and potential CSS properties.
    elseif selector:match("^[:.%[#]") or selector:match("^%s") or selector:match("^%w") then
      local full_selector
      if parent_selector == "" then
        full_selector = selector
      else
        -- If the selector starts with an ampersand, it indicates nesting within the parent.
        -- This is a common SASS/LESS-like nesting syntax.
        if selector:sub(1, 1) == "&" then
          full_selector = parent_selector .. selector:sub(2) -- Remove the ampersand
        else
          full_selector = parent_selector .. " " .. selector
        end
      end

      -- Sanity check for extremely long selectors to prevent potential issues.
      if #full_selector > 2000 then
        error("Selector too long: " .. full_selector:sub(1, 100) .. "...")
      end

      -- Recursively resolve styles for the concatenated selector.
      resolve_nested_styles(rules, full_selector, acc, depth + 1)
    else
      -- If it's not an at-rule and not a recognized selector syntax, treat it as a property of the parent.
      -- This part might need careful consideration depending on the exact nesting semantics desired.
      -- The original logic here was a bit ambiguous. Assuming it's a property of the parent.
      acc[parent_selector] = acc[parent_selector] or {}
      acc[parent_selector][selector] = rules
    end
  end
  return acc
end

--- Renders a Lua table of styles into a CSS string.
-- @param style_table table The table of styles to render.
-- @param minified boolean If true, the output CSS will be minified.
-- @return string The generated CSS string.
function css_helper.render_styles(style_table, minified)
  local flat_styles = {} -- Will hold the flattened CSS rules.

  -- First, flatten the input `style_table` using `resolve_nested_styles`.
  -- This processes all nesting and media queries.
  for selector, rules in pairs(style_table) do
    if type(rules) == "table" then
      local resolved_block = resolve_nested_styles({[selector] = rules})
      for sel, props_tbl in pairs(resolved_block) do
        -- Merge properties for the same selector.
        flat_styles[sel] = flat_styles[sel] or {}
        for prop, val in pairs(props_tbl) do
          flat_styles[sel][prop] = val
        end
      end
    else
      -- If the top-level entry isn't a table, it's a direct property-value pair
      -- for the "global" or default selector (which won't have a specific selector here).
      -- This case might indicate an issue with how `style_table` is structured if it's meant
      -- to be a collection of selectors. For now, it will be treated as rules for an empty selector.
      flat_styles[""] = flat_styles[""] or {}
      flat_styles[""][selector] = rules
    end
  end

  local css_chunks = {} -- Stores individual CSS rule blocks.
  local indent = minified and "" or "  " -- Indentation for pretty printing.
  local newline = minified and "" or "\n" -- Newline for pretty printing.
  local space = minified and "" or " " -- Space for pretty printing.

  for selector, rules in pairs(flat_styles) do
    if selector:sub(1, 1) == "@" then
      -- Handle at-rules (like `@media`).
      -- Recursively call render_styles for the inner rules of the at-rule.
      local inner_css = css_helper.render_styles(rules, minified)
      table.insert(css_chunks, selector .. space .. "{" .. newline .. inner_css .. newline .. "}")
    elseif selector == "" then
      -- If the selector is empty, it means these are properties for the root/default style.
      -- This usually doesn't happen with well-formed CSS-in-Lua structures, but defensively handle it.
      -- It's more common to have global styles defined directly in a style tag.
      -- We'll just ignore this case for now, as it's likely a malformed input if it makes it here.
      -- If intended as global styles, they should be wrapped in a specific selector (e.g., "body").
    else
      -- Process regular CSS rules.
      local props_list = {}
      for k, v in pairs(rules) do
        local prop = to_kebab_case(k) -- Convert property name.
        local val = format_value(prop, v) -- Format value.
        table.insert(props_list, indent .. prop .. ":" .. space .. val .. ";")
      end
      -- Assemble the CSS block for the current selector.
      if #props_list > 0 then -- Only add if there are properties.
        table.insert(css_chunks, selector .. space .. "{" .. newline .. table.concat(props_list, newline) .. newline .. "}")
      end
    end
  end

  -- Join all CSS chunks with newlines (or no newlines if minified).
  return table.concat(css_chunks, newline .. newline) -- Add an extra newline between blocks for readability when not minified.
end


--- Generates a class name and stores the associated styles.
-- @param tbl table A table of CSS properties for the class.
-- @param scope_id string An optional scope ID to prefix the generated class name.
-- @return table A table containing the generated `class` name and the original `style` table.
function css_helper.style_to_class(tbl, scope_id)
  -- Generate a unique hash for the style table to use as a class name.
  -- Prefix with "c" to ensure it's a valid CSS identifier.
  local class_name = (scope_id and scope_id .. "-") .. "c" .. hash_table(tbl)
  css_helper._styles[class_name] = tbl -- Store the styles under this class name.
  return {
    class = class_name,
    style = tbl -- Return the original style table for potential further use.
  }
end

--- Renders HTML with dynamically generated styles injected into a `<style>` tag.
-- This function collects all stored styles and renders them into a CSS string.
-- @param html string The HTML content.
-- @param minified boolean If true, the generated CSS will be minified.
-- @param scope_id string An optional scope ID to filter which stored styles are rendered.
-- @return string The HTML with the embedded `<style>` block.
function css_helper.render_with_styles(html, minified, scope_id)
  local styles_to_render = {}
  -- Iterate through all stored styles.
  for class_name, rules in pairs(css_helper._styles) do
    -- If a `scope_id` is provided, only include styles that belong to that scope.
    -- The original `find` might be too broad; `sub(1, #scope_id)` is more precise for prefix matching.
    if not scope_id or class_name:sub(1, #scope_id) == scope_id then
      styles_to_render["." .. class_name] = rules -- Prepend "." to make it a CSS class selector.
    end
  end
  local rendered_css = css_helper.render_styles(styles_to_render, minified)
  return html .. "\n<style>\n" .. rendered_css .. "\n</style>"
end

--- A utility function to test the `format_value` function.
-- @param style_tbl table A table of styles to test.
-- @return boolean, string True if all values can be formatted, false and an error message otherwise.
function css_helper.test(style_tbl)
  local ok, err = pcall(function()
    for k, v in pairs(style_tbl) do
      format_value(k, v) -- Test formatting for each property-value pair.
    end
  end)
  return ok, err
end

return css_helper