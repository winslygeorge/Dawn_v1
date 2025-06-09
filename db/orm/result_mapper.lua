--- This module is responsible for mapping raw database query results (rows)
--- into model instances.
local ResultMapper = {}

--- Maps a list of raw database rows into a list of model instances.
-- This function now supports mapping joined data into nested model instances
-- based on column aliases.
-- @param model_class table The ORM model class to map the primary results to.
-- @param raw_rows table A list of tables, where each inner table represents a row from the database.
-- @param model_mapping table (Optional) A table describing how to map columns to models.
--                      Format: {{ model = ModelClass, prefix = "table_name__", relation_name = "relation" }, ...}
-- @return table A list of model instances.
function ResultMapper.map_to_models(model_class, raw_rows, model_mapping)
    local instances = {}
    model_mapping = model_mapping or {{ model = model_class, prefix = "" }} -- Default to no prefix for main model

    if not raw_rows or #raw_rows == 0 then
        return instances
    end

    for _, raw_row in ipairs(raw_rows) do
        local main_instance_data = {}
        local related_instances_data = {}

        -- Extract data for each model based on its prefix
        for _, mapping_def in ipairs(model_mapping) do
            local current_model_data = {}
            local has_pk_value = false
            local pk_value = nil

            for column_name, column_value in pairs(raw_row) do
                -- Check if the column belongs to the current model based on prefix
                if string.sub(column_name, 1, #mapping_def.prefix) == mapping_def.prefix then
                    local original_col_name = string.sub(column_name, #mapping_def.prefix + 1)
                    current_model_data[original_col_name] = column_value

                    -- Check if primary key is present and not null
                    if original_col_name == mapping_def.model._primary_key and column_value ~= nil then
                        has_pk_value = true
                        pk_value = column_value
                    end
                end
            end

            if mapping_def.model == model_class then
                -- This is the main model
                main_instance_data = current_model_data
            elseif has_pk_value then -- Only create related instance if its primary key is present
                -- This is a related model
                related_instances_data[mapping_def.relation_name] = mapping_def.model:new(current_model_data)
            end
        end

        -- Create the main model instance
        local main_instance = model_class:new(main_instance_data)

        -- Attach related instances
        for relation_name, related_instance in pairs(related_instances_data) do
            main_instance[relation_name] = related_instance
        end

        table.insert(instances, main_instance)
    end

    return instances
end

return ResultMapper
