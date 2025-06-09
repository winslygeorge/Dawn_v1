local FuncComponent = require('layout.renderer.FuncComponent')
local css_helper = require('utils.css_helper')

local ActionButton = FuncComponent:extends()

ActionButton:setView('components/button')

ActionButton:init(function(children, props, style)

    props.icon = '<i class="fa fa-bank" style="font-size:48px;color:red"></i>'
    -- Theming + dynamic props
    local bg = props.color or "blue"
    local text = props.text_color or "white"
    local radius = props.radius or "10px"
    local shadow = props.shadow or "0 4px 8px rgba(0,0,0,0.15)"
    local size = props.size or "md"
    local isLoading = props.loading == true
    local hasIcon = props.icon ~= nil

    -- Padding based on size
    local sizePadding = {
        sm = "6px 12px",
        md = "12px 20px",
        lg = "16px 32px"
    }

    -- Base button styles
    style.css = {
        background = bg,
        color = text,
        ['border-radius'] = radius,
        ['box-shadow'] = shadow,
        padding = sizePadding[size] or sizePadding["md"],
        ['font-weight'] = "bold",
        ['font-size'] = size == "sm" and "0.85rem" or size == "lg" and "1.1rem" or "1rem",
        display = "inline-flex",
        ['align-items'] = "center",
        ['justify-content'] = "center",
        gap = hasIcon and "8px" or nil,
        cursor = isLoading and "not-allowed" or "pointer",
        border = "none",
        opacity = isLoading and 0.7 or 1,
        transition = "all 0.3s ease"
    }

    -- Hover & active states
    style.css[":hover"] = not isLoading and {
        ['box-shadow'] = "0 6px 12px rgba(0,0,0,0.2)",
        filter = "brightness(1.05)"
    } or nil

    style.css[":active"] = not isLoading and {
        ['box-shadow'] = "0 2px 4px rgba(0,0,0,0.1)",
        transform = "scale(0.98)"
    } or nil

    -- Button content
    props.type = props.type or "button"

    local label = isLoading and (props.loadingText or "Loading...") or props.label or "Click Me"

    children.btn_icon = hasIcon and ("<span class='icon'>" .. props.icon .. "</span>") or nil
    children.label = "<span class='label'>" .. label .. "</span>"
end)

return ActionButton
