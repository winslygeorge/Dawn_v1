-- streaming_multipart.lua

local ffi = require("ffi")
local zlib = require("zlib")
local base64 = require("utils.base64")
-- local crypto = require("crypto") -- assumes a Lua crypto library (for encryption/decryption)

local StreamingMultipartParser = {}
StreamingMultipartParser.__index = StreamingMultipartParser

local default_opts = {
  max_memory_size = 1024 * 1024 * 2, -- 2MB
  decode_base64 = true,
  decode_gzip = true,
  auto_save_dir = "/tmp",
  stream_to_disk = true,
  cleanup = true,
  on_start_part = nil,
  on_end_part = nil,
  encryption_key = nil, -- For encryption/decryption of parts (optional)
  progress_callback = nil, -- To track upload progress (optional)
}

local function sanitize_filename(name)
  return name:gsub("[^%w%.%-_]", "_")
end

-- Create a temp file writer
local function create_temp_writer(filename, opts)
  local path = opts.auto_save_dir .. "/" .. sanitize_filename(filename or ("part_" .. tostring(math.random(1e6))))
  local file = assert(io.open(path, "wb"))
  return {
    path = path,
    write = function(self, chunk) file:write(chunk) end,
    close = function() file:close() end
  }
end

-- Gzip decoder wrapper
local function try_gunzip(data)
  local ok, result = pcall(function()
    local stream = zlib.inflate()
    return stream(data)
  end)
  return ok and result or nil
end

-- Base64 encoder/decoder with optional encryption/decryption
-- local function encrypt_data(data, key)
--   if not key then return data end
--   return crypto.encrypt("aes-256-cbc", key, data)   -- Simple AES encryption for example
-- end

-- local function decrypt_data(data, key)
--   if not key then return data end
--   return crypto.decrypt("aes-256-cbc", key, data)   -- Simple AES decryption
-- end

-- Public constructor
function StreamingMultipartParser.new(content_type, on_part_callback, opts)
  assert(type(content_type) == "string", "Content-Type required")
  assert(type(on_part_callback) == "function", "Callback required")
  local boundary = content_type:match('boundary=([^"]+)')
  assert(boundary, "Boundary not found in content type")
  opts = setmetatable(opts or {}, { __index = default_opts })

  local self = setmetatable({
    boundary = "--" .. boundary,
    on_part = on_part_callback,
    opts = opts,
    buffer = "",
    state = "preamble",
    current = nil,
    done = false,
    total_read = 0,
    parts_count = 0,
    progress = 0,
  }, StreamingMultipartParser)

  return self
end

-- Feed chunks
function StreamingMultipartParser:feed(data)
  if self.done then return end
  self.buffer = self.buffer .. data
  self.total_read = self.total_read + #data

  -- Update progress
  if self.opts.progress_callback then
    self.progress = self.total_read
    self.opts.progress_callback(self.progress)
  end

  while true do
    if self.state == "preamble" then
      local s, e = self.buffer:find(self.boundary, 1, true)
      if not s then break end
      self.buffer = self.buffer:sub(e + 1)
      self.state = "headers"

    elseif self.state == "headers" then
      local s, e = self.buffer:find("\r\n\r\n")
      if not s then break end
      local header_block = self.buffer:sub(1, s - 1)
      self.buffer = self.buffer:sub(e + 1)

      local headers = {}
      for line in header_block:gmatch("[^\r\n]+") do
        local k, v = line:match("^(.-):%s*(.*)$")
        if k and v then headers[k:lower()] = v end
      end

      local cd = headers["content-disposition"] or ""
      local name = cd:match('name="([^"]+)"')
      local filename = cd:match('filename="([^"]+)"')
      local mimetype = headers["content-type"]

      self.current = {
        headers = headers,
        name = name,
        filename = filename,
        mimetype = mimetype,
        is_file = filename and true or false,
        size = 0,
        body = self.opts.stream_to_disk and nil or {},
        temp_writer = nil,
        base64 = self.opts.decode_base64 and headers["content-transfer-encoding"] == "base64",
        gzip = self.opts.decode_gzip and mimetype == "application/gzip"
      }

      if self.opts.stream_to_disk and self.current.is_file then
        self.current.temp_writer = create_temp_writer(filename, self.opts)
      end

      if self.opts.on_start_part then
        self.opts.on_start_part(self.current)
      end

      self.state = "body"

    elseif self.state == "body" then
      local s, e = self.buffer:find("\r\n" .. self.boundary, 1, true)
      if not s then break end
      local body_data = self.buffer:sub(1, s - 1)
      self.buffer = self.buffer:sub(e + 1)

      local part = self.current
      part.size = part.size + #body_data

      -- Memory limit enforcement
      if self.opts.max_memory_size and part.size > self.opts.max_memory_size then
        error("Part size exceeds memory limit")
      end

      -- Remove encryption/decryption block
      -- if self.opts.encryption_key then
      --   body_data = decrypt_data(body_data, self.opts.encryption_key)
      -- end

      if part.temp_writer then
        if part.base64 then
          body_data = base64.decode(body_data)
        end
        if part.gzip then
          local gunzipped = try_gunzip(body_data)
          if gunzipped then body_data = gunzipped end
        end
        part.temp_writer:write(body_data)
      else
        if part.base64 then
          body_data = base64.decode(body_data)
        end
        if part.gzip then
          local gunzipped = try_gunzip(body_data)
          if gunzipped then body_data = gunzipped end
        end
        table.insert(part.body, body_data)
      end

      if part.temp_writer then
        part.temp_writer:close()
        part.body = nil
        part.path = part.temp_writer.path
      else
        part.body = table.concat(part.body)
      end

      self.parts_count = self.parts_count + 1
      if self.opts.on_end_part then
        self.opts.on_end_part(part)
      end
      self.on_part(part)

      self.current = nil
      self.state = (self.buffer:sub(1, 2) == "--") and (self.done == true) or "headers"
    else
      error("Invalid parser state")
    end
  end
end

-- Utility: accumulate parts
function StreamingMultipartParser.accumulate(content_type, body_stream, opts)
  local form = {}
  local parser = StreamingMultipartParser.new(content_type, function(part)
    if opts and opts.nested and part.name then
      StreamingMultipartParser.set_nested(form, part.name, part.is_file and part or part.body)
    elseif part.name then
      form[part.name] = part.is_file and part or part.body
    end
  end, opts)

  for chunk in body_stream do
    parser:feed(chunk)
  end

  return form
end

function StreamingMultipartParser.set_nested(tbl, key_path, value)
  local keys = {}
  for k in key_path:gmatch("[^%[%]]+") do
    table.insert(keys, k)
  end
  local t = tbl
  for i = 1, #keys - 1 do
    t[keys[i]] = t[keys[i]] or {}
    t = t[keys[i]]
  end
  t[keys[#keys]] = value
end

return StreamingMultipartParser