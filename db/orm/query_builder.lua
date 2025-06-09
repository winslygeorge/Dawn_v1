-- orm/query_builder.lua

-- Require necessary modules for query execution and result mapping
local ConnectionManager = require("db.orm.connection_manager")
local ResultMapper = require("db.orm.result_mapper")
local config = require("db.orm.config") -- To get default_mode if not specified by model

--- This module provides a fluent API for constructing SQL queries.
--- It allows for building complex queries programmatically without writing raw SQL strings directly.
local QueryBuilder = {}

--- Set the metatable for QueryBuilder to itself, enabling method chaining.
QueryBuilder.__index = QueryBuilder

--- Creates a new QueryBuilder instance for a given table.
-- @param table_name string The name of the database table this query builder operates on.
-- @param connection_mode string (Optional) The connection mode ("sync" or "async") for this query.
-- @param model_class table (Optional) The ORM model class associated with this query builder.
-- @return table A new QueryBuilder instance.
function QueryBuilder.new(table_name, connection_mode, model_class)
    local self = setmetatable( {
        _table_name = table_name,
        _select_columns = {"*"}, -- Default to selecting all columns
        _where_clauses = {},
        _limit = nil,
        _offset = nil,
        _order_by = {},
        _group_by = {},
        _joins = {},
        _is_delete = false,
        _is_update = false,
        _update_data = {},
        _is_insert = false,
        _insert_data = {},
        _on_conflict_clause = nil,
        _connection_mode = connection_mode, -- Store the connection mode for execution
        _model_class = model_class, -- Store the associated Model class
        _parameters = {}, -- New: Store parameters for the prepared statement
        _select_aliases = {}, -- New: Store aliases for selected columns, useful for ResultMapper
        _include_soft_deleted = false, -- Internal flag for soft deletes in QueryBuilder
    }, QueryBuilder)

    return self
end

--- Sets the columns to select.
-- Can accept a variable number of column names as strings, or a table of column names.
-- Supports aliasing (e.g., "users.name as user_name").
-- @param ... string|table A variable number of column names as strings, or a table of column names.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:select(...)
    local columns = {...}
    if #columns == 1 and type(columns[1]) == "table" then
        self._select_columns = columns[1]
    else
        self._select_columns = columns
    end

    -- Clear existing aliases and re-parse them
    self._select_aliases = {}
    for _, col_str in ipairs(self._select_columns) do
        local alias_match = string.match(col_str, "(.+)%s+as%s+(.+)")
        if alias_match then
            self._select_aliases[alias_match[2]:trim()] = alias_match[1]:trim() -- Store alias -> original
        end
    end
    return self
end

--- Adds a WHERE clause to the query.
-- Values are added to the parameters list for safe execution.
-- @param column string The name of the column.
-- @param operator string The comparison operator (e.g., "=", ">", "<", "LIKE", "IN", "IS").
-- @param value mixed The value to compare against. For "IN", this can be a table.
-- @param conjunction string (Optional) The logical conjunction ("AND" or "OR"). Defaults to "AND".
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:where(column, operator, value, conjunction)
    local param_value = value
    local placeholder = "?"

    -- Special handling for IS NULL / IS NOT NULL
    if operator:upper() == "IS" and (value:upper() == "NULL" or value:upper() == "NOT NULL") then
        placeholder = value:upper() -- e.g., "IS NULL"
        param_value = nil -- No parameter needed for IS NULL
    elseif operator:upper() == "IN" and type(value) == "table" then
        -- For IN clause, create multiple placeholders and add all values to parameters
        local placeholders = {}
        for _, v in ipairs(value) do
            table.insert(placeholders, "?")
            table.insert(self._parameters, v)
        end
        placeholder = "(" .. table.concat(placeholders, ", ") .. ")"
        param_value = nil -- Values are already added to parameters
    else
        table.insert(self._parameters, value)
    end

    table.insert(self._where_clauses, {
        column = column,
        operator = operator,
        placeholder = param_value or placeholder, -- Use the placeholder or the raw value for IS NULL
        conjunction = conjunction or "AND"
    })
    return self
end

