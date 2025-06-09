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
    -- print package.path
    -- Start scanning from the root directory
    print("Scanning Lua paths in: " .." : " .. root)
    -- Ensure the root directory is added to package.path

    scan(root)
end

-- Set this to your actual project root, e.g., "../"
return add_lua_paths_recursively
-- Usage:
-- local add_lua_paths = require("bootstrap")   
-- add_lua_paths("../") -- Adjust the path as needed
-- This will add all directories recursively to package.path