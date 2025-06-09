-- orm/model_route.lua

--- This module defines a ModelRoute class that generates CRUD handlers
--- for a given ORM Model, integrating directly with DawnServer's request/response cycle.
local ModelRoute = {}

local json = require('cjson')
local log_level = require('utils.logger').LogLevel
local config = require('config') -- Assuming you have a config module for default connection mode
local setTimeout = require('utils.promise').setTimeout
local uv = require('luv') -- Assuming you have the 'luv' library available for async operations

--- Creates a new ModelRoute instance.
-- @param model_class table The ORM Model class (e.g., User, Department).
-- @param logger table The logger instance from DawnServer.
-- @return table A new ModelRoute instance.
function ModelRoute:new(model_class, logger)
    local self = setmetatable({}, { __index = ModelRoute })
    self.Model = model_class
    self.logger = logger
    return self
end

--- Handles GET requests to retrieve all instances of the model.
-- Route: /model_prefix
-- @param req table The request object.
-- @param res table The response object.
-- @param query_params table Query parameters from the URL.
function ModelRoute:get_all(req, res, query_params)
    -- Determine the connection mode for the model, falling back to a default if not specified.
    local model_conn_mode = self.Model._connection_mode or config.default_mode

    --- Helper function to send an error response.
    -- @param err_message string The error message to send.
    -- @param status_code number The HTTP status code for the error.
    local function send_error(err_message, status_code)
        self.logger:log(log_level.ERROR, string.format("Error getting all %s: %s", self.Model._table_name, err_message), "ModelRoute")
        res:writeHeader("Content-Type", "application/json")
           :writeStatus(status_code)
           :send(json.encode({ error = "Internal Server Error", message = err_message }))
    end

    -- Extract pagination parameters from query_params
    local page = tonumber(query_params.page)
    local per_page = tonumber(query_params.limit) -- Renamed 'limit' to 'per_page' for consistency with Model:paginate

    -- Determine if valid pagination parameters are present
    local has_pagination_params = (page and per_page and page >= 1 and per_page > 0)

    -- Extract other query parameters as filters, excluding pagination parameters
    local filters = {}
    for k, v in pairs(query_params) do
        if k ~= "page" and k ~= "limit" and k ~= "order_by" and k ~= "order_direction" then -- Exclude pagination parameters from the filters
            filters[k] = v
        end
    end
    local has_filters = next(filters) ~= nil -- Check if the filters table is not empty

    if model_conn_mode == "async" then
        -- Set common headers for async responses
        res:writeHeader("Connection" , "keep-alive")
           :writeHeader("Content-Type", "application/json")
           :writeStatus(200)

        if has_pagination_params then
            -- If pagination parameters are present, use the paginate method
            local qb = self.Model:query() -- Start a new query builder instance
            if has_filters then
                -- Apply additional filters if they exist
                for k, v in pairs(filters) do
                    qb:where(k, "=", v)
                end
            end
            -- Execute the paginated query asynchronously
            self.Model:paginate(page, per_page, function(err, pagination_result)
                if err then
                    return send_error(tostring(err), 500)
                end
                res:send(json.encode(pagination_result))
            end)
        elseif has_filters then
            -- If no pagination but filters are present, use the where method
            self.Model:where(filters, function(err, instances)
                if err then
                    return send_error(tostring(err), 500)
                end
                res:send(json.encode(instances))
            end)
        else
            -- If no pagination and no filters, use the all method
            self.Model:all(function(err, instances)
                if err then
                    return send_error(tostring(err), 500)
                end
                res:send(json.encode(instances))
            end)
        end
    else -- sync mode
        local ok, result = pcall(function()
            local data_to_send

            if has_pagination_params or has_filters then
                -- Execute the paginated query synchronously
                data_to_send = self.Model:paginate_with({include_relations = self.Model._include_relations or false, page = page, per_page = per_page, where = filters, order_by = {{column = query_params.order_by, direction = query_params.order_direction}}})
            else
                -- If no pagination and no filters, use the all method
                data_to_send = self.Model:all({include_relations = self.Model._include_relations or false})
            end

            -- Send the successful response
            res:writeHeader("Content-Type", "application/json")
               :writeStatus(200)
               :send(json.encode(data_to_send))
        end)
        if not ok then
            send_error(tostring(result), 500)
        end
    end
end


