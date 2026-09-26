local Mpv = {}
Mpv.__index = Mpv

local ffi_ok, ffi = pcall(require, "ffi")
local socket_ready = false
if ffi_ok then
    pcall(ffi.cdef, [[
        typedef unsigned short sa_family_t;
        struct sockaddr_un { sa_family_t sun_family; char sun_path[108]; };
        int socket(int domain, int type, int protocol);
        int connect(int sockfd, const struct sockaddr_un *addr, unsigned int addrlen);
        long send(int sockfd, const void *buf, unsigned long len, int flags);
        long recv(int sockfd, void *buf, unsigned long len, int flags);
        struct timeval { long tv_sec; long tv_usec; };
        int setsockopt(int sockfd, int level, int optname, const void *optval, unsigned int optlen);
        int close(int fd);
        int usleep(unsigned int usec);
    ]])
    socket_ready = true
end

local function shell_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if file then file:close(); return true end
    return false
end

local function read_pid(path)
    local file = io.open(path or "", "r")
    if not file then return nil end
    local pid = file:read("*l")
    file:close()
    if pid and pid:match("^%d+$") then return pid end
    return nil
end

local function process_alive(pid)
    if not pid then return false end
    local file = io.open("/proc/" .. pid .. "/stat", "r")
    if not file then return false end
    local stat = file:read("*l") or ""
    file:close()
    local state = stat:match("^%d+ %b() ([A-Z])")
    return state ~= nil and state ~= "Z"
end

local function wait_pid_exit(pid, timeout_ms)
    local started = love.timer.getTime()
    while process_alive(pid) and (love.timer.getTime() - started) * 1000 < timeout_ms do
        if socket_ready then pcall(ffi.C.usleep, 20000) end
    end
    return not process_alive(pid)
end

local function kill_pid(path)
    local pid = read_pid(path)
    if not pid then return nil end
    os.execute("kill " .. pid .. " 2>/dev/null")
    if not wait_pid_exit(pid, 300) then
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
        wait_pid_exit(pid, 200)
    end
    return pid
end

local function cleanup_late_process(pid_path, socket)
    if not pid_path or pid_path == "" then return end
    local script = "i=0; while [ ! -s " .. shell_quote(pid_path) .. " ] && [ $i -lt 10 ]; do sleep 0.05 2>/dev/null || sleep 1; i=$((i+1)); done; " ..
        "pid=$(cat " .. shell_quote(pid_path) .. " 2>/dev/null); " ..
        "if [ -n \"$pid\" ]; then kill $pid 2>/dev/null; fi; " ..
        "rm -f " .. shell_quote(pid_path)
    if socket and socket ~= "" then script = script .. " " .. shell_quote(socket) end
    os.execute("(" .. script .. ") >/dev/null 2>&1 &")
end

local function json_quote(value)
    return '"' .. tostring(value):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r') .. '"'
end

