local DawnModelRoute = {}

--- Creates a new QueryBuilder instance for a given table.
-- @param table_name string The name of the database table this query builder operates on.
-- @return table A new QueryBuilder instance.

DawnModelRoute.__index = DawnModelRoute

local Promise = require("utils.promise").Promise
local await = require("utils.promise").await
local async = require("utils.promise").async

-- Assuming 'json' library is available and needed for encoding.
-- If not, remove this line and the json.encode calls.
local json = require("cjson")

--- Creates a new DawnModelRoute instance.
--- @param model_name string The name of the model (e.g., "User", "Product").
--- @param Model table The ORM model class (e.g., User, Product) to which the route is associated.
--- @param server table The server instance (e.g., DawnServer) to which the route is associated.
--- @return table A new DawnModelRoute instance.
function DawnModelRoute:new(model_name, Model, server)
    local self = setmetatable({
        model_name = model_name,
        Model = Model,
        server = server,
        logger = server.logger,
        -- Ensure "orm.model_route" is the correct path to your ModelRoute module
        model_route = require("orm.model_route"):new(Model, server.logger),
    }, DawnModelRoute)
    return self
end

--- Initializes and registers the API routes for the model with the server.
function DawnModelRoute:initialize()
    -- Route Scoping Example (/api routes)
    self.server:scope("/api", function(api)
        -- These routes will be prefixed with /api

        -- GET /api/{model_name} - Get all records for the model
        api:get("/" .. self.model_name, function(req, res, query)

            async(function()
                -- Ensure the query is a table, even if empty
                if type(query) ~= "table" then
                    query = {}
                end

                -- -- Log the request for debugging purposes
                -- print("GET /api/" .. self.model_name .. " - Query: " .. json.encode(query))

                -- Call the model_route's get_all method to handle the request
                await(self.model_route:get_all(req, res, query))

            end)()
            -- self.model_route:get_all(req, res, query)
            -- print("GET /api/" .. self.model_name .. " - Query: " .. json.encode(query))
        end)
        -- -- POST /api/{model_name} - Create a new record for the model
        api:post("/".. self.model_name.."/add", function(req, res, body)
            -- print("POST /api/" .. self.model_name .. " - Body: " .. json.encode(req.body))
            self.model_route:create(req, res, body)
        end)

        -- GET /api/{model_name}/:id - Get a single record by ID for the model
        -- Using self.model_name ensures consistency with the model being routed.
        api:get("/".. self.model_name .. "/getby/:id", function(req, res, query)
            local recordId = req.params.id
            -- print("GET /api/" .. self.model_name .. "/:id - ID: " .. recordId .. ", Query: " .. json.encode(query))
            self.model_route:get_by_id(req, res, query)
        end)

        -- You might also want to add PUT and DELETE routes for completeness
        -- PUT /api/{model_name}/:id - Update a record by ID
        api:put("/".. self.model_name .."/update/:id", function(req, res, body)
            local recordId = req.params.id
            -- print("PUT /api/" .. self.model_name .. "/:id - ID: " .. recordId .. ", Body: " .. json.encode(req.body))
            self.model_route:update(req, res, body) -- Assuming model_route has an update method
        end)

        -- DELETE /api/{model_name}/:id - Delete a record by ID
        api:delete("/".. self.model_name .."/delete/:id", function(req, res, query)
            local recordId = req.params.id
            -- print("DELETE /api/" .. self.model_name .. "/:id - ID: " .. recordId .. ", Query: " .. json.encode(query))
            self.model_route:delete(req, res, query) -- Assuming model_route has a delete method
        end)

    end)

end


return DawnModelRoute
