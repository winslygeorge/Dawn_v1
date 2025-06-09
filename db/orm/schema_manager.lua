--- This module is responsible for generating Data Definition Language (DDL) SQL statements
--- based on ORM model definitions and for managing schema migrations.
local SchemaManager = {}

local ConnectionManager = require("db.orm.connection_manager")
local config = require("db.orm.config")

-- Mapping of ORM field types to PostgreSQL data types
local TYPE_MAP = {
    integer = "INTEGER",
    string = "VARCHAR(255)",
    text = "TEXT",
    timestamp = "TIMESTAMP",
    boolean = "BOOLEAN",
    float = "DOUBLE PRECISION",
    -- Add more type mappings as needed
}

--- Helper to get the SQL type for a field.
-- @param field_type string The ORM field type (e.g., "integer", "string").
-- @return string The corresponding SQL type.
local function get_sql_type(field_type)
    return TYPE_MAP[field_type] or "VARCHAR(255)" -- Default to VARCHAR if type not mapped
end

--- Helper to format default values for SQL.
-- Ensures SQL functions like CURRENT_TIMESTAMP are not quoted.
-- @param value mixed The default value.
-- @return string The formatted SQL default value.
local function format_default_value(value)
    if type(value) == "string" then
        local upper_value = value:upper()
        -- Check for common SQL functions/keywords that should not be quoted
        if upper_value == "CURRENT_TIMESTAMP" or upper_value == "NOW()" or upper_value == "NULL" or upper_value == "TRUE" or upper_value == "FALSE" then
            return value -- Return as is, unquoted
        end
        -- For other strings, quote and escape
        return "'" .. value:gsub("'", "''") .. "'"
    elseif type(value) == "number" or type(value) == "boolean" then
        return tostring(value)
    elseif value == nil then
        return "NULL"
    else
        error("Unsupported default value type for SQL: " .. type(value))
    end
end

