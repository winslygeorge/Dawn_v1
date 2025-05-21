local Multipart = require("multipart")

local boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"

local callbacks = {
  on_field = function(name, value)
    print("Field:", name, "=", value)
  end,
  on_file_start = function(name)
    print("File start:", name)
  end,
  on_file_chunk = function(name, chunk)
    print("File chunk:", name, #chunk, "bytes")
  end,
  on_file_end = function(name)
    print("File end:", name)
  end,
}

local parser = Multipart.new(boundary, callbacks)

local data = [[
------WebKitFormBoundary7MA4YWxkTrZu0gW
Content-Disposition: form-data; name="field1"

value1
------WebKitFormBoundary7MA4YWxkTrZu0gW
Content-Disposition: form-data; name="file1"; filename="test.txt"
Content-Type: text/plain

This is a test file.
------WebKitFormBoundary7MA4YWxkTrZu0gW--
]]

parser:feed(data)
parser:free()