local MyComponent = require("layout.renderer.FuncComponent")

local navComponent = MyComponent:extends()

navComponent:setView("components/navbar")
-- navComponent:setTheme("light") -- or "dark"

navComponent:init(function(children, props, style)
    -- Configure your component's children, props, and styles here
    -- children.header = "<h1>Welcome!</h1>"
    -- props.data = { title = "Page Title", message = "Hello, World!" }
    props.data = {
        links = {
            {url = "https://luarocks.org/modules/tieske/copas", text = "Home"},
             {url = "https://luarocks.org/modules/tieske/copas", text = "About"}
        },

        user = {
            loggedIn = true
        }
    }
    
end)

return navComponent