--- Generates the CREATE TABLE SQL statement for a given model.
-- @param Model table The ORM model class.
-- @return string The generated CREATE TABLE SQL.
function SchemaManager.create_table_sql(Model)
    local table_name = Model._table_name
    local fields = Model._fields
    local primary_key = Model._primary_key
    local unique_keys = Model._unique_keys
    local foreign_keys = Model._foreign_keys
    local indexes = Model._indexes -- Note: Indexes are typically created separately, not in CREATE TABLE

    local column_definitions = {}
    local constraints = {}
    local primary_key_defined_inline = false

    -- Process field definitions
    for field_name, field_props in pairs(fields) do
        local col_def = { field_name }
        local field_type = type(field_props) == "table" and field_props.type or field_props

        -- Determine the base SQL type
        local sql_type = get_sql_type(field_type)

        -- Handle SERIAL for auto-incrementing primary keys if type is integer and it's a primary key
        if field_type == "integer" and (
           (type(field_props) == "table" and field_props.primary_key) or
           (field_name == primary_key and not primary_key_defined_inline)
        ) then
            sql_type = "SERIAL" -- Change INTEGER to SERIAL for auto-increment
        end
        table.insert(col_def, sql_type)


        -- Check for inline primary key
        if type(field_props) == "table" and field_props.primary_key then
            table.insert(col_def, "PRIMARY KEY")
            primary_key_defined_inline = true
        elseif field_name == primary_key and not primary_key_defined_inline then
            -- This block is now mostly redundant for SERIAL, but keeps PRIMARY KEY if not SERIAL.
            table.insert(col_def, "PRIMARY KEY")
            primary_key_defined_inline = true
        end

        -- Check for NOT NULL
        if type(field_props) == "table" and field_props.not_null then
            table.insert(col_def, "NOT NULL")
        end

        -- Check for UNIQUE constraint (single column)
        if type(field_props) == "table" and field_props.unique then
            table.insert(col_def, "UNIQUE")
        end

        -- Check for DEFAULT value
        if type(field_props) == "table" and field_props.default ~= nil then
            table.insert(col_def, "DEFAULT " .. format_default_value(field_props.default))
        end

        -- Check for inline FOREIGN KEY
        if type(field_props) == "table" and field_props.references then
            local fk_parts = { "REFERENCES", field_props.references }
            if field_props.on_delete then
                table.insert(fk_parts, "ON DELETE " .. field_props.on_delete)
            end
            if field_props.on_update then
                table.insert(fk_parts, "ON UPDATE " .. field_props.on_update)
            end
            table.insert(col_def, table.concat(fk_parts, " "))
        end

        table.insert(column_definitions, table.concat(col_def, " "))
    end

    -- Add multi-column UNIQUE constraints
    for _, unique_cols in ipairs(unique_keys) do
        if type(unique_cols) == "table" and #unique_cols > 0 then
            table.insert(constraints, string.format("UNIQUE (%s)", table.concat(unique_cols, ", ")))
        end
    end

    -- Add table-level FOREIGN KEY constraints
    for _, fk_def in ipairs(foreign_keys) do
        if fk_def.columns and fk_def.references then
            local fk_cols = type(fk_def.columns) == "table" and table.concat(fk_def.columns, ", ") or fk_def.columns
            local fk_constraint = string.format("FOREIGN KEY (%s) REFERENCES %s", fk_cols, fk_def.references)
            if fk_def.on_delete then
                fk_constraint = fk_constraint .. " ON DELETE " .. fk_def.on_delete
            end
            if fk_def.on_update then
                fk_constraint = fk_constraint .. " ON UPDATE " .. fk_def.on_update
            end
            table.insert(constraints, fk_constraint)
        end
    end

    local create_sql_parts = { string.format("CREATE TABLE %s (", table_name) }
    table.insert(create_sql_parts, table.concat(column_definitions, ",\n    "))

    if #constraints > 0 then
        table.insert(create_sql_parts, ",\n    " .. table.concat(constraints, ",\n    "))
    end

    table.insert(create_sql_parts, "\n);")

    local create_table_sql = table.concat(create_sql_parts, "")

    -- Generate CREATE INDEX statements (separate from CREATE TABLE)
    local index_sqls = {}
    for i, index_def in ipairs(indexes) do
        local unique_keyword = ""
        local cols_str
        local index_name = string.format("%s_%s_idx", table_name, i)

        if type(index_def) == "string" then
            cols_str = index_def
        elseif type(index_def) == "table" then
            if index_def.columns then -- { columns = "col", unique = true } format
                cols_str = type(index_def.columns) == "table" and table.concat(index_def.columns, ", ") or index_def.columns
                if index_def.unique then
                    unique_keyword = "UNIQUE "
                    index_name = string.format("%s_%s_unique_idx", table_name, cols_str:gsub("[^%w_]", "")) -- More specific name
                end
            else -- {"col1", "col2"} format
                cols_str = table.concat(index_def, ", ")
            end
        end
        table.insert(index_sqls, string.format("CREATE %sINDEX %s ON %s (%s);", unique_keyword, index_name, table_name, cols_str))
    end

    return create_table_sql, index_sqls
end

--- Generates the DROP TABLE SQL statement for a given table name.
-- @param table_name string The name of the table to drop.
-- @param cascade boolean (Optional) If true, adds CASCADE to the DROP TABLE statement.
-- @return string The generated DROP TABLE SQL.
function SchemaManager.drop_table_sql(table_name, cascade)
    local sql = string.format("DROP TABLE IF EXISTS %s", table_name)
    if cascade then
        sql = sql .. " CASCADE"
    end
    return sql .. ";"
end