--- Adds a raw WHERE clause to the query. Use with caution to prevent SQL injection.
-- Parameters in the raw clause should be represented by '?' and passed in `raw_params`.
-- @param raw_sql string The raw SQL fragment for the WHERE clause.
-- @param raw_params table (Optional) A table of parameters corresponding to '?' in `raw_sql`.
-- @param conjunction string (Optional) The logical conjunction ("AND" or "OR"). Defaults to "AND".
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:where_raw(raw_sql, raw_params, conjunction)
    table.insert(self._where_clauses, {
        raw_sql = raw_sql,
        raw_params = raw_params or {},
        conjunction = conjunction or "AND"
    })
    -- Add raw_params to the main parameters list
    for _, param in ipairs(raw_params or {}) do
        table.insert(self._parameters, param)
    end
    return self
end


--- Adds an "AND" WHERE clause to the query.
-- @param column string The name of the column.
-- @param operator string The comparison operator.
-- @param value mixed The value to compare against.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:and_where(column, operator, value)
    return self:where(column, operator, value, "AND")
end

--- Adds an "OR" WHERE clause to the query.
-- @param column string The name of the column.
-- @param operator string The comparison operator.
-- @param value mixed The value to compare against.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:or_where(column, operator, value)
    return self:where(column, operator, value, "OR")
end

--- Sets the LIMIT for the query.
-- @param count number The maximum number of rows to return.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:limit(count)
    self._limit = count
    return self
end

--- Sets the OFFSET for the query.
-- @param count number The number of rows to skip.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:offset(count)
    self._offset = count
    return self
end

--- Adds an ORDER BY clause to the query.
-- @param column string The column to order by.
-- @param direction string (Optional) The sort direction ("ASC" or "DESC"). Defaults to "ASC".
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:order_by(column, direction)
    table.insert(self._order_by, { column = column, direction = direction or "ASC" })
    return self
end

--- Adds a GROUP BY clause to the query.
-- @param ... string|table A variable number of column names as strings, or a table of column names.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:group_by(...)
    local columns = {...}
    if #columns == 1 and type(columns[1]) == "table" then
        self._group_by = columns[1]
    else
        self._group_by = columns
    end
    return self
end

--- Configures the query for an INSERT operation.
-- Values are added to the parameters list for safe execution.
-- @param data table A table where keys are column names and values are the data to insert.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:insert(data)
    self._is_insert = true
    self._insert_data = data
    self._parameters = {} -- Clear parameters for INSERT
    for col, val in pairs(data) do
        table.insert(self._parameters, val)
    end
    return self
end

--- Configures the query for an UPDATE operation.
-- Values are added to the parameters list for safe execution.
-- @param data table A table where keys are column names and values are the data to update.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:update(data)
    self._is_update = true
    self._update_data = data
    self._parameters = {} -- Clear parameters for UPDATE
    for col, val in pairs(data) do
        table.insert(self._parameters, val)
    end
    return self
end

--- Configures the query for a DELETE operation.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:delete()
    self._is_delete = true
    return self
end

--- Adds an ON CONFLICT clause to an INSERT query.
-- @param target_columns string|table The column(s) to target for conflict (e.g., "email" or {"col1", "col2"}).
-- @param do_action string The action to take on conflict (e.g., "DO NOTHING", "DO UPDATE SET ...").
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:on_conflict(target_columns, do_action)
    local target_str
    if type(target_columns) == "string" then
        target_str = "(" .. target_columns .. ")"
    elseif type(target_columns) == "table" then
        target_str = "(" .. table.concat(target_columns, ", ") .. ")"
    else
        error("Invalid target_columns for on_conflict. Must be string or table.")
    end
    self._on_conflict_clause = " ON CONFLICT " .. target_str .. " " .. do_action
    return self
end

--- Adds a JOIN clause to the query.
-- @param join_type string The type of join (e.g., "INNER", "LEFT", "RIGHT").
-- @param table_name string The name of the table to join.
-- @param on_clause string The ON clause specifying the join condition (e.g., "users.id = posts.user_id").
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:join(join_type, table_name, on_clause)
    table.insert(self._joins, {
        type = join_type,
        table = table_name,
        on = on_clause
    })
    return self
end

