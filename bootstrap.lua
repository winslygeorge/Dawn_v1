local uv = require("luv")

local function normalize_path(path)
    return path:gsub("//", "/"):gsub("/$", "")
end

local function add_lua_paths_recursively(root)
    root = normalize_path(root)

    local function scan(path)
        local entries = uv.fs_scandir(path)
        while entries do
            local name, typ = uv.fs_scandir_next(entries)
            if not name then break end
            local full_path = path .. "/" .. name
            if typ == "directory" then
                -- Add this directory to package.path
                package.path = package.path .. ";" .. full_path .. "/?.lua"
                scan(full_path) -- Recurse
            end
        end
    end

    -- Add root itself too
    package.path = package.path .. ";" .. root .. "/?.lua"
    scan(root)
end

-- Set this to your actual project root, e.g., "../"
add_lua_paths_recursively("../")
