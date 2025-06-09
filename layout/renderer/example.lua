package.path = package.path .. ";./?.lua;./../?.lua;./../../?.lua;"
package.cpath = package.cpath .. ";./?.so;./../?.so;./../../server/?.so;"

require("bootstrap")("./../../")

 local lustache = require("lustache")

 local DawnServer = require("server.dawn_server")

 local myLogger = require("utils.logger").Logger:new()

local lustache_renderer = require("lustache_renderer")
 myLogger:setLogMode("dev") -- Set the desired log level

 local server_config = {
    port = 3000,
    logger = myLogger,
    -- Configure static file serving
    -- Each entry is a table with 'route_prefix' and 'directory_path'
    static_configs = {
        { route_prefix = "/static", directory_path = "./../../public" },
        { route_prefix = "/layout", directory_path = "./../../views" },

        -- You can add more static directories if needed:
        -- { route_prefix = "/assets", directory_path = "./assets" },
    },
    token_store = {
        store = {}, -- A simple Lua table for demonstration. In a real app, this would be a persistent store.
        cleanup_interval = 60 -- Clean up every 60 seconds (for TokenCleaner example)
    },
    state_management_options = {
        session_timeout = 3600, -- Session timeout in seconds
        cleanup_interval = 60   -- How often to clean up expired sessions
    }
}

 local server = DawnServer:new(server_config)


  local HomeController = require("controllers.home_controller")

local LayoutModel = require("layout_model")


 server:get("/home", function(req, res)

        local button = LayoutModel:extend({req = req, res = res}, HomeController)
        button.before_render_hook = function(self)
            self._controller:initialize_data()
        end
        button:render()

 end)

 server:get('/products', function (req, res)

    local product_controller = require("controllers.products_controller")

    local products_layout = LayoutModel:extend({req = req, res = res}, product_controller)

    products_layout.before_render_hook = function (self)
        self._controller:initialize_data(20)
    end

    products_layout:render()

 end)

 local ModelRoute = require("db.orm.DawnModelRoute")
 local profile_model = require("models.user").Profile

 ModelRoute:new('profiles', profile_model, server):initialize()

 server:start()




 