--- Executes a SQL statement using the connection manager.
--- @param sql string The SQL statement to execute.
--- @param mode string The connection mode ("sync" or "async").
--- @raise error If the execution fails.
local function execute_ddl(sql, mode)
    local conn = ConnectionManager.get_connection(mode)
    local p_results = nil
    local success, err_or_result = pcall(function()
        if mode == "async" then
            -- For async mode, we use a Promise-like approach
             p_results = ConnectionManager.execute_query(mode, conn, sql, function (err, result)
                 if err and string.gmatch(tostring(err), "Failed to create poll handle for socket 10: (libuv error), poll error_code : EEXIST: file already exists") then
                 else
                     error("DDL execution failed: " .. tostring(err) .. "\nSQL: " .. sql)
                 end
                 -- p_results = result -- Store the result for async handling
                 return result -- Return the result for async handling
               end)

             return p_results -- Return the result for async handling
        end
        return ConnectionManager.execute_query(mode, conn, sql)
    end)
    ConnectionManager.release_connection(mode, conn)
    if not success then
        error("DDL execution failed: " .. tostring(err_or_result) .. "\nSQL: " .. sql)
    end
end

--- Creates a table for the given model in the database.
-- @param Model table The ORM model class.
-- @param mode string (Optional) The connection mode. Defaults to Model._connection_mode or config.default_mode.
-- @raise error If table creation fails.
function SchemaManager.create_table(Model, mode)
    mode = mode or Model._connection_mode or config.default_mode
    local create_sql, index_sqls = SchemaManager.create_table_sql(Model)
    print(string.format("[DDL] Executing CREATE TABLE for %s:\n%s", Model._table_name, create_sql))
    execute_ddl(create_sql, mode)

    for _, index_sql in ipairs(index_sqls) do
        print(string.format("[DDL] Executing CREATE INDEX for %s:\n%s", Model._table_name, index_sql))
        execute_ddl(index_sql, mode)
    end
    print(string.format("Table '%s' and its indexes created/ensured.", Model._table_name))
end

--- Drops a table from the database.
-- @param table_name string The name of the table to drop.
-- @param cascade boolean (Optional) If true, adds CASCADE to the DROP TABLE statement.
-- @param mode string (Optional) The connection mode. Defaults to "sync".
-- @raise error If table dropping fails.
function SchemaManager.drop_table(table_name, cascade, mode)
    mode = mode or "async" -- Default to sync for DDL operations
    local drop_sql = SchemaManager.drop_table_sql(table_name, cascade)
    print(string.format("[DDL] Executing DROP TABLE for %s:\n%s", table_name, drop_sql))
    execute_ddl(drop_sql, mode)
    print(string.format("Table '%s' dropped.", table_name))
end

--- INTERNAL: Generates SQL to check if a table exists.
-- @param table_name string The name of the table.
-- @return string The SQL query.
local function table_exists_sql(table_name)
    return string.format("SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = '%s');", table_name)
end

--- INTERNAL: Generates SQL to get column information for a table.
-- @param table_name string The name of the table.
-- @return string The SQL query.
local function get_column_info_sql(table_name)
    return string.format(
        "SELECT column_name, data_type, is_nullable, column_default " ..
        "FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = '%s';",
        table_name
    )
end

--- CONCEPTUAL: Fetches the current schema definition for a table from the database.
-- This function would need to query the database's information schema to get details
-- about existing columns, their types, nullability, defaults, and potentially
-- constraints and indexes.
-- As direct database introspection is not available in this environment, this is a placeholder.
-- In a real implementation, you would execute SQL queries against information_schema.
-- @param table_name string The name of the table.
-- @param mode string The connection mode.
-- @return table A table representing the current schema, or nil if table doesn't exist.
local function fetch_current_schema(table_name, mode)
    print(string.format("[SchemaManager] Attempting to fetch current schema for '%s'. (Conceptual)", table_name))
    local conn = ConnectionManager.get_connection(mode)
    local success, columns_info_rows = pcall(function()
        -- In a real scenario, you'd execute this query
        return ConnectionManager.execute_query(mode, conn, get_column_info_sql(table_name))
    end)
    ConnectionManager.release_connection(mode, conn)

    if not success or not columns_info_rows or #columns_info_rows == 0 then
        print(string.format("[SchemaManager] Could not fetch schema for '%s'. It might not exist or an error occurred.", table_name))
        return nil -- Table might not exist or no columns found
    end

    local current_columns = {}
    for _, col_row in ipairs(columns_info_rows) do
        local col_name = col_row.column_name
        current_columns[col_name] = {
            data_type = col_row.data_type,
            is_nullable = (col_row.is_nullable == 'YES'),
            column_default = col_row.column_default
        }
    end

    -- In a full implementation, you would also fetch primary keys, unique constraints,
    -- foreign keys, and indexes from information_schema.
    -- Example conceptual structure for a full schema:
    return {
        columns = current_columns,
        -- primary_key = {},
        -- unique_constraints = {},
        -- foreign_keys = {},
        -- indexes = {}
    }
