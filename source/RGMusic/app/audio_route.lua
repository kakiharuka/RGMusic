local AudioRoute = {}
AudioRoute.__index = AudioRoute

local SPEAKER_SINK = "alsa_output.1.stereo-fallback"
local HEADPHONE_SINK = "alsa_output.0.HiFi__Speaker__sink"
local GPIO_PATH = "/sys/kernel/debug/gpio"
local STATE_PATH = "/sys/class/anbernic_misc/spk_state"

local function run(command)
    os.execute(command .. " >/dev/null 2>&1")
end

local function read_headphones()
    local state_file = io.open(STATE_PATH, "r")
    if state_file then
        local value = state_file:read("*a"):match("%d+")
        state_file:close()
        if value then return value == "1" end
    end
    local file = io.open(GPIO_PATH, "r")
    if not file then return nil end
    local result
    for line in file:lines() do
        if line:find("|hp-det", 1, true) then
            local value = line:match("%sin%s+(%a+)%s+IRQ")
            if value == "hi" then result = true
            elseif value == "lo" then result = false end
            break
        end
    end
    file:close()
    return result
end

local function is_app_stream(application)
    return application == "love.aarch64" or application:find("mpv", 1, true) ~= nil
end

local function move_inputs(target_sink)
    local pipe = io.popen("pactl list sink-inputs 2>/dev/null", "r")
    if not pipe then return end
    local sink_input_id
    local application
    for line in pipe:lines() do
        local id = line:match("^Sink Input #(%d+)")
        if id then
            sink_input_id = id
            application = nil
        else
            local name = line:match('application%.name = "([^"]+)"')
            if name then application = name end
            if sink_input_id and application and is_app_stream(application) then
                run("pactl move-sink-input " .. sink_input_id .. " " .. target_sink)
                sink_input_id = nil
                application = nil
            end
        end
    end
    pipe:close()
end

function AudioRoute.open()
    if not love.system or love.system.getOS() ~= "Linux" then return nil end
    local inserted = read_headphones()
    if inserted == nil then return nil end
    return setmetatable({inserted = inserted, nextCheck = 0, nextMove = 0, closed = false}, AudioRoute)
end

function AudioRoute:set_output_change_callback(callback)
    self.onOutputChange = callback
end

function AudioRoute:poll()
    if self.closed then return false end
    local now = love.timer.getTime()
    if now < self.nextCheck then return true end
    self.nextCheck = now + 0.25
    local inserted = read_headphones()
    if inserted ~= nil and inserted ~= self.inserted then
        self.inserted = inserted
        if self.onOutputChange then self.onOutputChange(inserted) end
        move_inputs(inserted and HEADPHONE_SINK or SPEAKER_SINK)
        self.nextMove = now + 0.5
    elseif now >= (self.nextMove or 0) then
        self.nextMove = now + 0.5
        move_inputs(inserted and HEADPHONE_SINK or SPEAKER_SINK)
    end
    return true
end

function AudioRoute:is_headphones()
    return self.inserted == true
end

function AudioRoute:close()
    self.closed = true
end

return AudioRoute