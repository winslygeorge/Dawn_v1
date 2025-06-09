--- This module defines the base class for all ORM models.
--- Models inherit from this base to gain ORM capabilities like CRUD operations,
--- query building, and automatic result mapping.
local Model = {}

-- Require necessary modules for ORM functionality
local ConnectionManager = require("db.orm.connection_manager")
local QueryBuilder = require("db.orm.query_builder")
local ResultMapper = require("db.orm.result_mapper")
local config = require("db.orm.config") -- Assuming this exists for default_mode
local CacheManager = require("db.orm.CacheManager") -- Assuming this exists for caching
local setTimeout = require("utils.promise").setTimeout -- Assuming this exists for async operations

--- Base constructor for a model instance.
-- This is typically called internally when mapping results or creating new instances.
--- @param data table (Optional) A table of initial properties for the model instance.
--- @return table A new model instance.
function Model:new(data)
    local instance = data or {}
    -- Set the metatable to self, so methods defined on the model class (e.g., User)
    -- are accessible on the instance, and also allow for "inheritance" via __index.
    setmetatable(instance, { __index = self })
    return instance
end

--- Extends the base Model to create a new specific model class.
-- This is the primary way to define your application's database models.
--- @param table_name string The name of the database table this model represents.
--- @param fields table A table defining the schema of the model (e.g., { id = "integer", name = "string" }).
--                      Supported types: "integer", "string", "timestamp", "boolean", "float", "text".
--                      Additional properties for fields:
--                        - `primary_key`: boolean (true if this field is the primary key, overrides _primary_key option)
--                        - `unique`: boolean (true if this field has a unique constraint)
--                        - `not_null`: boolean (true if this field cannot be null)
--                        - `default`: string|number|boolean (default value for the field)
--                        - `references`: string (e.g., "other_table(id)" for foreign key)
--                        - `on_delete`: string (e.g., "CASCADE", "SET NULL", "RESTRICT", "NO ACTION")
--                        - `on_update`: string (e.g., "CASCADE", "SET NULL", "RESTRICT", "NO ACTION")
--- @param options table (Optional) A table of options for the model:
--   - _primary_key string (Optional) The name of the primary key column. Defaults to "id".
--   - _connection_mode "sync"|"async" (Optional) Overrides the global default connection mode for this model.
--   - _unique_keys table (Optional) A list of tables, where each inner table defines a multi-column unique constraint.
--                                 Example: {{ "col1", "col2" }}
--   - _indexes table (Optional) A list of tables, where each inner table defines an index.
--                               Each index definition can be:
--                                 - A string (for single column index, e.g., "email")
--                                 - A table of strings (for composite index, e.g., {"first_name", "last_name"})
--                                 - A table with `columns` (string|table) and `unique` (boolean) for unique index.
--                                   Example: {{ columns = "email", unique = true }, { "created_at" }}
--   - _foreign_keys table (Optional) A list of tables, where each inner table defines a foreign key.
--                                 This is an alternative/addition to `references` on a field.
--                                 Example: {{ columns = "user_id", references = "users(id)", on_delete = "CASCADE" }}
--   - _relations table (Optional) A map defining explicit relationships, e.g., { user = { model = "User", foreign_key = "user_id" } }
--- @return table A new model class (table with metatable) that inherits from Model.
function Model:extend(table_name, fields, options)
    options = options or {}
    local new_model = {}

    -- Set the metatable for the new_model (the class itself) to inherit from the base Model.
    -- This allows new_model to access methods like 'new', 'extend' from the base Model.
    setmetatable(new_model, { __index = self })

    -- Model-specific properties
    new_model._table_name = table_name
    new_model._fields = fields or {}
    new_model._primary_key = options._primary_key or "id"
    new_model._connection_mode = options._connection_mode -- Can be nil, falling back to config.default_mode
    new_model._unique_keys = options._unique_keys or {}
    new_model._indexes = options._indexes or {}
    new_model._foreign_keys = options._foreign_keys or {}
    new_model._filter_presets = options._filter_presets or {} -- For paginate_with_advanced filters
    new_model._include_soft_deleted = false -- Internal flag for soft deletes
    new_model._timestamps = options._timestamps or false -- Enable automatic handling of created_at and updated_at
    new_model._include_relations = options._include_relations or false -- Enable eager loading of relations

    -- New: Process foreign keys into a more usable relations map
    new_model._relations = options._relations or {}
    for _, fk_def in ipairs(new_model._foreign_keys) do
        -- Assuming simple foreign key definition: { columns = "user_id", references = "users(id)" }
        -- We need to extract the referenced table and column.
        local local_col = type(fk_def.columns) == "table" and fk_def.columns[1] or fk_def.columns
        local ref_table, ref_col = string.match(fk_def.references, "(.+)%((.+)%)")
        if local_col and ref_table and ref_col then
            -- Default relation name to the referenced table name (singularized if possible)
            local relation_name = ref_table:gsub("s$", "") -- Simple plural to singular
            new_model._relations[relation_name] = {
                model_name = ref_table:gsub("^%l", string.upper), -- Capitalize first letter for model name
                local_key = local_col,
                foreign_key = ref_col,
                join_type = fk_def.join_type or "LEFT" -- Default to LEFT JOIN
            }
        end
    end

    --- Private helper to execute a query (DML or SELECT) and handle connection management.
    -- @param sql string The SQL query string.
    -- @param params table The parameters for the query.
    -- @param callback function|nil Optional callback for async mode.
    -- @param is_select boolean True if it's a SELECT query, false for DML.
    -- @param select_aliases table (Optional) Aliases for selected columns, for ResultMapper.
    -- @return mixed For sync: query result. For async: nil (result via callback).
    -- @raise error If the query operation fails.
    local function execute_query_helper(sql, params, callback, is_select, select_aliases)
        local mode = new_model._connection_mode or config.default_mode
        local conn = ConnectionManager.get_connection(mode)

        -- restructure sql and params for execution
        if not conn then
            error("Failed to get a database connection for mode: " .. tostring(mode))
        end
        if not sql or type(sql) ~= "string" or sql == "" then
            ConnectionManager.release_connection(mode, conn)
            error("SQL query string cannot be empty.")
        end
        -- check if sql is update, insert, or delete
        if not is_select and (not params or type(params) ~= "table") then
            params = {} -- Ensure params is a table for DML queries
        end

        -- if sql is insert, update, or delete, replace (?, ?, ?) with $1, $2, $3, ...
        if not is_select then
            local param_count = 0
            sql = sql:gsub("(%?)", function()
                param_count = param_count + 1
                return params and "'"..params[param_count].."'" or nil
            end)
        end

        -- if sql is select, replace (?, ?, ?) with $1, $2, $3, ...
        if is_select then
            local param_count = 0
            sql = sql:gsub("(%?)", function()
                param_count = param_count + 1
                return params and "'"..params[param_count].."'" or nil
            end)
        end

    

        if new_model._connection_mode == "async" then
            if type(callback) ~= "function" then
                ConnectionManager.release_connection(mode, conn)
                error("Callback function must be provided in async mode.")
            end

            ConnectionManager.execute_query(mode, conn, sql, function(err, rows_or_result)
                new_model._include_soft_deleted = false -- Reset flag after query
                ConnectionManager.release_connection(mode, conn)
                if err then
                    return callback(nil, tostring(err))
                end

                if is_select then
                    local models = ResultMapper.map_to_models(new_model, rows_or_result, select_aliases)
                    callback(models, nil)
                else
                    callback(rows_or_result, nil) -- For DML, return result directly
                end
            end)
            return nil
        else -- Sync mode
                    local success, result_or_error = pcall(function()
                local query_result = ConnectionManager.execute_query(mode, conn, sql, params)
                return query_result
            end)

            new_model._include_soft_deleted = false -- Reset flag after query
            ConnectionManager.release_connection(mode, conn)

            if not success then
                return nil, tostring(result_or_error)
            end

            if is_select then
                return ResultMapper.map_to_models(new_model, result_or_error, select_aliases), nil
            else
                return result_or_error, nil -- For DML, return result directly
            end
        end
    end

    --- Helper to add joins and select related columns for eager loading.
    -- @param qb QueryBuilder The query builder instance.
    -- @param includes table A list of relation names to include (e.g., {"user", "profile"}).
    -- @return table A table describing the models and their prefixes for ResultMapper.
    local function add_joins_and_selects(qb, includes)
        local model_mapping = {
            { model = new_model, prefix = new_model._table_name .. "__" } -- Main model
        }

        -- Select all columns from the main table with a prefix
        local main_select_cols = {}
        for field_name, _ in pairs(new_model._fields) do
            table.insert(main_select_cols, string.format("%s.%s AS %s%s", new_model._table_name, field_name, new_model._table_name, "__" .. field_name))
        end
        qb:select(main_select_cols)
        if includes and type(includes) == "table" and #includes > 0 then
            for _, relation_name in ipairs(includes) do
                local relation_def = new_model._relations[relation_name]
                if relation_def then
                    -- Dynamically load the related model class
                    local related_model_class = require("db.init_models")[relation_def.model_name] -- Adjust path as needed

                    local related_table_name = related_model_class._table_name
                    local related_prefix = related_table_name .. "__"

                    -- Add JOIN clause
                    qb:join(relation_def.join_type, related_table_name,
                            string.format("%s.%s = %s.%s",
                                new_model._table_name, relation_def.local_key,
                                related_table_name, relation_def.foreign_key))

                    -- Add related model's columns to select with a prefix
                    local related_select_cols = {}
                    for field_name, _ in pairs(related_model_class._fields) do
                        table.insert(related_select_cols, string.format("%s.%s AS %s%s", related_table_name, field_name, related_prefix, field_name))
                    end
                    -- Append related model's columns to the main query's select

                    -- append related_select_cols to qb._select_columns

                    -- qb._select_columns = qb._select_columns or {}    
                    -- Ensure qb._select_columns is initialized
                    if not qb._select_columns then
                        qb._select_columns = {}
                    end
                    -- Append related columns to the existing select columns
                    for _, col in ipairs(related_select_cols) do
                        table.insert(qb._select_columns, col)
                    end

                    -- table.insert(qb._select_columns, related_select_cols)                    
                    qb:select(qb._select_columns) -- Append to existing select

                    table.insert(model_mapping, { model = related_model_class, prefix = related_prefix, relation_name = relation_name })
                else
                    print(string.format("Warning: Relation '%s' not found in model '%s'.", relation_name, new_model._table_name))
                end
            end
        end
        return model_mapping
    end

    --- Creates a new record in the database and returns a new model instance.
    -- @param data table A table where keys are column names and values are the data to insert.
    -- @param callback function|nil Optional callback for async mode.
    -- @return table|nil A new model instance representing the created record, with its actual primary key (sync only).
    -- @return string|nil An error message if the operation fails (sync only).
    function new_model:create(data, callback)
        if not data or type(data) ~= "table" or next(data) == nil then
            return nil, "Invalid data provided for create operation. Must be a non-empty table."
        end

        local insert_data = {}

        -- Filter fields to insert only defined schema fields and perform basic type validation/casting
        for field_name, field_def in pairs(self._fields) do
            if data[field_name] ~= nil then
                -- Basic type validation/casting (can be expanded)
                if field_def == "boolean" then
                    insert_data[field_name] = data[field_name] and 1 or 0 -- Convert Lua boolean to 0/1 for DB
                else
                    insert_data[field_name] = data[field_name]
                end
            end
        end

        -- set created_at to current time if it exists in the schema
        if self._fields["created_at"] then
            insert_data["created_at"] = os.date("!%Y-%m-%d %H:%M:%S") -- UTC ISO format
        end

        -- Handle auto-generated primary key (if it's an integer and not provided)
        if self._primary_key and self._fields[self._primary_key] == "integer" and data[self._primary_key] == nil then
            -- Do not include the primary key in insert_data; let the DB auto-generate
        else
            insert_data[self._primary_key] = data[self._primary_key] -- Include if explicitly provided
        end

        local query_builder = QueryBuilder.new(self._table_name, self._connection_mode, new_model):insert(insert_data)
        local sql, params = query_builder:to_sql()

     

        -- Add RETURNING clause for primary key if available and it's an integer type
        if self._primary_key and self._fields[self._primary_key] == "integer" then
            sql = sql:gsub(";", "") .. " RETURNING " .. self._primary_key .. ";"
        end

        -- check if connection mode is async or sync
        if new_model._connection_mode == "async" and type(callback) ~= "function" then
            return nil, "Callback function must be provided in async mode."
        end 
        -- Execute the query
        -- Use the helper function to execute the query
        if new_model._connection_mode == "async" then
            if type(callback) ~= "function" then
                return nil, "Callback function must be provided in async mode."
            end

            return execute_query_helper(sql, params, function(result, err)
            if err then return callback(nil, err) end

            local created_instance_data = data
            if result and result[1] and result[1][self._primary_key] then
                created_instance_data[self._primary_key] = result[1][self._primary_key]
            end
            callback(self:new(created_instance_data), nil)
        end, false) -- is_select = false for DML
        else
            -- In sync mode, we can directly return the result
            local result, err = execute_query_helper(sql, params, nil, false) -- is_select = false for DML
            if err then return nil, err end

            local created_instance_data = data
            if result and result[1] and result[1][self._primary_key] then
                created_instance_data[self._primary_key] = result[1][self._primary_key]
            end
            return self:new(created_instance_data), nil
        end
    end

    --- Finds a record by its primary key.
    -- @param id mixed The value of the primary key to search for.
    -- @param opts table (Optional) Options including `includes` for eager loading.
    -- @param callback function|nil Optional callback for async mode.
    -- @return table|nil A model instance if found, otherwise nil (sync only).
    -- @return string|nil An error message if the operation fails (sync only).
    function new_model:find(id, opts, callback)
        -- Handle optional opts and callback
        if type(opts) == "function" then
            callback = opts
            opts = {}
        else
            opts = opts or {}
        end

        local query_builder = QueryBuilder.new(self._table_name, self._connection_mode, new_model)
                                    :where(self._table_name.."."..self._primary_key, "=", id)
                                    :limit(1)

        -- Apply soft delete filter if 'deleted_at' field exists and not explicitly including soft deleted records
        if self._fields["deleted_at"] and not self._include_soft_deleted then
            query_builder:where(self._table_name..".deleted_at", "IS", "NULL")
        end

         local model_mapping = nil
        local includes = {}

        if self._include_relations and self._relations then 

            for _k, _v in pairs(self._relations) do
                -- Add the relation to the includes list
                if self:contains(includes, _v.model_name) then
                -- If the model is already included, skip adding it again
                else
                table.insert(includes, _v.model_name)
                end
            end
        end

         model_mapping = add_joins_and_selects(query_builder, includes)
        local sql, params = query_builder:to_sql()

        return execute_query_helper(sql, params, function(models, err)
            if err then return callback(nil, err) end
            callback(models[1], nil)
        end, true, model_mapping) -- is_select = true
    end

    --- Finds a record by one or more column values.
    -- @param criteria table A key-value table of column names and their desired values.
    -- @param opts table (Optional) Options including `includes` for eager loading.
    -- @param callback function|nil Optional callback for async mode.
    -- @return table|nil A model instance if found (sync only).
    -- @return string|nil An error message if the operation fails (sync only).
    function new_model:find_by(criteria, opts, callback)
        -- Handle optional opts and callback
        if type(opts) == "function" then
            callback = opts
            opts = {}
        else
            opts = opts or {}
        end

        if type(criteria) ~= "table" or next(criteria) == nil then
            return nil, "find_by expects a non-empty table of criteria."
        end

        local query_builder = QueryBuilder.new(self._table_name, self._connection_mode, new_model)

        for col, value in pairs(criteria) do
            query_builder:where(self._table_name.."."..col, "=", value)
        end

        -- Apply soft delete filter if 'deleted_at' field exists and not explicitly including soft deleted records
        if self._fields["deleted_at"] and not self._include_soft_deleted then
            query_builder:where(self._table_name..".deleted_at", "IS", "NULL")
        end

        query_builder:limit(1)
         local model_mapping = nil
        local includes = {}

        if self._include_relations and self._relations then 

            for _k, _v in pairs(self._relations) do
                -- Add the relation to the includes list
                if self:contains(includes, _v.model_name) then
                -- If the model is already included, skip adding it again
                else
                table.insert(includes, _v.model_name)
                end
            end
        end
         model_mapping = add_joins_and_selects(query_builder, includes)
        local sql, params = query_builder:to_sql()

        return execute_query_helper(sql, params, function(models, err)
            if err then return callback(nil, err) end
            callback(models[1], nil)
        end, true, model_mapping)
    end

    --- Finds all records matching one or more column values.
    -- @param criteria table A key-value table of column names and their desired values.
    -- @param opts table (Optional) Options including `includes` for eager loading.
    -- @param callback function|nil Optional callback for async mode.
    -- @return table|nil A list of model instances (sync only).
    -- @return string|nil An error message if the operation fails (sync only).
    function new_model:find_all_by(criteria, opts, callback)
        -- Handle optional opts and callback
        if type(opts) == "function" then
            callback = opts
            opts = {}
        else
            opts = opts or {}
        end

        if type(criteria) ~= "table" or next(criteria) == nil then
            return nil, "find_all_by expects a non-empty table of criteria."
        end

        local query_builder = QueryBuilder.new(self._table_name, self._connection_mode, new_model)

        for col, value in pairs(criteria) do
            query_builder:where(self._table_name.."."..col, "=", value)
        end

        -- Apply soft delete filter if 'deleted_at' field exists and not explicitly including soft deleted records
        if self._fields["deleted_at"] and not self._include_soft_deleted then
            query_builder:where(self._table_name..".deleted_at", "IS", "NULL")
        end

         local model_mapping = nil
        local includes = {}

        if opts.include_relations and self._relations then 

            for _k, _v in pairs(self._relations) do
                -- Add the relation to the includes list
                if self:contains(includes, _v.model_name) then
                -- If the model is already included, skip adding it again
                else
                table.insert(includes, _v.model_name)
                end
            end
        end

        model_mapping = add_joins_and_selects(query_builder, includes)
        local sql, params = query_builder:to_sql()

        return execute_query_helper(sql, params, function(models, err)
            if err then return callback(nil, err) end
            callback(models, nil)
        end, true, model_mapping)
    end

    --- Finds all records matching advanced conditions.
    -- @param conditions table A list of condition tuples { {col, op, value}, ... }
    -- @param opts table (Optional) Options including `includes` for eager loading.
    -- @param callback function|nil Optional callback for async mode.
    -- @return table|nil A list of model instances (sync only).
    -- @return string|nil An error message if the operation fails (sync only).
    function new_model:find_where(conditions, opts, callback)
        -- Handle optional opts and callback
        if type(opts) == "function" then
            callback = opts
            opts = {}
        else
            opts = opts or {}
        end

        if type(conditions) ~= "table" or #conditions == 0 then
            return nil, "find_where expects a non-empty array of condition triplets {col, op, value}"
        end

        local query_builder = QueryBuilder.new(self._table_name, self._connection_mode, new_model)

        for _, condition in ipairs(conditions) do
            local col, op, val = unpack(condition)
            if not (col and op and val ~= nil) then
                return nil, "Each condition must be {column, operator, value}"
            end
            query_builder:where(self._table_name.."."..col, op, val)
        end

        -- Apply soft delete filter if 'deleted_at' field exists and not explicitly including soft deleted records
        if self._fields["deleted_at"] and not self._include_soft_deleted then
            query_builder:where(self._table_name..".deleted_at", "IS", "NULL")
        end

         local model_mapping = nil
        local includes = {}

        if opts.include_relations and self._relations then 

            for _k, _v in pairs(self._relations) do
                -- Add the relation to the includes list
                if self:contains(includes, _v.model_name) then
                -- If the model is already included, skip adding it again
                else
                table.insert(includes, _v.model_name)
                end
            end
        end

         model_mapping = add_joins_and_selects(query_builder, includes)
        local sql, params = query_builder:to_sql()

        return execute_query_helper(sql, params, function(models, err)
            if err then return callback(nil, err) end
            callback(models, nil)
        end, true, model_mapping)
    end

    --- Starts a query chain for this model.
    -- @return table A new QueryBuilder instance configured for this model's table.
    function new_model:query()
        -- Pass the model's connection mode AND the model class itself to the QueryBuilder
        return QueryBuilder.new(self._table_name, self._connection_mode, new_model)
    end

    --- Saves the current model instance to the database.
    -- If the primary key is set, it performs an UPDATE; otherwise, it performs an INSERT.
    -- @param callback function|nil Optional callback for async mode.
    -- @return boolean|nil True if save was successful (sync only).
    -- @return string|nil An error message if the operation fails (sync only).
    function new_model:save(callback)
        local primary_key_value = self[self._primary_key]
        local is_insert = not primary_key_value

        local function build_query_and_data()
            local now = os.date("!%Y-%m-%d %H:%M:%S") -- UTC ISO format
            local data_to_save = {}

            -- Collect all fields from the instance that are defined in the schema
            for field_name, field_def in pairs(self._fields) do
                if self[field_name] ~= nil then
                    -- Basic type validation/casting
                    if field_def == "boolean" then
                        data_to_save[field_name] = self[field_name] and 1 or 0
                    else
                        data_to_save[field_name] = self[field_name]
                    end
                end
            end

            -- Set 'created_at' for new records if the field exists
            if is_insert and self._fields["created_at"] then
                data_to_save["created_at"] = now
            end

            -- Set 'updated_at' for all saves if the field exists
            if self._fields["updated_at"] then
                data_to_save["updated_at"] = now
            end

            -- Remove primary key from data_to_save for updates if it's an auto-incrementing integer
            if not is_insert and self._fields[self._primary_key] == "integer" then
                data_to_save[self._primary_key] = nil
            end

            local query_builder
            if is_insert then
                query_builder = QueryBuilder.new(self._table_name, self._connection_mode, new_model)
                                    :insert(data_to_save)
            else
                query_builder = QueryBuilder.new(self._table_name, self._connection_mode, new_model)
                                    :update(data_to_save)
                                    :where(self._primary_key, "=", primary_key_value)
            end

            -- For inserts, if primary key is auto-generated, add RETURNING clause
            local sql, params = query_builder:to_sql()
            if is_insert and self._primary_key and self._fields[self._primary_key] == "integer" then
                sql = sql:gsub(";", "") .. " RETURNING " .. self._primary_key .. ";"
            end

            return sql, params, is_insert
        end

        local sql, params, is_insert_query = build_query_and_data()

        return execute_query_helper(sql, params, function(result, err)
            if err then return callback(nil, err) end

            -- If it was an insert and a primary key was returned, update the instance
            if is_insert_query and result and result[1] and result[1][self._primary_key] then
                self[self._primary_key] = result[1][self._primary_key]
            end
            callback(true, nil)
        end, false) -- is_select = false for DML
    end

    --- Deletes the current model instance from the database.
    -- Requires the primary key to be set on the instance.
    -- Performs a soft delete if `deleted_at` field exists and `_include_soft_deleted` is false.
    -- Otherwise, performs a hard delete.
    -- @param callback function|nil Optional callback for async mode.
    -- @return boolean|nil True if delete was successful (sync only).
    -- @return string|nil An error message if the operation fails (sync only).
    function new_model:delete(callback)
        local primary_key_value = self[self._primary_key]
        if not primary_key_value then
            return nil, "Cannot delete record: Primary key is not set on the model instance."
        end

        local function build_delete_query()
            local qb = QueryBuilder.new(self._table_name, self._connection_mode, new_model)
            -- Check for soft delete capability and if soft delete is not explicitly bypassed
            if self._fields["deleted_at"] and not self._include_soft_deleted then
                -- Soft delete: update `deleted_at` timestamp
                local now = os.date("!%Y-%m-%d %H:%M:%S")
                qb:update({ deleted_at = now })
            else
                -- Hard delete: delete the record
                qb:delete()
            end
            qb:where(self._table_name.."."..self._primary_key, "=", primary_key_value)
            return qb:to_sql()
        end

        local sql, params = build_delete_query()

        return execute_query_helper(sql, params, function(result, err)
            if err then return callback(nil, err) end
            callback(true, nil)
        end, false) -- is_select = false for DML
    end

    function new_model:contains(list, value)
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

    --- Fetches all records for the model.
    -- Applies soft delete filter by default if 'deleted_at' field exists.
    -- @param opts table (Optional) Options including `includes` for eager loading.
    -- @param callback function|nil Optional callback for async mode.
    -- @return table|nil A list of model instances (sync only).
    -- @return string|nil An error message if the operation fails (sync only).
    function new_model:all(opts, callback)
        -- Handle optional opts and callback
        if type(opts) == "function" then
            callback = opts
            opts = {}
        else
            opts = opts or {}
        end

        local query_builder = QueryBuilder.new(self._table_name, self._connection_mode, new_model)
        if self._fields["deleted_at"] and not self._include_soft_deleted then
            query_builder:where(self._table_name..".deleted_at", "IS", "NULL")
        end

        local model_mapping = nil
        local includes = {}

        if opts.include_relations and self._relations then 

            for _k, _v in pairs(self._relations) do
                -- Add the relation to the includes list
                if self:contains(includes, _v.model_name) then
                -- If the model is already included, skip adding it again
                else
                table.insert(includes, _v.model_name)
                end
            end
        end
      
        model_mapping = add_joins_and_selects(query_builder, includes)
        local sql, params = query_builder:to_sql()
        return execute_query_helper(sql, params, function(models, err)
            if err then return callback(nil, err) end
            callback(models, nil)
        end, true, model_mapping)
    end

    --- Fetches records based on a simple key-value filter.
    -- Applies soft delete filter by default if 'deleted_at' field exists.
    -- @param filters table A table where keys are column names and their desired values.
    -- @param opts table (Optional) Options including `includes` for eager loading.
    -- @param callback function|nil Optional callback for async mode.
    -- @return table|nil A list of model instances (sync only).
    -- @return string|nil An error message if the operation fails (sync only).
    function new_model:where(filters, opts, callback)
        -- Handle optional opts and callback
        if type(opts) == "function" then
            callback = opts
            opts = {}
        else
            opts = opts or {}
        end

        local query_builder = QueryBuilder.new(self._table_name, self._connection_mode, new_model)
        for k, v in pairs(filters) do
            query_builder:where(self._table_name.."."..k, "=", v)
        end
        -- Apply soft delete filter if 'deleted_at' field exists and not explicitly including soft deleted records
        if self._fields["deleted_at"] and not self._include_soft_deleted then
            query_builder:where(self._table_name..".deleted_at", "IS", "NULL")
        end

         local model_mapping = nil
        local includes = {}

        if opts.include_relations and self._relations then 

            for _k, _v in pairs(self._relations) do
                -- Add the relation to the includes list
                if self:contains(includes, _v.model_name) then
                -- If the model is already included, skip adding it again
                else
                table.insert(includes, _v.model_name)
                end
            end
        end
      
        model_mapping = add_joins_and_selects(query_builder, includes)
        local sql, params = query_builder:to_sql()

        return execute_query_helper(sql, params, function(models, err)
            if err then return callback(nil, err) end
            callback(models, nil)
        end, true, model_mapping)
    end

    --- Paginates results.
    -- Applies soft delete filter by default if 'deleted_at' field exists.
    -- @param page number The page number (1-based).
    -- @param per_page number Number of items per page.
    -- @param opts table (Optional) Options including `includes` for eager loading.
    -- @param callback function (optional) For async mode.
    -- @return table|nil A table with `items`, `page`, `per_page`, `total`, `pages` or calls the callback.
    -- @return string|nil An error message if the operation fails (sync only).
    function new_model:paginate(page, per_page, opts, callback)
        -- Handle optional opts and callback
        if type(opts) == "function" then
            callback = opts
            opts = {}
        else
            opts = opts or {}
        end

        assert(type(page) == "number" and page >= 1, "Invalid page number")
        assert(type(per_page) == "number" and per_page > 0, "Invalid per_page")

        local offset = (page - 1) * per_page

         local model_mapping = nil
        local includes = {}

        if opts.include_relations and self._relations then 

            for _k, _v in pairs(self._relations) do
                -- Add the relation to the includes list
                if self:contains(includes, _v.model_name) then
                -- If the model is already included, skip adding it again
                else
                table.insert(includes, _v.model_name)
                end
            end
        end

        local function build_paginated_query(is_count_query)
            local qb = QueryBuilder.new(self._table_name, self._connection_mode, new_model)


            -- Apply soft delete filter if 'deleted_at' field exists and not explicitly including soft deleted records
            if self._fields["deleted_at"] and not self._include_soft_deleted then
                qb:where(self._table_name..".deleted_at", "IS", "NULL")
            end

         

            if is_count_query then
                qb:count()
            else
       
      
        -- model_mapping = add_joins_and_selects(query_builder, includes)
                add_joins_and_selects(qb, includes) -- Add joins and selects for main query
                qb:limit(per_page):offset(offset)
            end
            return qb:to_sql()
        end

        local sql, params = build_paginated_query(false)
        local count_sql, count_params = build_paginated_query(true)

        if self._connection_mode == "async" then
            if type(callback) ~= "function" then
                error("Callback function is required in async mode")
            end

            local result_data = {}
            execute_query_helper(count_sql, count_params, function(count_rows, err1)
                if err1 then return callback(nil, err1) end
                local total = count_rows[1].count or 0
                result_data.total = total
                result_data.pages = math.ceil(total / per_page)
                result_data.page = page
                result_data.per_page = per_page

                execute_query_helper(sql, params, function(rows, err2)
                    if err2 then return callback(nil, err2) end
                    result_data.items = rows
                    callback(result_data, nil)
                end, true, add_joins_and_selects(QueryBuilder.new(self._table_name, self._connection_mode, new_model), includes))
            end, true) -- is_select = true for count query
            return nil
        else -- Sync mode
            local success, count_rows_or_err = execute_query_helper(count_sql, count_params, nil, true)
            if not success then return nil, count_rows_or_err end
            local total = count_rows_or_err[1].count or 0

            local success_items, rows_or_err = execute_query_helper(sql, params, nil, true, add_joins_and_selects(QueryBuilder.new(self._table_name, self._connection_mode, new_model), includes))
            if not success_items then return nil, rows_or_err end

            return {
                items = rows_or_err,
                page = page,
                per_page = per_page,
                total = total,
                pages = math.ceil(total / per_page),
            }, nil
        end
    end

    --- Paginates with filters, ordering, and soft-deleted support.
    -- @param opts table Options: { page, per_page, where, order_by, include_deleted, includes }
    --   - `page`: number (1-based, for offset-based pagination)
    --   - `per_page`: number (items per page)
    --   - `where`: table (key-value for simple equality filters)
    --   - `order_by`: table (list of { column = string, direction = string })
    --   - `include_deleted`: boolean (if true, includes soft-deleted records)
    --   - `includes`: table (list of relation names for eager loading)
    -- @param callback function (optional) For async mode.
    -- @return table|nil Paginated result or async callback
    -- @return string|nil An error message if the operation fails (sync only).
    function new_model:paginate_with(opts, callback)
        opts = opts or {}
        local page = opts.page or 1
        local per_page = opts.per_page or 10
        local where_criteria = opts.where or {}
        local order_by_clauses = opts.order_by or {}
        local include_deleted = opts.include_deleted or false
        local includes = opts.includes or {}

        assert(type(page) == "number" and page >= 1, "Invalid page number")
        assert(type(per_page) == "number" and per_page > 0, "Invalid per_page")

        local offset = (page - 1) * per_page

         local model_mapping = nil
        local includes = {}

        if opts.include_relations and self._relations then 

            for _k, _v in pairs(self._relations) do
                -- Add the relation to the includes list
                if self:contains(includes, _v.model_name) then
                -- If the model is already included, skip adding it again
                else
                table.insert(includes, _v.model_name)
                end
            end
        end

        local function build_base_query_builder()
            local qb = QueryBuilder.new(self._table_name, self._connection_mode, new_model)

            -- WHERE clauses
            for col, val in pairs(where_criteria) do
                qb:where(self._table_name.."."..col, "=", val)
            end

            -- Soft delete filter
            if self._fields["deleted_at"] and not include_deleted then
                qb:where(self._table_name..".deleted_at", "IS", "NULL")
            end
            return qb
        end

        local function build_paginated_query(is_count_query)
            local qb = build_base_query_builder()

            if is_count_query then
                qb:count()
            else
                -- ORDER BY
                if order_by_clauses and #order_by_clauses > 0 then
                    for _, order in ipairs(order_by_clauses) do
                        if type(order) == "table" and order.column and order.direction then
                            qb:order_by(order.column, order.direction)
                        else
                            -- Log warning or error if format is incorrect
                            print("Warning: Invalid order_by format. Expected table with 'column' and 'direction'.")
                        end
                    end
                else
                    -- Default ordering by primary key if no order_by specified
                    qb:order_by(self._primary_key, "asc")
                end
                qb:limit(per_page):offset(offset)
            end
            return qb
        end

        local main_qb = build_paginated_query(false)
        model_mapping = add_joins_and_selects(main_qb, includes) -- Add joins and selects for main query

        local sql, params = main_qb:to_sql()
        local count_sql, count_params = build_paginated_query(true):to_sql()

        if self._connection_mode == "async" then
            if type(callback) ~= "function" then
                error("Callback function is required in async mode")
            end

            local result_data = {}
            execute_query_helper(count_sql, count_params, function(count_rows, err1)
                if err1 then return callback(nil, err1) end

                local total = count_rows and count_rows[1] and count_rows[1].count or 0
                result_data.total = total
                result_data.page = page
                result_data.per_page = per_page
                result_data.pages = math.ceil(total / per_page)

                if total == 0 then
                    result_data.items = {}
                    return callback(result_data, nil)
                end

                execute_query_helper(sql, params, function(rows, err2)
                    if err2 then return callback(nil, err2) end
                    result_data.items = rows
                    callback(result_data, nil)
                end, true, model_mapping)
            end, true)
            return nil
        else -- Sync mode
            local count_rows, err_count = execute_query_helper(count_sql, count_params, nil, true)
            if err_count then return nil, err_count end

            local total = tonumber(count_rows and count_rows[1] and count_rows[1].count or 0)
            if total == 0 then
                return {
                    items = {},
                    page = page,
                    per_page = per_page,
                    total = total,
                    pages = 0,
                }, nil
            end

            local items, err_items
            if total > 0 then
                items, err_items = execute_query_helper(sql, params, nil, true, model_mapping)
                if err_items then return nil, err_items end
            else
                items = {}
            end

            return {
                items = items,
                page = page,
                per_page = per_page,
                total = total,
                pages = math.ceil(total / per_page),
            }, nil
        end
    end

    --- Paginates with advanced options including search, filters, cursor-based pagination, and caching.
    -- @param opts table Options: { page, per_page, search, sort_by, sort_dir, filters, cursor, cache_key, use_async, on_result, includes }
    --   - `page`: number (1-based, for offset-based pagination)
    --   - `per_page`: number (items per page)
    --   - `search`: table (key-value for simple LIKE search, or `fts` table for full-text search)
    --     - `search.fts`: table { config: string, fields: table, query: string } for full-text search
    --   - `sort_by`: string (column to sort by)
    --   - `sort_dir`: string ("asc" or "desc")
    --   - `filters`: table (key-value, where key is filter name and value is boolean to enable/disable)
    --   - `cursor`: table { after: mixed, sort_by: string } for cursor-based pagination
    --   - `cache_key`: string (key for caching the result)
    --   - `use_async`: boolean (if true, function uses coroutines for async execution)
    --   - `on_result`: function (callback required if async)
    --   - `includes`: table (list of relation names for eager loading)
    -- @return table Paginated result: { data: table, meta: table }
    -- @raise error If any query operation fails or if async is used outside a coroutine.
    function new_model:paginate_with_advanced(opts)
        opts = opts or {}
        local page = opts.page or 1
        local per_page = opts.per_page or 10
        local search = opts.search or {}
        local sort_by = opts.sort_by or self._primary_key
        local sort_dir = opts.sort_dir or "asc"
        local filters = opts.filters or {}
        local cursor = opts.cursor or {}
        local cache_key = opts.cache_key
        local use_async = opts.use_async or false
        local on_result = opts.on_result -- callback (required if async)
        local includes = opts.includes or {}

        local offset = (page - 1) * per_page
        if cursor.after then
            offset = nil
        end

         local model_mapping = nil
        local includes = {}

        if opts.include_relations and self._relations then 

            for _k, _v in pairs(self._relations) do
                -- Add the relation to the includes list
                if self:contains(includes, _v.model_name) then
                -- If the model is already included, skip adding it again
                else
                table.insert(includes, _v.model_name)
                end
            end
        end

        local function build_base_query_builder()
            local qb = QueryBuilder.new(self._table_name, self._connection_mode, new_model)

            if cursor.after then
                qb:where(self._table_name.."."..cursor.sort_by or self._table_name.."."..self._primary_key, ">", cursor.after)
            end

            if search.fts then
                local fts_config = search.fts.config or "english"
                local fts_fields = table.concat(search.fts.fields, " || ' ' || ")
                local fts_query = search.fts.query
                -- IMPORTANT: Use parameterized query for fts_query to prevent SQL injection
                local expr = string.format("to_tsvector('%s', %s) @@ plainto_tsquery('%s', ?)",
                                           fts_config, fts_fields, fts_config)
                qb:where_raw(expr, {fts_query}) -- Pass fts_query as a parameter
            else
                for col, keyword in pairs(search) do
                    qb:where(self._table_name.."."..col, "ILIKE", "%" .. keyword .. "%")
                end
            end

            for name, enabled in pairs(filters) do
                if enabled and self._filter_presets and self._filter_presets[name] then
                    self._filter_presets[name](qb)
                end
            end

            if self._fields["deleted_at"] and not opts.include_deleted then
                qb:where(self._table_name..".deleted_at", "IS", "NULL")
            end
            return qb
        end

        local function build_main_query()
            local qb = build_base_query_builder()
            qb:order_by(sort_by, sort_dir)
            if offset then qb:offset(offset) end
            qb:limit(per_page + 1) -- Fetch one extra to check for next page
            return qb
        end

        local function build_count_query()
            local qb = build_base_query_builder()
            qb:count()
            return qb
        end

        local function parse_result(rows)
            if not rows or #rows == 0 then
                return {
                    data = {},
                    meta = {
                        page = page,
                        per_page = per_page,
                        has_next_page = false,
                        next_cursor = nil,
                        total_count = 0
                    }
                }
            end

            -- Pass model_mapping to ResultMapper
             model_mapping = add_joins_and_selects(QueryBuilder.new(self._table_name, self._connection_mode, new_model), includes)
            local instances = ResultMapper.map_to_models(self, rows, model_mapping)

            local has_next_page = #instances > per_page
            if has_next_page then
                table.remove(instances) -- Remove the extra item
            end
            local next_cursor = has_next_page and instances[#instances][cursor.sort_by or self._primary_key] or nil

            return {
                data = instances,
                meta = {
                    page = page,
                    per_page = per_page,
                    has_next_page = has_next_page,
                    next_cursor = next_cursor,
                    total_count = nil -- Will be filled by count query
                }
            }
        end

        local function finish_with_result(result)
            if cache_key then
                CacheManager.set(cache_key, result, 60)
            end
            if use_async and on_result then
                on_result(result)
            else
                return result
            end
        end

        local function execute_paginated()
            local main_qb = build_main_query()
            model_mapping = add_joins_and_selects(main_qb, includes) -- Get mapping for main query

            local sql, params = main_qb:to_sql()

            if use_async then
                execute_query_helper(sql, params, function(rows, err)
                    if err then error("Failed to execute main query: " .. tostring(err)) end

                    local result = parse_result(rows)

                    if not cursor.after then
                        local count_qb = build_count_query()
                        local count_sql, count_params = count_qb:to_sql()
                        execute_query_helper(count_sql, count_params, function(count_rows, err_count)
                            if err_count then error("Failed to execute count query: " .. tostring(err_count)) end
                            result.meta.total_count = tonumber(count_rows[1].count) or 0
                            finish_with_result(result)
                        end, true)
                    else
                        finish_with_result(result)
                    end
                end, true, model_mapping) -- is_select = true, pass model_mapping
            else
                local rows, err_rows = execute_query_helper(sql, params, nil, true, model_mapping)
                if err_rows then error("Failed to execute main query: " .. tostring(err_rows)) end

                local result = parse_result(rows)
                if not cursor.after then
                    local count_qb = build_count_query()
                    local count_sql, count_params = count_qb:to_sql()
                    local count_rows, err_count = execute_query_helper(count_sql, count_params, nil, true)
                    if err_count then error("Failed to execute count query: " .. tostring(err_count)) end
                    result.meta.total_count = tonumber(count_rows[1].count) or 0
                end
                return finish_with_result(result)
            end
        end

        if cache_key then
            local cached = CacheManager.get(cache_key)
            if cached then
                if use_async and on_result then
                    return on_result(cached)
                else
                    return cached
                end
            end
        end

        return execute_paginated()
    end

    --- Sets an internal flag to include soft-deleted records in subsequent queries.
    -- This method returns `self` to allow for method chaining.
    -- The flag is reset after each query execution.
    -- @return table The model class itself.
    function new_model:with_soft_deleted()
        self._include_soft_deleted = true
        return self
    end

    -- Return the new model class. Its __index is already set to the base Model.
    return new_model
end

return Model