end

--- CONCEPTUAL: Generates ALTER TABLE SQL statements for schema updates.
-- This function compares the desired model schema with the current database schema
-- and generates the necessary ALTER TABLE statements to bring the database
-- schema in sync with the model definition.
-- As direct database introspection and full diffing logic are complex and
-- depend on actual database schema fetching, this is a conceptual outline.
-- @param Model table The ORM model class.
-- @param current_schema_info table A table representing the current database schema.
-- @return table A list of SQL statements to execute for migration.
function SchemaManager.alter_table_sql(Model, current_schema_info)
    print(string.format("[SchemaManager] Generating ALTER TABLE SQL for '%s'. (Conceptual Diffing Logic)", Model._table_name))
    local alter_sqls = {}
    local table_name = Model._table_name
    local desired_fields = Model._fields

    local current_columns = current_schema_info.columns or {}

    -- 1. Check for new columns (ADD COLUMN)
    for field_name, field_props in pairs(desired_fields) do
        if not current_columns[field_name] then
            -- Column does not exist, add it
            local col_def_parts = { field_name }
            local field_type = type(field_props) == "table" and field_props.type or field_props
            local sql_type = get_sql_type(field_type)

            -- Handle SERIAL for new primary keys (only if adding a primary key that should be serial)
            if field_type == "integer" and ((type(field_props) == "table" and field_props.primary_key) or (field_name == Model._primary_key)) then
                 sql_type = "SERIAL" -- For new primary key columns that are integers
            end
            table.insert(col_def_parts, sql_type)

            if type(field_props) == "table" then
                if field_props.not_null then
                    table.insert(col_def_parts, "NOT NULL")
                end
                if field_props.unique then
                    table.insert(col_def_parts, "UNIQUE")
                end
                if field_props.default ~= nil then
                    table.insert(col_def_parts, "DEFAULT " .. format_default_value(field_props.default))
                end
                if field_props.references then -- Inline foreign key for new column
                    local fk_parts = { "REFERENCES", field_props.references }
                    if field_props.on_delete then
                        table.insert(fk_parts, "ON DELETE " .. field_props.on_delete)
                    end
                    if field_props.on_update then
                        table.insert(fk_parts, "ON UPDATE " .. field_props.on_update)
                    end
                    table.insert(col_def_parts, table.concat(fk_parts, " "))
                end
            end
            table.insert(alter_sqls, string.format("ALTER TABLE %s ADD COLUMN %s;", table_name, table.concat(col_def_parts, " ")))
        else
            -- 2. Check for existing columns (ALTER COLUMN properties)
            local current_col = current_columns[field_name]
            local desired_field_type = type(field_props) == "table" and field_props.type or field_props
            local desired_sql_type = get_sql_type(desired_field_type)

            -- Type change (consider carefully as it might lose data)
            if string.lower(current_col.data_type) ~= string.lower(desired_sql_type) then
                print(string.format("[SchemaManager] INFO: Column '%s.%s' type mismatch. Current: %s, Desired: %s. Generating ALTER TYPE. This might be destructive.", table_name, field_name, current_col.data_type, desired_sql_type))
                table.insert(alter_sqls, string.format("ALTER TABLE %s ALTER COLUMN %s TYPE %s;", table_name, field_name, desired_sql_type))
            end

            -- Nullability change
            local desired_not_null = type(field_props) == "table" and field_props.not_null
            -- A primary key column is always desired to be NOT NULL
            if field_name == Model._primary_key then
                desired_not_null = true
            end

            if desired_not_null and current_col.is_nullable then
                -- Change from nullable to NOT NULL
                table.insert(alter_sqls, string.format("ALTER TABLE %s ALTER COLUMN %s SET NOT NULL;", table_name, field_name))
            elseif not desired_not_null and not current_col.is_nullable then
                -- Attempt to change from NOT NULL to nullable
                -- IMPORTANT: NEVER DROP NOT NULL for a primary key column
                if field_name ~= Model._primary_key then
                    table.insert(alter_sqls, string.format("ALTER TABLE %s ALTER COLUMN %s DROP NOT NULL;", table_name, field_name))
                else
                    print(string.format("[SchemaManager] INFO: Skipping DROP NOT NULL for primary key column '%s.%s' as it's inherently NOT NULL.", table_name, field_name))
                end
            end

            -- Default value change
            local desired_default_value = nil
            if type(field_props) == "table" then
                desired_default_value = field_props.default
            end

            local current_default_value = current_col.column_default

            -- Compare formatted default values (DB might store them as strings, or NULL)
            -- If desired_default_value is not nil AND it's different from current
            if desired_default_value ~= nil then
                -- Need to compare formatted desired value with current DB default
                -- Postgres often stores defaults as strings, like 'CURRENT_TIMESTAMP'::timestamp,
                -- so a direct string comparison is often needed after proper formatting.
                local formatted_desired = format_default_value(desired_default_value)
                local formatted_current = current_default_value or "NULL" -- Treat DB NULL as "NULL" for comparison

                -- Handle SERIAL implicitly generated defaults which might appear as 'nextval(...)'
                -- If current_col.data_type is 'integer' and current_col.column_default resembles a sequence call
                -- and desired_default_value is nil, assume it's a SERIAL default and do nothing.
                if string.lower(current_col.data_type) == "integer" and
                   type(current_default_value) == "string" and
                   string.find(current_default_value, "nextval", 1, true) then
                    -- This is an implicit SERIAL default, and we don't want to change it unless explicitly desired
                    if desired_default_value == nil then
                        -- Do nothing, as the model doesn't specify a default and DB has SERIAL
                    else
                        -- If the model explicitly wants a default, then alter it.
                        -- This might drop the SERIAL behavior, so be careful.
                        table.insert(alter_sqls, string.format("ALTER TABLE %s ALTER COLUMN %s SET DEFAULT %s;", table_name, field_name, formatted_desired))
                    end
                elseif formatted_desired ~= formatted_current then
                    table.insert(alter_sqls, string.format("ALTER TABLE %s ALTER COLUMN %s SET DEFAULT %s;", table_name, field_name, formatted_desired))
                end
            elseif desired_default_value == nil and current_default_value ~= nil then
                -- If the model specifies no default, but the DB has one, drop it.
                -- EXCEPTION: Do not drop default for SERIAL columns.
                local is_serial_default = false
                if string.lower(current_col.data_type) == "integer" and
                   type(current_default_value) == "string" and
                   string.find(current_default_value, "nextval", 1, true) then
                   is_serial_default = true
                end

                if not is_serial_default then
                    table.insert(alter_sqls, string.format("ALTER TABLE %s ALTER COLUMN %s DROP DEFAULT;", table_name, field_name))
                else
                    print(string.format("[SchemaManager] INFO: Skipping DROP DEFAULT for SERIAL column '%s.%s' as it's implicitly managed.", table_name, field_name))
                end
            end
        end
    end

    -- 3. Check for dropped columns (DROP COLUMN) - requires careful handling in real systems.
    --    This logic is often omitted or handled manually in migration tools due to data loss risk.
    --    For demonstration, here's how it would conceptually look:
    for col_name, _ in pairs(current_columns) do
        -- Skip system columns (like 'id', 'created_at', 'updated_at' if they are standard and not explicitly defined in the model)
        local is_system_col = (col_name == "id" or col_name == "created_at" or col_name == "updated_at")
        if not desired_fields[col_name] and not is_system_col then
            print(string.format("[SchemaManager] WARNING: Column '%s.%s' exists in DB but not in model. Generating DROP COLUMN. This is highly destructive and should be reviewed!", table_name, col_name))
            table.insert(alter_sqls, string.format("ALTER TABLE %s DROP COLUMN %s;", table_name, col_name))
        end
    end

    -- 4. Handle Primary Key, Unique Constraints, Foreign Keys, and Indexes.
    --    This is significantly more complex as it involves fetching and comparing
    --    constraint definitions and index definitions from information_schema.
    --    For example:
    --    - Adding new primary key: ALTER TABLE table ADD PRIMARY KEY (col);
    --    - Dropping primary key: ALTER TABLE table DROP CONSTRAINT constraint_name;
    --    - Adding unique constraint: ALTER TABLE table ADD CONSTRAINT name UNIQUE (col);
    --    - Adding foreign key: ALTER TABLE table ADD CONSTRAINT name FOREIGN KEY (col) REFERENCES other_table (other_col);
    --    - Dropping constraints by name.
    --    This requires comprehensive introspection of the database's `information_schema`
    --    and `pg_indexes` (for PostgreSQL) views to accurately compare and generate
    --    ADD/DROP CONSTRAINT and CREATE/DROP INDEX statements.
    print("[SchemaManager] Skipping generation of ALTER statements for Primary Keys, Unique Constraints, Foreign Keys, and Indexes due to complexity and the need for detailed DB introspection beyond current capabilities.")


    return alter_sqls
