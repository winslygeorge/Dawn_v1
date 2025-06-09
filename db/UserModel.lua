local Model = require("db.orm.model")
-- Example User Model
-- Profile Model Definition
local Profile = Model:extend("profiles", {
    id = { type = "integer", primary_key = true, default = "SERIAL" }, -- Corrected: Removed default = "SERIAL"
    bio = "text",
    phone = "string",
    created_at = { type = "timestamp", not_null = true, default = "CURRENT_TIMESTAMP" },
    updated_at = { type = "timestamp", not_null = true, default = "CURRENT_TIMESTAMP" },
}, {
    _primary_key = "id",
    _timestamps = true,
    _include_relations = true, -- Enables eager loading of related models

})

-- User Model Definition
local User = Model:extend("users", {
    id = { type = "integer", primary_key = true, default = "SERIAL" }, -- Corrected: Removed default = "SERIAL"
    name = "string",
    email = { type = "string", unique = true },
    profile_id = "integer", -- Corrected: No default specified, as it's a foreign key
    created_at = { type = "timestamp", not_null = true, default = "CURRENT_TIMESTAMP" },
    updated_at = { type = "timestamp", not_null = true, default = "CURRENT_TIMESTAMP" },
}, {
    _primary_key = "id",
    _foreign_keys = {
        { columns = "profile_id", references = "profiles(id)", on_delete = "SET NULL" }
    },
    _relations = {
        Profiles = { model_name = "Profiles", local_key = "profile_id", foreign_key = "id", join_type = "LEFT" }
    },
    _timestamps = true,
    _include_relations = true, -- Enables eager loading of related models
})

return {
    User = User,
    Profile = Profile
}
