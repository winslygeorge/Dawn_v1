local ffi = require("ffi")

-- Load system LZ4 library
local lz4 = ffi.load("lz4")

ffi.cdef[[
int LZ4_decompress_safe(const char* src, char* dst, int compressedSize, int dstCapacity);
]]

function decompress_lz4(compressed_data)
    local max_output_size = #compressed_data * 5  -- Estimate a safe decompression size
    local output = ffi.new("char[?]", max_output_size)
    
    local decompressed_size = lz4.LZ4_decompress_safe(compressed_data, output, #compressed_data, max_output_size)
    
    if decompressed_size < 0 then
        error("LZ4 decompression failed")
    end

    return ffi.string(output, decompressed_size)
end

-- Read the compressed file
local f = io.open("app.log.lz4", "rb")
local compressed_data = f:read("*all")
f:close()

-- Decompress and print logs
local logs = decompress_lz4(compressed_data)
print(logs)
