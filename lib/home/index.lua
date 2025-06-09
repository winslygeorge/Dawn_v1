local FuncComponent = require("layout.renderer.FuncComponent")

local action_button = require("button")

local HomeComponent = FuncComponent:extends()

HomeComponent:setView('pages/home')

HomeComponent:init(function (children, props)

    action_button:init(function (btn_children, btn_props)
        btn_props.data =  { -- Nested table for the button component
            text = "Explore Features",
            type = "info",
            action = "exploreFeatures"
        }
    end)

    children.call_to_action_button_props = action_button:build()

end)

return HomeComponent


