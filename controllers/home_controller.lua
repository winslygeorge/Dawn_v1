-- controllers/home_controller.lua

-- 1. Require the base Controller class
local BaseController = require("layout.renderer.Controller") -- Assuming 'Controller.lua' is in a path Lua can find

local MainLayout = require("lib.main_layout")
-- 2. Create the HomeController table and inherit from BaseController
-- local HomeController = BaseController:new(lustache_renderer):extends() -- Pass the renderer to the base Controller constructor

local HomeController = BaseController:extends()

    HomeController.user_data = {}

   function HomeController:initialize_data()

    local UserModel = require("db.UserModel").User
     local user_list = UserModel:find(2)
     if user_list and #user_list > 0 then
        self.user_data = user_list[1]
     end

   end

-- Define the 'index' action for the home page
function HomeController:index()
    local user = self.user_data

    print("print user : ", user)
    -- local products = get_latest_products()

    -- Data for the page content (`pages/home.mustache`)
    local homepage_data = {
        page_heading = "Welcome to Dawnserver!",
        page_description = "Your ultimate solution for modern web applications.",
        show_call_to_action_button = true, -- Boolean for conditional rendering
        -- latest_products = products,
        -- Any other data specific to the home page
    }

    -- Render the page content and navbar separately as you did,
    -- then pass them as part of the content block to the layout.
    local home_cont = require("lib.home.index")


    home_cont:init(function (children, props)
        props.home_data = homepage_data
                print('setting data: ', require('cjson').encode(props))

    end)

    local page_content_html = home_cont:build()

    MainLayout:init(
        function (children, props, style)
            children.body = page_content_html
        end
    )

    MainLayout:render_layout(self)
    -- 4. Use self:render() from the base Controller to send the final HTML
end

return HomeController