end

--- Applies schema migrations for a given model.
-- This function checks if the table exists. If not, it creates it.
-- If the table exists, it attempts to apply necessary ALTER TABLE statements
-- by comparing the model definition with the current database schema.
-- @param Model table The ORM model class.
-- @param mode string (Optional) The connection mode. Defaults to Model._connection_mode or config.default_mode.
-- @raise error If schema migration fails.
function SchemaManager.apply_migrations(Model, mode)
    mode = mode or Model._connection_mode or config.default_mode
    local table_name = Model._table_name

    local conn = ConnectionManager.get_connection(mode)
    local table_exists_query = table_exists_sql(table_name)
    local exists_result = nil

    local success, err_or_result = pcall(function()
        -- In a real async scenario, you'd integrate Promise handling here
        return ConnectionManager.execute_query(mode, conn, table_exists_query)
    end)
    ConnectionManager.release_connection(mode, conn)

    if not success then
        print(string.format("[SchemaManager] Error checking table existence for '%s': %s", table_name, tostring(err_or_result)))
        error("Schema migration failed due to inability to check table existence.")
    end

    -- Extract the boolean result from the query result
    exists_result = success and err_or_result[1] and err_or_result[1].exists

    if not exists_result then
        print(string.format("Table '%s' does not exist. Creating table.", table_name))
        SchemaManager.create_table(Model, mode)
    else
        print(string.format("Table '%s' exists. Attempting to apply schema updates.", table_name))
        local current_schema_info = fetch_current_schema(table_name, mode)
        if current_schema_info then
            local alter_sqls = SchemaManager.alter_table_sql(Model, current_schema_info)
            if #alter_sqls > 0 then
                print(string.format("[DDL] Executing ALTER TABLE statements for %s:", table_name))
                for _, sql in ipairs(alter_sqls) do
                    print("  " .. sql)
                    execute_ddl(sql, mode)
                end
                print(string.format("Schema for table '%s' updated.", table_name))
            else
                print(string.format("Schema for table '%s' is already up to date. No ALTER statements needed.", table_name))
            end
        else
            print(string.format("[SchemaManager] WARNING: Could not fetch current schema for '%s'. Skipping ALTER TABLE attempts.", table_name))
        end
    end
end

return SchemaManager