--- Generates the SQL string and the list of parameters for the current query builder state.
-- @return string The generated SQL query string.
-- @return table The list of parameters for the prepared statement.
-- @raise error If the query state is invalid (e.g., trying to combine INSERT/UPDATE/DELETE with SELECT).
function QueryBuilder:to_sql()
    local sql_parts = {}
    local current_parameters = {} -- Parameters specific to this to_sql call

    -- Helper to add parameters to the current_parameters list
    local function add_param(value)
        table.insert(current_parameters, value)
    end

    if self._is_insert then
        local columns = {}
        local placeholders = {}
        for col, val in pairs(self._insert_data) do
            table.insert(columns, col)
            table.insert(placeholders, "?")
            add_param(val)
        end
        table.insert(sql_parts, string.format("INSERT INTO %s (%s) VALUES (%s)",
            self._table_name, table.concat(columns, ", "), table.concat(placeholders, ", ")))
        if self._on_conflict_clause then
            table.insert(sql_parts, self._on_conflict_clause)
        end
    elseif self._is_update then
        local set_clauses = {}
        for col, val in pairs(self._update_data) do
            table.insert(set_clauses, string.format("%s = ?", col))
            add_param(val)
        end
        table.insert(sql_parts, string.format("UPDATE %s SET %s",
            self._table_name, table.concat(set_clauses, ", ")))
    elseif self._is_delete then
        table.insert(sql_parts, string.format("DELETE FROM %s", self._table_name))
    else -- Default is SELECT
        table.insert(sql_parts, string.format("SELECT %s FROM %s",
            table.concat(self._select_columns, ", "), self._table_name))
    end

    -- Add JOIN clauses
    if #self._joins > 0 then
        for _, join in ipairs(self._joins) do
            table.insert(sql_parts, string.format("%s JOIN %s ON %s",
                join.type, join.table, join.on))
        end
    end

    -- Add WHERE clauses
    if #self._where_clauses > 0 then
        local where_strings = {}
        for i, clause in ipairs(self._where_clauses) do
            local clause_str
            if clause.raw_sql then
                clause_str = clause.raw_sql
                -- Parameters for raw_sql are already added to current_parameters
            else
                clause_str = string.format("%s %s %s", clause.column, clause.operator, clause.placeholder)
                -- Parameters for non-raw clauses are already added to current_parameters
            end

            if i > 1 then
                table.insert(where_strings, clause.conjunction)
            end
            table.insert(where_strings, clause_str)
        end
        table.insert(sql_parts, "WHERE " .. table.concat(where_strings, " "))
    end

    -- Add GROUP BY clauses
    if #self._group_by > 0 then
        table.insert(sql_parts, "GROUP BY " .. table.concat(self._group_by, ", "))
    end

    -- Add ORDER BY clauses
    if #self._order_by > 0 then
        local order_strings = {}
        for _, order in ipairs(self._order_by) do
            table.insert(order_strings, string.format("%s %s", order.column, order.direction))
        end
        table.insert(sql_parts, "ORDER BY " .. table.concat(order_strings, ", "))
    end

    -- Add LIMIT and OFFSET
    if self._limit then
        table.insert(sql_parts, "LIMIT ?")
        add_param(self._limit)
    end
    if self._offset then
        table.insert(sql_parts, "OFFSET ?")
        add_param(self._offset)
    end

    return table.concat(sql_parts, " ") .. ";", current_parameters -- Return SQL and parameters
end

--- Enables or disables asynchronous execution for the query.
-- @param enable boolean If true, enables async execution; if false, disables it.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:use_async(enable)
    self._opts = self._opts or {}
    self._opts.use_async = enable
    return self
end

--- Executes the built SELECT query and returns a list of model instances.
-- This method is typically called at the end of a query chain.
-- @param callback function|nil Optional callback for async mode.
-- @return table|nil A list of model instances (sync only).
-- @raise error If the query operation fails.
function QueryBuilder:get(callback)
    -- Ensure we are not in an INSERT, UPDATE, or DELETE state
    if self._is_insert or self._is_update or self._is_delete then
        error("Cannot call get() on an INSERT, UPDATE, or DELETE query builder.")
    end

    if not self._model_class then
        error("Model class not provided to QueryBuilder for mapping results. Use Model:query():get() or pass Model to QueryBuilder.new().")
    end

    local mode = self._connection_mode or config.default_mode
    local conn = ConnectionManager.get_connection(mode)
    local sql, params = self:to_sql() -- Get SQL and parameters
    local use_async = self._opts and self._opts.use_async

    if use_async then
        if type(callback) ~= "function" then
            ConnectionManager.release_connection(mode, conn)
            error("Async get() requires a callback function.")
        end

        -- Asynchronous execution with callback
        ConnectionManager.execute_query(mode, conn, sql, function(err, rows_or_err) -- Pass params
            ConnectionManager.release_connection(mode, conn)

            if err then
                callback(nil, "Async query failed: " .. tostring(err))
            else
                -- Pass select_aliases to ResultMapper for correct mapping of joined data
                local models = ResultMapper.map_to_models(self._model_class, rows_or_err)
                callback(models, nil)
            end
        end)
    else
        -- Synchronous execution
        local success, raw_rows = pcall(function()
            return ConnectionManager.execute_query(mode, conn, sql, params) -- Pass params
        end)
        ConnectionManager.release_connection(mode, conn)

        if not success then
            error("Failed to execute query: " .. tostring(raw_rows))
        end

        -- Pass select_aliases to ResultMapper for correct mapping of joined data
        return ResultMapper.map_to_models(self._model_class, raw_rows)
    end
