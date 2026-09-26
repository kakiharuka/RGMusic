local Library = {}

local SUPPORTED = {
    mp3 = true,
    ogg = true,
    wav = true,
}

local palettes = {
    {{0.12,0.22,0.42},{0.18,0.84,0.69},{0.96,0.42,0.31}},
    {{0.16,0.10,0.34},{0.72,0.43,0.92},{0.28,0.86,0.94}},
    {{0.34,0.10,0.15},{0.98,0.46,0.29},{0.95,0.78,0.28}},
    {{0.03,0.22,0.28},{0.15,0.72,0.82},{0.66,0.94,0.82}},
    {{0.12,0.14,0.18},{0.98,0.66,0.24},{0.82,0.30,0.25}},
    {{0.12,0.18,0.12},{0.48,0.84,0.34},{0.95,0.72,0.22}},
}

local function u16be(s, i)
    local a, b = s:byte(i, i + 1)
    return (a or 0) * 256 + (b or 0)
end

local function u32be(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a or 0) * 16777216) + ((b or 0) * 65536) + ((c or 0) * 256) + (d or 0)
end

local function u32le(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return (a or 0) + ((b or 0) * 256) + ((c or 0) * 65536) + ((d or 0) * 16777216)
end

local function syncsafe(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a or 0) * 2097152) + ((b or 0) * 16384) + ((c or 0) * 128) + (d or 0)
end

local function utf8_char(cp)
    if cp <= 0x7f then
        return string.char(cp)
    elseif cp <= 0x7ff then
        return string.char(0xc0 + math.floor(cp / 64), 0x80 + (cp % 64))
    elseif cp <= 0xffff then
        return string.char(0xe0 + math.floor(cp / 4096), 0x80 + (math.floor(cp / 64) % 64), 0x80 + (cp % 64))
    end
    return string.char(
        0xf0 + math.floor(cp / 262144),
        0x80 + (math.floor(cp / 4096) % 64),
        0x80 + (math.floor(cp / 64) % 64),
        0x80 + (cp % 64)
    )
end