--- Handles GET requests to retrieve a single instance by ID.
-- Route: /model_prefix/:id
-- @param req table The request object (req.params.id will contain the ID).
-- @param res table The response object.
-- @param query_params table Query parameters from the URL.
function ModelRoute:get_by_id(req, res, query_params)
    local id = tonumber(req.params.id)
    if not id then
        res:writeHeader("Content-Type", "application/json")
           :writeStatus(400)
           :send(json.encode({ error = "Bad Request", message = "Invalid ID provided." }))
        return
    end

    local model_conn_mode = self.Model._connection_mode or config.default_mode

    local function send_error(err_message, status_code)
        self.logger:log(log_level.ERROR, string.format("Error finding %s by ID %s: %s", self.Model._table_name, id, err_message), "ModelRoute")
        res:writeHeader("Content-Type", "application/json")
           :writeStatus(status_code)
           :send(json.encode({ error = "Internal Server Error", message = err_message }))
    end

    local function send_not_found()
        res:writeHeader("Content-Type", "application/json")
           :writeStatus(404)
           :send(json.encode({ error = "Not Found", message = string.format("%s with ID %s not found.", self.Model._table_name, id) }))
    end

    if model_conn_mode == "async" then
        self.Model:find(id, function(err, instance)
            if err then
                return send_error(tostring(err), 500)
            end
            if instance then
                res:writeHeader("Content-Type", "application/json")
                   :writeStatus(200)
                   :send(json.encode(instance))
            else
                send_not_found()
            end
        end)
    else -- sync mode
        local ok, instance = pcall(function()
            return self.Model:find(id)
        end)

        if not ok then
            send_error(tostring(instance), 500)
            return
        end

        if instance then
            res:writeHeader("Content-Type", "application/json")
               :writeStatus(200)
               :send(json.encode(instance))
        else
            send_not_found()
        end
    end
end

--- Handles POST requests to create a new instance.
-- Route: /model_prefix
-- @param req table The request object.
-- @param res table The response object.
-- @param body table The parsed request body (JSON or form data).
function ModelRoute:create(req, res, body)
    if not body or type(body) ~= "table" or next(body) == nil then
        res:writeHeader("Content-Type", "application/json")
           :writeStatus(400)
           :send(json.encode({ error = "Bad Request", message = "Request body must be a non-empty JSON object or form data." }))
        return
    end

    local model_conn_mode = self.Model._connection_mode or config.default_mode

    local function send_error(err_message, status_code)
        self.logger:log(log_level.ERROR, string.format("Error creating %s: %s", self.Model._table_name, err_message), "ModelRoute")
        res:writeHeader("Content-Type", "application/json")
           :writeStatus(status_code)
           :send(json.encode({ error = "Internal Server Error", message = err_message }))
    end

    if model_conn_mode == "async" then
        self.Model:create(body, function(err, new_instance)
            if err then
                -- Check for unique constraint violation specifically
                if tostring(err):find("duplicate key value violates unique constraint") then
                    return send_error("A record with the provided unique data already exists.", 409)
                else
                    return send_error(tostring(err), 500)
                end
            end
            res:writeHeader("Content-Type", "application/json")
               :writeStatus(201) -- Created
               :send(json.encode(new_instance))
        end)
    else -- sync mode
        local ok, new_instance = pcall(function()
            return self.Model:create(body)
        end)

        if not ok then
            -- Check for unique constraint violation specifically
            if tostring(new_instance):find("duplicate key value violates unique constraint") then
                send_error("A record with the provided unique data already exists.", 409)
            else
                send_error(tostring(new_instance), 500)
            end
            return
        end

        res:writeHeader("Content-Type", "application/json")
           :writeStatus(201) -- Created
           :send(json.encode(new_instance))
    end
end