local function json_encode(value)
    local kind = type(value)
    if kind == "string" then return json_quote(value) end
    if kind == "number" then return tostring(value) end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "nil" then return "null" end
    if kind == "table" then
        local is_array = true
        local count = 0
        for key in pairs(value) do
            count = count + 1
            if type(key) ~= "number" then is_array = false end
        end
        local parts = {}
        if is_array then
            for index = 1, count do parts[index] = json_encode(value[index]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for key, item in pairs(value) do
            parts[#parts + 1] = json_quote(tostring(key)) .. ":" .. json_encode(item)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local function parse_data(line)
    local value = line:match('"data"%s*:%s*([^,}]+)')
    if not value then return nil end
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "null" then return nil end
    if value == "true" then return true end
    if value == "false" then return false end
    return tonumber(value) or value:gsub('^"', ''):gsub('"$', '')
end

function Mpv.detect(app_root)
    if love.system.getOS() ~= "Linux" then return nil end
    local override = os.getenv("RGMUSIC_MPV")
    if override and override ~= "" and file_exists(override) then return override end
    local candidates = {app_root .. "/bin/mpv.aarch64", app_root .. "/bin/mpv", "/usr/bin/mpv", "/bin/mpv", "/usr/local/bin/mpv", "/opt/mpv/mpv"}
    for _, path in ipairs(candidates) do if file_exists(path) then return path end end
    local pipe = io.popen("command -v mpv 2>/dev/null", "r")
    if pipe then
        local path = pipe:read("*l")
        pipe:close()
        if path and path ~= "" and file_exists(path) then return path end
    end
    return nil
end
function Mpv.new(options)
    local self = setmetatable({}, Mpv)
    self.binary = options.binary
    self.socket_base = options.socket
    self.pid_base = options.pid_path
    self.socket = options.socket
    self.pid_path = options.pid_path
    self.log_path = options.log_path
    self.active = false
    self.sequence = 0
    self.request_id = 0
    self.status = {time = 0, duration = 0, paused = false, eof = false, idle = false, loaded = false, buffering = false, cache = 0}
    self.socket_ready = socket_ready
    return self
end

function Mpv:available()
    return self.socket_ready and file_exists(self.binary)
end

function Mpv:remove_runtime_files(socket, pid_path)
    pcall(os.remove, socket or self.socket)
    pcall(os.remove, pid_path or self.pid_path)
end

function Mpv:send_lines(lines)
    if not self.active or not self.socket_ready then return {} end
    local fd = ffi.C.socket(1, 1, 0)
    if fd < 0 then return {} end
    local address = ffi.new("struct sockaddr_un")
    address.sun_family = 1
    ffi.copy(address.sun_path, self.socket)
    local timeout = ffi.new("struct timeval[1]")
    timeout[0].tv_sec, timeout[0].tv_usec = 0, 80000
    ffi.C.setsockopt(fd, 1, 20, timeout, ffi.sizeof(timeout))
    if ffi.C.connect(fd, address, ffi.sizeof(address)) ~= 0 then
        ffi.C.close(fd)
        return {}
    end
    local payload = table.concat(lines, "\n") .. "\n"
    ffi.C.send(fd, payload, #payload, 0)
    local responses, buffer = {}, ""
    local temp = ffi.new("char[8192]")
    for _ = 1, 64 do
        local count = ffi.C.recv(fd, temp, 8192, 0)
        if count <= 0 then break end
        buffer = buffer .. ffi.string(temp, count)
        while true do
            local newline = buffer:find("\n", 1, true)
            if not newline then break end
            local line = buffer:sub(1, newline - 1)
            buffer = buffer:sub(newline + 1)
            if line:find('"request_id"', 1, true) then responses[#responses + 1] = line end
        end
        if #responses >= #lines then break end
    end
    ffi.C.close(fd)
    return responses
end

function Mpv:command(command)
    self.request_id = self.request_id + 1
    return self:send_lines({json_encode({command = command, request_id = self.request_id})})
end

function Mpv:query_many(properties)
    self.request_id = self.request_id + 1
    local base = self.request_id
    local lines, mapping = {}, {}
    for index, property in ipairs(properties) do
        local id = base + index - 1
        lines[#lines + 1] = json_encode({command = {"get_property", property}, request_id = id})
        mapping[id] = property
    end
    self.request_id = base + #properties - 1
    local responses = self:send_lines(lines)
    local result = {}
    for _, line in ipairs(responses) do
        local id = tonumber(line:match('"request_id"%s*:%s*(%d+)'))
        if id and mapping[id] then result[mapping[id]] = parse_data(line) end
    end
    return result
end
function Mpv:play(url, volume)
    local previous_socket, previous_pid_path = self.socket, self.pid_path
    self:stop()
    self.sequence = self.sequence + 1
    self.socket = self.socket_base .. "-" .. tostring(self.sequence) .. ".sock"
    self.pid_path = self.pid_base .. "-" .. tostring(self.sequence) .. ".pid"
    self:remove_runtime_files()

    local volume_value = math.floor(math.max(0, math.min(1, volume or 0.5)) * 100 + 0.5)
    local launch = "echo $$ > " .. shell_quote(self.pid_path) .. "; echo $$ > " .. shell_quote(self.pid_base) .. "; exec " .. shell_quote(self.binary) ..
        " --no-config --no-video --vo=null --ao=pulse,alsa --idle=yes" ..
        " --cache=yes --cache-pause=no --volume=" .. tostring(volume_value) ..
        " --network-timeout=20" ..
        " --user-agent=" .. shell_quote("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36") ..
        " --http-header-fields=" .. shell_quote("Referer: https://music.163.com/") ..
        " --input-ipc-server=" .. shell_quote(self.socket) ..
        " " .. shell_quote(url) ..
        " > " .. shell_quote(self.log_path) .. " 2>&1"
    os.execute("sh -c " .. shell_quote(launch) .. " &")
    self.active = true
    self.status = {time = 0, duration = 0, paused = false, eof = false, idle = false, loaded = false, buffering = false, cache = 0}
    if previous_pid_path and previous_pid_path ~= self.pid_base then
        cleanup_late_process(previous_pid_path, previous_socket)
    end
    return true
end

function Mpv:update_status()
    if not self.active then return false end
    local values = self:query_many({"time-pos", "duration", "pause", "eof-reached", "idle-active", "path", "paused-for-cache", "cache-buffering-state"})
    if not next(values) then return false end
    if values["time-pos"] ~= nil then self.status.time = tonumber(values["time-pos"]) or 0 end
    if values.duration ~= nil then self.status.duration = tonumber(values.duration) or self.status.duration end
    if values.pause ~= nil then self.status.paused = values.pause == true end
    if values["eof-reached"] ~= nil then self.status.eof = values["eof-reached"] == true end
    if values["idle-active"] ~= nil then
        self.status.idle = values["idle-active"] == true
        if self.status.idle then self.status.eof = true end
    end
    if values.path ~= nil then self.status.loaded = tostring(values.path) ~= "" end
    if values["paused-for-cache"] ~= nil then self.status.buffering = values["paused-for-cache"] == true end
    if values["cache-buffering-state"] ~= nil then self.status.cache = tonumber(values["cache-buffering-state"]) or self.status.cache end
    return true
end

function Mpv:toggle_pause()
    if not self.active then return false end
    self.status.paused = not self.status.paused
    self:command({"set_property", "pause", self.status.paused})
    return self.status.paused
end

function Mpv:seek(seconds)
    if not self.active then return end
    self.status.time = tonumber(seconds) or 0
    self:command({"seek", self.status.time, "absolute"})
end

function Mpv:set_volume(volume)
    if not self.active then return end
    local value = math.floor(math.max(0, math.min(1, volume or 0.5)) * 100 + 0.5)
    self:command({"set_property", "volume", value})
end

function Mpv:stop()
    if self.active then self:command({"quit"}) end
    kill_pid(self.pid_path)
    if self.pid_base ~= self.pid_path then kill_pid(self.pid_base) end
    self.active = false
    self.status = {time = 0, duration = 0, paused = false, eof = false, idle = false, loaded = false, buffering = false, cache = 0}
    self:remove_runtime_files()
    pcall(os.remove, self.socket_base)
    pcall(os.remove, self.pid_base)
end

function Mpv:is_active() return self.active end
function Mpv:get_status() return self.status end

return Mpv
