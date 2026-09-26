local AudioRoute = {}
AudioRoute.__index = AudioRoute

local SINK = "alsa_output.1.stereo-fallback"
local HEADPHONES = "analog-output-headphones"
local SPEAKER = "analog-output-speaker"

local function shell()
    return os.execute("pactl info >/dev/null 2>&1") == 0
end

local function move_inputs()
    local pipe = io.popen("pactl list sink-inputs short 2>/dev/null", "r")
    if not pipe then return end
    for line in pipe:lines() do
        local id = line:match("^(%d+)")
        if id then os.execute("pactl move-sink-input " .. id .. " " .. SINK .. " >/dev/null 2>&1") end
    end
    pipe:close()
end

local function apply(inserted)
    if not shell() then return end
    os.execute("pactl set-default-sink " .. SINK .. " >/dev/null 2>&1")
    os.execute("pactl set-sink-port " .. SINK .. " " .. (inserted and HEADPHONES or SPEAKER) .. " >/dev/null 2>&1")
    move_inputs()
end

function AudioRoute.open()
    if not love.system or love.system.getOS() ~= "Linux" then return nil end
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil end
    pcall(ffi.cdef, [[
        struct rgmusic_switch_event { long sec; long usec; unsigned short type; unsigned short code; int value; };
        int open(const char *path, int flags, ...);
        long read(int fd, void *buf, unsigned long count);
        int close(int fd);
        int ioctl(int fd, unsigned long request, ...);
    ]])

    local path
    for index = 0, 31 do
        local file = io.open("/sys/class/input/event" .. index .. "/device/name", "r")
        if file then
            local name = file:read("*l")
            file:close()
            if name == "rockchip-rk817 Headset" then
                path = "/dev/input/event" .. index
                break
            end
        end
    end
    if not path then return nil end

    local fd = ffi.C.open(path, 0x800)
    if fd < 0 then return nil end
    local events = ffi.new("struct rgmusic_switch_event[64]")
    local event_size = ffi.sizeof("struct rgmusic_switch_event")
    local switches = ffi.new("unsigned long[1]")
    local request = 0x8008451b
    local inserted = false
    if ffi.C.ioctl(fd, request, switches) == 0 then
        inserted = math.floor(tonumber(switches[0]) / 4) % 2 == 1
    end
    apply(inserted)

    local self = setmetatable({ffi = ffi, fd = fd, events = events, event_size = event_size, path = path, inserted = inserted, closed = false}, AudioRoute)
    return self
end

function AudioRoute:poll()
    if self.closed then return false end
    local bytes = tonumber(self.ffi.C.read(self.fd, self.events, self.ffi.sizeof(self.events)))
    if bytes < 0 then
        local err = self.ffi.errno()
        return err == 11 or err == 4
    end
    if bytes % self.event_size ~= 0 then self:close(); return false end
    for index = 0, bytes / self.event_size - 1 do
        local event = self.events[index]
        if tonumber(event.type) == 5 and (tonumber(event.code) == 2 or tonumber(event.code) == 4) then
            local inserted = tonumber(event.value) == 1
            if inserted ~= self.inserted then
                self.inserted = inserted
                apply(inserted)
            end
        end
    end
    return true
end

function AudioRoute:close()
    if self.closed then return end
    self.closed = true
    pcall(function() self.ffi.C.close(self.fd) end)
end

return AudioRoute