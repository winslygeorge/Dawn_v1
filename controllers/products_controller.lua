local Controller = require("layout.renderer.Controller")
local MainLayout = require("lib.main_layout")
local ProductController = Controller:extends()

function ProductController:initialize_data(id)
    -- Optional: Initialize controller-specific properties or services here, like fetching data
    print("Fetching data : ", id)

    local ProductsModel = require("models.user").Profile

    local data = ProductsModel:all()
 print('data : ', require("cjson").encode(data))
end

function ProductController:beforeAction(action, ...)
    -- Optional: Code to run before any action in this controller
    -- For example, logging or authentication checks specific to this controller
    print("Before action: " .. action)
end

function ProductController:index()
    -- Handle GET /my_route
    -- Example: Handle Controller data layout rendering
    -- Pass the content or component layout of the controller as children.body on the MainLayout renderer
    MainLayout:init(function (children, props, style)
end)

MainLayout:render_layout(self)
end

return ProductController