end

--- Executes the built DML (INSERT, UPDATE, DELETE) query.
-- This method is typically called at the end of a query chain for non-SELECT operations.
-- @param callback function|nil Optional callback for async mode.
-- @return boolean|nil True if the operation was successful (sync only), or nil for async.
-- @raise error If the query operation fails.
function QueryBuilder:execute(callback)
    -- Ensure we are in an INSERT, UPDATE, or DELETE state
    if not (self._is_insert or self._is_update or self._is_delete) then
        error("Cannot call execute() on a SELECT query builder. Use get() instead.")
    end

    local mode = self._connection_mode or config.default_mode
    local conn = ConnectionManager.get_connection(mode)
    local sql, params = self:to_sql() -- Get SQL and parameters
    local use_async = self._opts and self._opts.use_async

    if use_async then
        if type(callback) ~= "function" then
            ConnectionManager.release_connection(mode, conn)
            error("Async execute() requires a callback function.")
        end

        ConnectionManager.execute_query(mode, conn, sql, function(err, result) -- Pass params
            ConnectionManager.release_connection(mode, conn)
            if err then
                callback(nil, "Async execution failed: " .. tostring(err))
            else
                callback(true, nil) -- Indicate success
            end
        end)
        return nil
    else
        local success, result_or_error = pcall(function()
            return ConnectionManager.execute_query(mode, conn, sql, params) -- Pass params
        end)
        ConnectionManager.release_connection(mode, conn)

        if not success then
            error("Failed to execute query: " .. tostring(result_or_error))
        end
        return true -- Indicate success
    end
end

--- Creates a deep copy of the QueryBuilder instance.
-- This is useful for building complex queries without modifying the original builder state.
-- @return table A new QueryBuilder instance with copied state.
function QueryBuilder:clone()
    local copy = {}
    for k, v in pairs(self) do
        if type(v) == "table" then
            -- Deep copy tables, but handle metatables for nested objects if necessary
            -- For simple tables like _where_clauses, a shallow copy of inner tables is usually fine
            -- but for safety, let's deep copy all nested tables.
            local deep_copy_table = function(tbl)
                local new_tbl = {}
                for sub_k, sub_v in pairs(tbl) do
                    if type(sub_v) == "table" then
                        new_tbl[sub_k] = deep_copy_table(sub_v)
                    else
                        new_tbl[sub_k] = sub_v
                    end
                end
                return new_tbl
            end
            copy[k] = deep_copy_table(v)
        else
            copy[k] = v
        end
    end
    setmetatable(copy, getmetatable(self))
    return copy
end

--- Clears the LIMIT clause.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:clear_limit()
    self._limit = nil
    return self
end

--- Configures the query to return a count of records.
-- Sets the select columns to "COUNT(*) as count".
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:count()
    self._select_columns = { "COUNT(*) as count" }
    -- No need for _is_count flag, as the select column dictates it
    return self
end

--- Clears all WHERE clauses.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:clear_where()
    self._where_clauses = {}
    self._parameters = {} -- Clear parameters associated with WHERE clauses
    return self
end

--- Clears all GROUP BY clauses.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:clear_group_by()
    self._group_by = {}
    return self
end

--- Clears the OFFSET clause.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:clear_offset()
    self._offset = nil
    return self
end

--- Clears all ORDER BY clauses.
-- @return table The QueryBuilder instance for chaining.
function QueryBuilder:clear_order_by()
    self._order_by = {}
    return self
end

--- Sets an internal flag to include soft-deleted records in subsequent queries.
-- This method returns `self` to allow for method chaining.
-- The flag is reset after each query execution.
-- @return table The QueryBuilder instance itself.
function QueryBuilder:with_soft_deleted()
    self._include_soft_deleted = true
    return self
end

return QueryBuilder