local function decode_utf16(s, little)
    local out, i = {}, 1
    while i + 1 <= #s do
        local a, b
        if little then a, b = s:byte(i + 1), s:byte(i)
        else a, b = s:byte(i), s:byte(i + 1) end
        local cp = (a or 0) * 256 + (b or 0)
        i = i + 2
        if cp >= 0xd800 and cp <= 0xdbff and i + 1 <= #s then
            local c, d
            if little then c, d = s:byte(i + 1), s:byte(i)
            else c, d = s:byte(i), s:byte(i + 1) end
            local low = (c or 0) * 256 + (d or 0)
            if low >= 0xdc00 and low <= 0xdfff then
                cp = 0x10000 + ((cp - 0xd800) * 0x400) + (low - 0xdc00)
                i = i + 2
            end
        end
        if cp ~= 0 then out[#out + 1] = utf8_char(cp) end
    end
    return table.concat(out)
end

local function clean_text(text)
    if not text then return nil end
    text = text:gsub("%z+$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return text ~= "" and text or nil
end

local function decode_id3_text(s)
    if not s or #s == 0 then return nil end
    local encoding = s:byte(1)
    local body = s:sub(2)
    if encoding == 0 then
        return clean_text(body)
    elseif encoding == 1 then
        if body:sub(1, 2) == "\255\254" then return clean_text(decode_utf16(body:sub(3), true)) end
        if body:sub(1, 2) == "\254\255" then return clean_text(decode_utf16(body:sub(3), false)) end
        return clean_text(body)
    elseif encoding == 2 then
        return clean_text(decode_utf16(body, false))
    elseif encoding == 3 then
        return clean_text(body)
    end
    return nil
end

local function parse_apic(value, absoluteValueOffset)
    if #value < 4 then return nil end
    local encoding = value:byte(1) or 0
    local mime_end = value:find("\0", 2, true)
    if not mime_end then return nil end
    local mime = value:sub(2, mime_end - 1)
    local position = mime_end + 2
    if position > #value then return nil end
    if encoding == 1 or encoding == 2 then
        while position < #value do
            if value:byte(position) == 0 and value:byte(position + 1) == 0 then
                position = position + 2
                break
            end
            position = position + 1
        end
    else
        local description_end = value:find("\0", position, true)
        if not description_end then return nil end
        position = description_end + 1
    end
    if position > #value then return nil end
    return {
        coverMime = mime ~= "" and mime or "image/jpeg",
        coverOffset = absoluteValueOffset + position - 1,
        coverSize = #value - position + 1,
    }
end

local function parse_id3v2(data)
    if data:sub(1, 3) ~= "ID3" or #data < 11 then return nil end
    local version = data:byte(4) or 0
    local flags = data:byte(6) or 0
    local limit = math.min(#data, 10 + syncsafe(data, 7))
    local pos = 11
    if version == 3 and (flags % 128 >= 64) then
        local size = u32be(data, pos)
        pos = pos + 4 + size
    elseif version == 4 and (flags % 128 >= 64) then
        local size = syncsafe(data, pos)
        pos = pos + size
    end
    local result = {}
    while pos + 10 <= limit do
        local id = data:sub(pos, pos + 3)
        if not id:match("^[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$") then break end
        local size = version == 4 and syncsafe(data, pos + 4) or u32be(data, pos + 4)
        if size <= 0 then break end
        local frame_end = pos + 10 + size - 1
        local available = #data - (pos + 9)
        if id == "APIC" and available > 0 then
            local header_size = math.min(size, available, 65536)
            local apic = parse_apic(data:sub(pos + 10, pos + 9 + header_size), pos + 9)
            if apic then
                result.coverMime = apic.coverMime
                result.coverOffset = apic.coverOffset
                result.coverSize = apic.coverSize
            end
        elseif frame_end <= #data then
            local value = data:sub(pos + 10, frame_end)
            if id == "TIT2" then result.title = decode_id3_text(value)
            elseif id == "TPE1" then result.artist = decode_id3_text(value)
            elseif id == "TALB" then result.album = decode_id3_text(value) end
        end
        if frame_end > #data then break end
        pos = pos + 10 + size
        if result.title and result.artist and result.album and result.coverOffset then break end
    end
    return result
end

local function parse_id3v1(tail)
    if #tail < 128 or tail:sub(#tail - 127, #tail - 124) ~= "TAG" then return nil end
    local base = #tail - 127
    local function field(offset, length)
        return clean_text(tail:sub(base + offset, base + offset + length - 1))
    end
    return {
        title = field(3, 30),
        artist = field(33, 30),
        album = field(63, 30),
    }
end

local function parse_vorbis(data)
    local marker = data:find("\1vorbis", 1, true)
    if not marker then return nil end
    local pos = marker + 7
    if pos + 4 > #data then return nil end
    local vendor = u32le(data, pos)
    pos = pos + 4 + vendor
    if pos + 4 > #data then return nil end
    local count = u32le(data, pos)
    pos = pos + 4
    local result = {}
    for _ = 1, math.min(count, 256) do
        if pos + 4 > #data then break end
        local length = u32le(data, pos)
        pos = pos + 4
        if length <= 0 or pos + length - 1 > #data then break end
        local pair = data:sub(pos, pos + length - 1)
        local key, value = pair:match("^([^=]+)=(.*)$")
        if key then
            key = key:upper()
            if key == "TITLE" then result.title = clean_text(value)
            elseif key == "ARTIST" then result.artist = clean_text(value)
            elseif key == "ALBUM" then result.album = clean_text(value) end
        end
        pos = pos + length
    end
    return result
end

local function read_prefix(path, count)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read(count)
    file:close()
    return data
end

local function read_tail(path, count)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    if not size or size <= 0 then file:close(); return nil end
    file:seek("set", math.max(0, size - count))
    local data = file:read(count)
    file:close()
    return data
end

local function fallback_name(path)
    local name = path:match("([^/\\]+)$") or path
    local stem = name:gsub("%.[^%.]+$", "")
    stem = stem:gsub("[_]+", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return stem ~= "" and stem or name
end

local function hash_string(s)
    local h = 5381
    for i = 1, #s do h = ((h * 33) + s:byte(i)) % 2147483647 end
    return h
end

local function read_metadata(path)
    local extension = path:match("%.([^%.]+)$")
    extension = extension and extension:lower() or ""
    local prefix = read_prefix(path, 65536) or ""
    if extension == "mp3" and prefix:sub(1, 3) == "ID3" and #prefix >= 10 then
        local needed = math.min(syncsafe(prefix, 7) + 10, 1048576)
        if needed > #prefix then prefix = read_prefix(path, needed) or prefix end
    end
    local result
    if extension == "mp3" then
        result = parse_id3v2(prefix)
        if not result or not result.title then
            local fallback = parse_id3v1(read_tail(path, 128) or "")
            result = result or {}
            for k, v in pairs(fallback or {}) do if not result[k] then result[k] = v end end
        end
    elseif extension == "ogg" then
        result = parse_vorbis(prefix)
    end
    result = result or {}
    result.title = result.title or fallback_name(path)
    result.artist = result.artist or "Unknown Artist"
    result.album = result.album or "Local Library"
    result.palette = palettes[(hash_string(path) % #palettes) + 1]
    result.filename = path:match("([^/\\]+)$") or path
    result.extension = extension
    result.path = path
    result.folder = path:match("^(.*)[/\\][^/\\]+$")
    return result
end

local Directory = {}
local ffi_ready = false
local ffi

if jit and jit.os == "Linux" then
    local ok, lib = pcall(require, "ffi")
    if ok then
        ffi = lib
        ffi.cdef[[
            typedef struct __dirstream DIR;
            struct dirent {
                uint64_t d_ino;
                int64_t d_off;
                unsigned short d_reclen;
                unsigned char d_type;
                char d_name[256];
            };
            DIR *opendir(const char *name);
            struct dirent *readdir(DIR *dirp);
            int closedir(DIR *dirp);
        ]]
        ffi_ready = true
    end
end

local function directory_entries(path)
    if not ffi_ready then return nil end
    local dir = ffi.C.opendir(path)
    if dir == nil then return nil end
    local entries = {}
    while true do
        local entry = ffi.C.readdir(dir)
        if entry == nil then break end
        local name = ffi.string(entry.d_name)
        if name ~= "." and name ~= ".." then
            entries[#entries + 1] = {name = name, dtype = tonumber(entry.d_type) or 0}
        end
    end
    ffi.C.closedir(dir)
    return entries
end

local function is_directory(path)
    if not ffi_ready then return false end
    local dir = ffi.C.opendir(path)
    if dir == nil then return false end
    ffi.C.closedir(dir)
    return true
end

local function supported(path)
    local extension = path:match("%.([^%.]+)$")
    return extension and SUPPORTED[extension:lower()] == true
end

local function join(a, b)
    if a:sub(-1) == "/" then return a .. b end
    return a .. "/" .. b
end

local function scan_directory(root, depth, seen, yield)
    if depth > 8 or #seen >= 2000 then return end
    local entries = directory_entries(root)
    if not entries then return end
    table.sort(entries, function(a, b) return a.name:lower() < b.name:lower() end)
    for _, entry in ipairs(entries) do
        if entry.name:sub(1, 1) ~= "." then
            local path = join(root, entry.name)
            local dtype = entry.dtype
            if dtype == 4 or (dtype == 0 and is_directory(path)) then
                scan_directory(path, depth + 1, seen, yield)
            elseif dtype == 8 or dtype == 0 then
                if supported(path) then
                    seen[#seen + 1] = path
                    yield(read_metadata(path), #seen, root)
                end
            end
        end
    end
end

function Library.scan(paths)
    return coroutine.create(function()
        local seen, tracks = {}, {}
        for _, root in ipairs(paths) do
            if root and root ~= "" and is_directory(root) then
                scan_directory(root, 0, seen, function(track, count, activeRoot)
                    tracks[#tracks + 1] = track
                    coroutine.yield({kind = "track", track = track, count = count, root = activeRoot})
                end)
            end
        end
        table.sort(tracks, function(a, b)
            local aa = (a.artist or "") .. "\0" .. (a.title or "")
            local bb = (b.artist or "") .. "\0" .. (b.title or "")
            return aa:lower() < bb:lower()
        end)
        return tracks
    end)
end

function Library.inspect_file(path)
    return read_metadata(path)
end
function Library.available()
    return ffi_ready
end

return Library