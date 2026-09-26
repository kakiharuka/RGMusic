local Netease = {}
Netease.__index = Netease

local function shell_quote(value)
    value = tostring(value or "")
    if love.system.getOS() == "Windows" then
        return value
    end
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function read_all(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function split_rows(data)
    local rows = {}
    for line in tostring(data or ""):gmatch("[^\r\n]+") do
        local fields, start = {}, 1
        while true do
            local pos = line:find("\t", start, true)
            if not pos then
                fields[#fields + 1] = line:sub(start)
                break
            end
            fields[#fields + 1] = line:sub(start, pos - 1)
            start = pos + 1
        end
        rows[#rows + 1] = fields
    end
    return rows
end

local function remove_file(path)
    if path and path ~= "" then pcall(os.remove, path) end
end

local function read_pid(path)
    local file = io.open(path or "", "r")
    if not file then return nil end
    local pid = file:read("*l")
    file:close()
    if pid and pid:match("^%d+$") then return pid end
    return nil
end

local function kill_file_process(path)
    local pid = read_pid(path)
    if pid then os.execute("kill " .. pid .. " 2>/dev/null") end
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

function Netease.new(options)
    local self = setmetatable({}, Netease)
    self.binary = options.binary
    self.data_dir = options.data_dir
    if love.system.getOS() == "Windows" then self.data_dir = self.data_dir:gsub("/", "\\") end
    self.output_dir = options.output_dir
    if love.system.getOS() == "Windows" then self.output_dir = self.output_dir:gsub("/", "\\") end
    self.sep = love.system.getOS() == "Windows" and "\\" or "/"
    self.sequence = 0
    self.busy = false
    self.request_id = 0
    self.callback = nil
    self.output_path = nil
    self.pid_path = nil
    self.exit_path = nil
    self.synchronous = false
    if love.system.getOS() == "Windows" then
        -- The main app creates the save subdirectory with love.filesystem.
    else
        os.execute("mkdir -p " .. shell_quote(self.output_dir))
    end
    return self
end

function Netease:run(command, args, callback)
    if self.busy then return false end
    self.sequence = self.sequence + 1
    self.request_id = self.sequence
    self.busy = true
    self.callback = callback
    self.output_seen_at = nil
    self.output_path = string.format("%s%scommand-%d.tsv", self.output_dir, self.sep, self.sequence)
    self.pid_path = self.output_path .. ".pid"
    remove_file(self.output_path)
    remove_file(self.pid_path)

    local parts = {shell_quote(self.binary), "-data", shell_quote(self.data_dir), "-out", shell_quote(self.output_path), command}
    for _, value in ipairs(args or {}) do parts[#parts + 1] = shell_quote(value) end
    local command_line = table.concat(parts, " ")

    if love.system.getOS() == "Windows" then
        self.synchronous = true
        local pipe = io.popen(command_line, "r")
        if pipe then pipe:read("*a"); local ok = pipe:close(); self.sync_rc = ok and 0 or 1 else self.sync_rc = 1 end
    else
        self.synchronous = false
        local launch = "echo $$ > " .. shell_quote(self.pid_path) .. "; exec " .. command_line .. " >/dev/null 2>&1"
        os.execute("sh -c " .. shell_quote(launch) .. " &")
    end
    return true
end

function Netease:cancel()
    if not self.busy then return end
    if love.system.getOS() ~= "Windows" then kill_file_process(self.pid_path) end
    self.busy = false
    self.callback = nil
    self.synchronous = false
    self.sync_rc = nil
    self.output_seen_at = nil
    remove_file(self.pid_path)
    remove_file(self.output_path)
end
function Netease:update()
    if not self.busy then return end
    local output = read_all(self.output_path)
    if self.synchronous then
        output = output or ""
    else
        if not output or output == "" then
            local pid = read_pid(self.pid_path)
            if pid and not process_alive(pid) then
                output = ""
            else
                self.output_seen_at = nil
                return
            end
        end
        local now = love.timer.getTime()
        if not self.output_seen_at then
            self.output_seen_at = now
            return
        end
        if now - self.output_seen_at < 0.15 then return end
    end
    local rows = split_rows(output)
    local callback = self.callback
    self.busy, self.callback, self.synchronous = false, nil, false
    self.output_seen_at = nil
    remove_file(self.pid_path)
    if callback then
        local ok = output ~= "" and not output:match("^error\t")
        callback(ok, rows, output)
    end
end

function Netease:is_busy()
    return self.busy
end

return Netease