--- Handles PUT/PATCH requests to update an existing instance by ID.
-- Route: /model_prefix/:id
-- @param req table The request object (req.params.id will contain the ID).
-- @param res table The response object.
-- @param body table The parsed request body (JSON or form data).
function ModelRoute:update(req, res, body)
    local id = tonumber(req.params.id)
    if not id then
        res:writeHeader("Content-Type", "application/json")
           :writeStatus(400)
           :send(json.encode({ error = "Bad Request", message = "Invalid ID provided." }))
        return
    end

    if not body or type(body) ~= "table" or next(body) == nil then
        res:writeHeader("Content-Type", "application/json")
           :writeStatus(400)
           :send(json.encode({ error = "Bad Request", message = "Request body must be a non-empty JSON object or form data." }))
        return
    end

    local model_conn_mode = self.Model._connection_mode or config.default_mode

    local function send_error(err_message, status_code)
        self.logger:log(log_level.ERROR, string.format("Error updating %s with ID %s: %s", self.Model._table_name, id, err_message), "ModelRoute")
        res:writeHeader("Content-Type", "application/json")
           :writeStatus(status_code)
           :send(json.encode({ error = "Internal Server Error", message = err_message }))
    end

    local function send_not_found()
        res:writeHeader("Content-Type", "application/json")
           :writeStatus(404)
           :send(json.encode({ error = "Not Found", message = string.format("%s with ID %s not found for update.", self.Model._table_name, id) }))
    end

    if model_conn_mode == "async" then
        self.Model:find(id, function(err, instance)
            if err then
                return send_error(tostring(err), 500)
            end
            if not instance then
                return send_not_found()
            end

            -- Update instance properties with data from the body
            for k, v in pairs(body) do
                instance[k] = v
            end

           self.Model:new(instance):save(function(save_err, save_success)
                if save_err or not save_success then
                    return send_error(tostring(save_err or "Unknown save error"), 500)
                end
                res:writeHeader("Content-Type", "application/json")
                   :writeStatus(200)
                   :send(json.encode(instance)) -- Return the updated instance
            end)
        end)
    else -- sync mode
        local ok, instance = pcall(function()
            return self.Model:find(id)
        end)

        if not ok then
            send_error(tostring(instance), 500)
            return
        end

        if not instance then
            send_not_found()
            return
        end

        -- Update instance properties with data from the body
        for k, v in pairs(body) do
            instance[k] = v
        end

        local save_ok, save_err = pcall(function()
            return self.Model:new(instance):save()
        end)

        if not save_ok then
            send_error(tostring(save_err), 500)
            return
        end

        res:writeHeader("Content-Type", "application/json")
           :writeStatus(200)
           :send(json.encode(instance)) -- Return the updated instance
    end
end

--- Handles DELETE requests to delete an instance by ID.
-- Route: /model_prefix/:id
-- @param req table The request object (req.params.id will contain the ID).
-- @param res table The response object.
-- @param query_params table Query parameters from the URL.
function ModelRoute:delete(req, res, query_params)
    local id = tonumber(req.params.id)
    if not id then
        res:writeHeader("Content-Type", "application/json")
           :writeStatus(400)
           :send(json.encode({ error = "Bad Request", message = "Invalid ID provided." }))
        return
    end

    local model_conn_mode = self.Model._connection_mode or config.default_mode

    local function send_error(err_message, status_code)
        self.logger:log(log_level.ERROR, string.format("Error deleting %s with ID %s: %s", self.Model._table_name, id, err_message), "ModelRoute")
        res:writeHeader("Content-Type", "application/json")
           :writeStatus(status_code)
           :send(json.encode({ error = "Internal Server Error", message = err_message }))
    end

    local function send_not_found()
        res:writeHeader("Content-Type", "application/json")
           :writeStatus(404)
           :send(json.encode({ error = "Not Found", message = string.format("%s with ID %s not found for deletion.", self.Model._table_name, id) }))
    end

    if model_conn_mode == "async" then
        self.Model:find(id, function(err, instance)
            if err then
                return send_error(tostring(err), 500)
            end
            if not instance then
                return send_not_found()
            end

            instance = self.Model:new(instance) -- Ensure instance is a new object for deletion

            instance:delete(function(delete_err, delete_success)
                if delete_err or not delete_success then
                    -- print("Error deleting instance:", delete_err)
                    return send_error(tostring(delete_err or "Unknown delete error"), 500)
                end
                res:writeStatus(204):send(json.encode({message = "Delete request successful", model = delete_success})) -- No Content for successful deletion
            end)
        end)
    else -- sync mode
        local ok, instance = pcall(function()
            return self.Model:find(id)
        end)

        if not ok then
            send_error(tostring(instance), 500)
            return
        end

        if not instance then
            send_not_found()
            return
        end

        local delete_ok, delete_err = pcall(function()
            return self.Model:new(instance):delete()
        end)

        if not delete_ok then
            send_error(tostring(delete_err), 500)
            return
        end

        res:writeStatus(204):send(json.encode({message = "Delete request successful"})) -- No Content for successful deletion
    end
end

return ModelRoute