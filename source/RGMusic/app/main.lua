local Library = require("library")
local Touch = require("touch_evdev")
local Netease = require("netease")
local Mpv = require("mpv")
local AudioRoute = require("audio_route")
local APP_VERSION = "r0.76"
local STREAM_UNAVAILABLE_MESSAGE = "此歌曲无可用播放源：可能受版权、地区或会员权益限制"
local start_stream_ready, queue_online_art, queue_online_lyrics, prefetch_online_url
local log_path, log_line, log_tail

local SCREEN_W, SCREEN_H = 1024, 768
local WINDOW_W, WINDOW_H = 2048, 768
local LOWER_X = 1024
local VISIBLE_ROWS = 6

local C = {
    bg = {0.952, 0.963, 0.982, 1},
    upper = {0.982, 0.986, 0.997, 1},
    lower = {0.941, 0.951, 0.973, 1},
    card = {1.0, 1.0, 1.0, 1},
    card2 = {0.925, 0.946, 0.984, 1},
    card3 = {0.865, 0.891, 0.938, 1},
    text = {0.082, 0.102, 0.148, 1},
    muted = {0.405, 0.445, 0.525, 1},
    accent = {0.18, 0.43, 0.91, 1},
    accent2 = {0.91, 0.30, 0.37, 1},
    line = {0.825, 0.855, 0.91, 1},
    dark = {0.045, 0.06, 0.09, 1},
    ok = {0.08, 0.65, 0.46, 1},
}

local state = {
    tracks = {}, selected = 1, playing = false, position = 0, duration = 0,
    masterVolume = 0.5, speakerVolume = 0.5, headphoneVolume = 0.5, output = "speaker", muted = false,
    playbackState = "idle", playbackTrack = nil, playbackError = nil,
    loadingStartedAt = 0, loadingStage = nil, trackStatus = {}, favorites = {},
    shuffle = false, repeatTrack = false,
    time = 0, scroll = 1, status = "正在启动音乐库...",
    scanActive = false, scanTracks = {}, scanCount = 0, scanRoot = "",
    scanCoroutine = nil, source = nil, fileData = nil, audioReady = false, playbackConfirmed = false,
    mpvProgressAt = 0, mpvLastPosition = 0,
    paths = {}, fonts = {}, fontData = nil, fontPath = nil, controls = nil,
    rowHitboxes = {}, buttonRects = {},
    progressRect = nil, quickVolumeRect = nil, rescanRect = nil,
    coverImage = nil, coverData = nil, coverMood = nil, coverPalette = nil, nowPlaying = nil,
    section = "local", localUI = nil, online = nil, sectionRects = {},
    lyrics = {lines = {}, current = 1, available = false, source = nil}, touch = nil, touchOrigin = nil, evdevActive = false,
    pointer = {active = false, downX = 0, downY = 0, lastX = 0, lastY = 0,
        drag = false, startScroll = 1, scrubTarget = nil},
}

local function color(c, a) love.graphics.setColor(c[1], c[2], c[3], a or c[4] or 1) end
local function accent()
    local p = state.coverPalette
    if not p then return C.accent end
    local r, g, b = p[1], p[2], p[3]
    local maximum = math.max(r, g, b)
    if maximum < 0.34 then
        local k = 0.34 / math.max(maximum, 0.01)
        r, g, b = r * k, g * k, b * k
    end
    return {math.max(0.08, math.min(0.94, r * 0.86 + 0.11)), math.max(0.08, math.min(0.94, g * 0.86 + 0.11)), math.max(0.08, math.min(0.94, b * 0.86 + 0.11)), 1}
end
local function rounded_panel(x, y, w, h, fill, radius)
    color(fill)
    love.graphics.rectangle("fill", x, y, w, h, radius or 18, radius or 18)
end
local function soft_panel(x, y, w, h, fill, radius, strength)
    rounded_panel(x, y, w, h, fill, radius or 18)
end
local function glass_panel(x, y, w, h, radius, tint, alpha)
    radius = radius or 18
    local base = tint or C.card
    local a = accent()
    color({base[1], base[2], base[3], alpha or 0.72})
    love.graphics.rectangle("fill", x, y, w, h, radius, radius)
    color(a, 0.060)
    love.graphics.rectangle("fill", x, y, w, h, radius, radius)
end

local function clamp(v, low, high) return math.max(low, math.min(high, v)) end
local function fmt_time(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end
local function quantize_volume(value)
    value = clamp(value or 0, 0, 1)
    return math.floor(value * 20 + 0.5) / 20
end

local function effective_volume()
    if state.muted then return 0 end
    return clamp(state.masterVolume * 0.5, 0, 1)
end
local function current_track()
    local track = state.nowPlaying or state.tracks[state.selected] or state.tracks[1]
    if track then return track end
    return {title = "没有找到本地音乐", artist = "请将音乐放入扫描目录", album = "", duration = 0, extension = "", palette = {{0.12,0.22,0.42},{0.18,0.84,0.69},{0.96,0.42,0.31}}}
end
local function track_key(track)
    if not track then return nil end
    if track.id then return "id:" .. tostring(track.id) end
    if track.path and track.path ~= "" then return "path:" .. tostring(track.path) end
    return "title:" .. tostring(track.title or track.name or "")
end

local function same_track(left, right)
    if not left or not right then return false end
    if left.id and right.id then return tostring(left.id) == tostring(right.id) end
    if left.path and right.path then return left.path == right.path end
    return false
end

local function set_track_status(track, status, detail)
    local key = track_key(track)
    if not key then return end
    state.trackStatus[key] = {status = status, detail = detail, at = love.timer.getTime()}
end

local function get_track_status(track)
    local key = track_key(track)
    if key and state.trackStatus[key] then
        return state.trackStatus[key].status, state.trackStatus[key].detail
    end
    if same_track(track, state.playbackTrack) then
        return state.playbackState, state.playbackError
    end
    return "idle", nil
end

local function set_playback_state(value, track, detail)
    if state.playbackTrack and track and not same_track(state.playbackTrack, track) then
        local oldStatus = get_track_status(state.playbackTrack)
        local oldStillPlaying = same_track(state.playbackTrack, state.nowPlaying) and state.streaming and state.mpv and state.mpv:is_active()
        if not oldStillPlaying and (oldStatus == "playing" or oldStatus == "paused" or oldStatus == "loading" or oldStatus == "starting" or oldStatus == "buffering" or oldStatus == "resolving") then
            set_track_status(state.playbackTrack, "idle", nil)
        end
    end
    state.playbackState = value or "idle"
    state.playbackTrack = track
    state.playbackError = value == "failed" and detail or nil
    state.loadingStage = (value == "resolving" or value == "loading" or value == "starting" or value == "buffering") and value or nil
    if value == "resolving" or value == "loading" or value == "starting" then
        state.loadingStartedAt = love.timer.getTime()
    end
    if track then set_track_status(track, state.playbackState, detail) end
end

local function load_favorites()
    state.favorites = {}
    local data = love.filesystem.read("favorites.txt")
    if not data then return end
    for line in data:gmatch("[^\r\n]+") do state.favorites[line] = true end
end

local function save_favorites()
    local keys = {}
    for key in pairs(state.favorites) do keys[#keys + 1] = key end
    table.sort(keys)
    love.filesystem.write("favorites.txt", table.concat(keys, "\n") .. "\n")
end

local function is_favorite(track)
    local key = track_key(track)
    return key ~= nil and state.favorites[key] == true
end

local function set_user_status(message)
    state.status = message
    if state.online then state.online.status = message end
end

local function toggle_favorite()
    local track = state.tracks[state.selected] or current_track()
    if not track or (track.kind and track.kind ~= "track") then return end
    local key = track_key(track)
    if not key then return end
    if state.favorites[key] then
        state.favorites[key] = nil
        set_user_status("已取消收藏：" .. tostring(track.title or track.name or ""))
    else
        state.favorites[key] = true
        set_user_status("已收藏：" .. tostring(track.title or track.name or ""))
    end
    save_favorites()
end

local function truncate(text, font, width)
    text = tostring(text or "")
    if font:getWidth(text) <= width then return text end
    while #text > 0 do
        local i = #text
        while i > 1 and text:byte(i) >= 128 and text:byte(i) < 192 do i = i - 1 end
        text = text:sub(1, i - 1)
        if font:getWidth(text .. "...") <= width then return text .. "..." end
    end
    return "..."
end

local function read_file_range(path, offset, size)
    if not path or not offset or not size or size <= 0 then return nil end
    local file = io.open(path, "rb")
    if not file then return nil end
    file:seek("set", offset)
    local data = file:read(size)
    file:close()
    return data
end
local function average_color(imageData)
    local w, h = imageData:getDimensions()
    local step = math.max(1, math.floor(math.min(w, h) / 24))
    local r, g, b, count = 0, 0, 0, 0
    for y = 0, h - 1, step do
        for x = 0, w - 1, step do
            local pr, pg, pb, pa = imageData:getPixel(x, y)
            if pa > 0.25 then r, g, b, count = r + pr, g + pg, b + pb, count + 1 end
        end
    end
    if count == 0 then return nil end
    return {r / count, g / count, b / count, 1}
end
local function release_cover()
    if state.coverImage then state.coverImage:release() end
    if state.coverMood then state.coverMood:release() end
    state.coverImage, state.coverData, state.coverMood, state.coverPalette = nil, nil, nil, nil
end

local coverBlurShader
local coverBlurShaderFailed = false

local function get_cover_blur_shader()
    if coverBlurShader or coverBlurShaderFailed then return coverBlurShader end
    local ok, shader = pcall(love.graphics.newShader, [=[
extern vec2 blur_step;
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec4 sum = Texel(tex, uv) * 0.227027;
    sum += Texel(tex, uv + blur_step * 1.384615) * 0.316216;
    sum += Texel(tex, uv - blur_step * 1.384615) * 0.316216;
    sum += Texel(tex, uv + blur_step * 3.230769) * 0.070270;
    sum += Texel(tex, uv - blur_step * 3.230769) * 0.070270;
    return sum * color;
}
]=])
    if not ok then coverBlurShaderFailed = true; return nil end
    coverBlurShader = shader
    return coverBlurShader
end

local function make_cover_mood(image)
    if not image then return nil end
    local iw, ih = image:getDimensions()
    local scale = 128 / math.max(iw, ih)
    local mw = math.max(16, math.floor(iw * scale))
    local mh = math.max(16, math.floor(ih * scale))
    local okCanvas, canvas = pcall(love.graphics.newCanvas, mw, mh)
    if not okCanvas then return nil end
    canvas:setFilter("linear", "linear")
    local previousCanvas = love.graphics.getCanvas()
    local previousShader = love.graphics.getShader()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(1, 1, 1, 0)
    local drawScale = math.max(mw / iw, mh / ih)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(image, (mw - iw * drawScale) / 2, (mh - ih * drawScale) / 2, 0, drawScale, drawScale)

    local okTemp, temp = pcall(love.graphics.newCanvas, mw, mh)
    local shader = get_cover_blur_shader()
    if okTemp and shader then
        temp:setFilter("linear", "linear")
        shader:send("blur_step", {1 / mw, 0})
        love.graphics.setCanvas(temp)
        love.graphics.setShader(shader)
        love.graphics.clear(1, 1, 1, 0)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(canvas)
        shader:send("blur_step", {0, 1 / mh})
        love.graphics.setCanvas(canvas)
        love.graphics.clear(1, 1, 1, 0)
        love.graphics.draw(temp)
    end

    if previousShader then love.graphics.setShader(previousShader) else love.graphics.setShader() end
    if previousCanvas then love.graphics.setCanvas(previousCanvas) else love.graphics.setCanvas() end
    if okTemp and temp then temp:release() end
    return canvas
end
local function load_cover_data(data, name)
    if not data then return false end
    local ok, fileData = pcall(love.filesystem.newFileData, data, name or "cover.jpg")
    if not ok then return false end
    local okData, imageData = pcall(love.image.newImageData, fileData)
    if not okData then return false end
    local okImage, image = pcall(love.graphics.newImage, imageData)
    if not okImage then return false end
    local mood = make_cover_mood(image)
    state.coverPalette = average_color(imageData)
    imageData:release()
    state.coverData, state.coverImage, state.coverMood = fileData, image, mood
    return true
end
local function folder_cover_candidates(track)
    local folder = track.folder
    if not folder then return {} end
    local result = {folder .. "/cover.jpg", folder .. "/cover.jpeg", folder .. "/cover.png",
        folder .. "/folder.jpg", folder .. "/folder.png", folder .. "/front.jpg",
        folder .. "/front.png", folder .. "/album.jpg", folder .. "/album.png"}
    if track.filename then
        local base = track.filename:gsub("%.[^%.]+$", "")
        result[#result + 1] = folder .. "/" .. base .. ".jpg"
        result[#result + 1] = folder .. "/" .. base .. ".jpeg"
        result[#result + 1] = folder .. "/" .. base .. ".png"
    end
    return result
end
local function load_cover(track)
    release_cover()
    if not track then return end
    if track.coverPath and track.coverPath ~= "" then
        local file = io.open(track.coverPath, "rb")
        if file then
            local data = file:read("*a"); file:close()
            if load_cover_data(data, track.coverPath) then return end
        end
    end
    if track.coverOffset and track.coverSize and track.coverSize <= 12 * 1024 * 1024 then
        local data = read_file_range(track.path, track.coverOffset, track.coverSize)
        local extension = (track.coverMime or ""):find("png", 1, true) and "png" or "jpg"
        if load_cover_data(data, "embedded." .. extension) then return end
    end
    for _, path in ipairs(folder_cover_candidates(track)) do
        local file = io.open(path, "rb")
        if file then
            local data = file:read("*a")
            file:close()
            if load_cover_data(data, path) then return end
        end
    end
end
local function parse_lrc(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    if not data or data == "" then return nil end
    data = data:gsub("^\239\187\191", "")
    local lines = {}
    for raw in data:gmatch("[^\r\n]+") do
        local remaining = raw
        local times = {}
        while true do
            local minute, second, fraction, rest = remaining:match("^%[(%d+):(%d+)%.?(%d*)%](.*)$")
            if not minute then break end
            local frac = 0
            if fraction and fraction ~= "" then frac = tonumber(fraction) / (10 ^ #fraction) end
            times[#times + 1] = tonumber(minute) * 60 + tonumber(second) + (frac or 0)
            remaining = rest
        end
        if #times > 0 and remaining ~= "" then
            for _, value in ipairs(times) do lines[#lines + 1] = {time = value, text = remaining} end
        elseif not raw:match("^%[%a+:") then
            local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
            if trimmed ~= "" then lines[#lines + 1] = {time = nil, text = trimmed} end
        end
    end
    if #lines == 0 then return nil end
    table.sort(lines, function(a, b)
        if a.time == nil then return false end
        if b.time == nil then return true end
        return a.time < b.time
    end)
    return lines
end

local function lyrics_path_for(track)
    if not track or not track.path then return nil end
    if track.lyricsPath and track.lyricsPath ~= "" then
        local file = io.open(track.lyricsPath, "rb")
        if file then file:close(); return track.lyricsPath end
    end
    local base = track.path:gsub("%.[^%.]+$", "")
    for _, path in ipairs({base .. ".lrc", base .. ".LRC", track.folder and (track.folder .. "/lyrics.lrc")}) do
        if path then
            local file = io.open(path, "rb")
            if file then file:close(); return path end
        end
    end
end

local function load_lyrics(track)
    state.lyrics = {lines = {}, current = 1, available = false, source = nil}
    if not track then return end
    local path = lyrics_path_for(track)
    if not path then return end
    local lines = parse_lrc(path)
    if lines then
        state.lyrics = {lines = lines, current = 1, available = true, source = path}
    end
end

local function current_lyric_index()
    local lyrics = state.lyrics
    if not lyrics or not lyrics.available or #lyrics.lines == 0 then return nil end
    local timed = false
    for _, line in ipairs(lyrics.lines) do
        if line.time then timed = true; break end
    end
    if not timed then return 1 end
    local current = 1
    for index, line in ipairs(lyrics.lines) do
        if line.time and line.time <= state.position then current = index end
    end
    lyrics.current = current
    return current
end

local function apply_source_volume()
    if state.source then state.source:setVolume(effective_volume()) end
    if state.streaming and state.mpv then state.mpv:set_volume(effective_volume()) end
end
local function stop_source()
    if state.mpv and state.mpv:is_active() then state.mpv:stop() end
    state.streaming = false
    if state.source then state.source:stop() end
    state.source, state.fileData, state.audioReady, state.playbackConfirmed = nil, nil, false, false
end
local function load_source_for_track(track)
    if state.nowPlaying and not same_track(state.nowPlaying, track) then
        set_track_status(state.nowPlaying, "idle", nil)
    end
    stop_source()
    set_playback_state("loading", track, "正在加载：" .. tostring(track.title or track.filename or ""))
    load_cover(track)
    load_lyrics(track)
    state.advanceGuardUntil = 0
    if track.streamURL and state.mpv and state.mpv:available() then
        state.nowPlaying = track
        state.source, state.fileData = nil, nil
        state.duration = tonumber(track.duration) or 0
        state.position, state.playing, state.audioReady, state.playbackConfirmed, state.streaming = 0, false, false, false, true
        state.mpvStartedAt, state.mpvStatusAt, state.mpvEofHandled = state.time, state.time, false
        state.mpvProgressAt, state.mpvLastPosition = state.time, 0
        set_playback_state("starting", track, "正在启动播放：" .. tostring(track.title or ""))
        local playOk, playErr = pcall(state.mpv.play, state.mpv, track.streamURL, effective_volume())
        if not playOk then
            state.streaming, state.playing, state.audioReady, state.playbackConfirmed = false, false, false, false
            log_line("mpv", "start error: " .. tostring(playErr))
            error(playErr)
        end
        log_line("mpv", "started: " .. tostring(track.title))
        state.status = "正在启动播放：" .. tostring(track.title)
        return
    end
    local file = io.open(track.path, "rb")
    if not file then error("无法打开 " .. tostring(track.path)) end
    local size = file:seek("end")
    if not size or size <= 0 or size > 32 * 1024 * 1024 then
        file:close(); error("文件过大或无效")
    end
    file:seek("set", 0)
    local data = file:read("*a")
    file:close()
    local fileData = love.filesystem.newFileData(data, track.filename or "track")
    local source = love.audio.newSource(fileData, "stream")
    state.nowPlaying = track
    state.source, state.fileData = source, fileData
    state.duration = tonumber(source:getDuration()) or 0
    state.position, state.playing, state.audioReady, state.playbackConfirmed = 0, true, true, true
    set_playback_state("playing", track, "正在播放：" .. tostring(track.title or ""))
    apply_source_volume()
    source:play()
    state.status = "正在播放：" .. track.title
end
local function start_track(track)
    if not track then return end
    local ok, err = pcall(load_source_for_track, track)
    if not ok then
        state.playing, state.audioReady, state.streaming = false, false, false
        set_playback_state("failed", track, tostring(err))
        set_user_status("播放失败：" .. tostring(err))
    end
end
local function ensure_selected_visible()
    state.scroll = clamp(state.scroll, 1, math.max(1, #state.tracks - VISIBLE_ROWS + 1))
    if state.selected < state.scroll then state.scroll = state.selected end
    if state.selected >= state.scroll + VISIBLE_ROWS then state.scroll = state.selected - VISIBLE_ROWS + 1 end
end
local function image_from_path(path)
    if not path or path == "" then return nil end
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a"); file:close()
    local okFile, fileData = pcall(love.filesystem.newFileData, data, path:match("([^/\\]+)$") or "image")
    if not okFile then return nil end
    local okImage, imageData = pcall(love.image.newImageData, fileData)
    if not okImage then return nil end
    local okResult, image = pcall(love.graphics.newImage, imageData)
    imageData:release()
    if okResult then return image end
end

local refresh_playlists
local poll_login
local activate_online_item
local prepare_online_track
local retry_stream_playback

local function online_items()
    if state.online and state.online.view == "tracks" then return state.online.tracks end
    return state.online and state.online.menu or {}
end

local function apply_online_view()
    if not state.online then return end
    if state.section ~= "online" then return end
    state.tracks = online_items()
    state.selected = state.online.selected
    state.scroll = state.online.scroll
    ensure_selected_visible()
end

local function save_online_ui()
    if not state.online then return end
    state.online.selected, state.online.scroll = state.selected, state.scroll
end

local function set_section(section)
    if section == state.section then return end
    if state.section == "local" then
        state.localUI.tracks, state.localUI.selected, state.localUI.scroll = state.tracks, state.selected, state.scroll
    else
        save_online_ui()
    end
    state.section = section
    if section == "local" then
        state.tracks = state.localUI.tracks
        state.selected, state.scroll = state.localUI.selected, state.localUI.scroll
        ensure_selected_visible()
    else
        apply_online_view()
        if state.online and not state.online.started then
            state.online.started = true
            state.online.client:run("status", {}, function(ok, rows, output)
                if not ok then
                    state.online.loggedIn, state.online.status = false, "网易云连接失败：" .. truncate(output, state.fonts.small, 500)
                    state.online.menu = {{kind = "action", action = "retry", title = "重试连接", subtitle = "检查网络后重试"}}
                    apply_online_view()
                    return
                end
                local row = rows[1] or {}
                state.online.loggedIn = row[1] == "logged_in"
                state.online.nickname, state.online.uid = row[2] or "", tonumber(row[3]) or 0
                state.online.vipType = tonumber(row[4]) or 0
                state.online.redVipLevel = tonumber(row[5]) or 0
                state.online.vipLevel = tonumber(row[6]) or 0
                state.online.member = state.online.vipType > 0 or state.online.redVipLevel > 0
                if state.online.loggedIn then
            state.online.status = "已登录：" .. state.online.nickname .. (state.online.member and " | 会员权益已识别" or " | 当前账号未检测到会员权益")
                    refresh_playlists()
                else
                    state.online.status = "登录后可同步歌单和每日推荐"
                    state.online.menu = {{kind = "action", action = "login", title = "扫码登录网易云", subtitle = "使用手机网易云音乐扫码"}}
                    apply_online_view()
                end
            end)
        end
    end
end

function refresh_playlists()
    if not state.online or not state.online.loggedIn or state.online.client:is_busy() then return end
    state.online.status = "正在读取歌单..."
    state.online.client:run("playlists", {}, function(ok, rows, output)
        if not ok then
            state.online.status = "歌单读取失败：" .. truncate(output, state.fonts.small, 500)
            return
        end
        local menu = {{kind = "action", action = "daily", title = "每日推荐", subtitle = "根据网易云账号每日更新"}}
        for _, row in ipairs(rows) do
            if row[1] == "playlist" then
                menu[#menu + 1] = {
                    kind = "playlist", id = row[2], title = row[5], artist = row[4],
                    subtitle = (row[4] ~= "" and (row[4] .. " · ") or "") .. tostring(row[3] or "0") .. " 首",
                    trackCount = tonumber(row[3]) or 0, coverURL = row[6],
                }
            end
        end
        menu[#menu + 1] = {kind = "action", action = "logout", title = "退出当前账号", subtitle = "切换其他网易云账号"}
        state.online.menu = menu
        state.online.view = "menu"
        state.online.selected, state.online.scroll = 1, 1
        state.online.status = string.format("已同步 %d 个歌单", math.max(0, #menu - 1))
        apply_online_view()
    end)
end

function activate_online_item()
    if not state.online or #state.tracks == 0 then return end
    local item = state.tracks[state.selected]
    if not item then return end
    if item.kind == "action" then
        if item.action == "login" then
            state.online.status = "正在生成登录二维码..."
            state.online.client:run("login-start", {}, function(ok, rows, output)
                if not ok then
                    state.online.status = "二维码生成失败：" .. truncate(output, state.fonts.small, 500)
                    return
                end
                local row = rows[1] or {}
                state.online.view = "login"
                state.online.qrPath = row[2] or ""
                state.online.qrImage = image_from_path(state.online.qrPath)
                state.online.loginState, state.online.loginMessage = "waiting", "等待扫码"
                state.online.status = "等待扫码登录"
                state.online.pollAt = love.timer.getTime() + 2
                apply_online_view()
            end)
        elseif item.action == "retry" then
            state.online.started = false
            set_section("local")
            set_section("online")
        elseif item.action == "logout" then
            state.online.status = "正在退出登录..."
            state.online.client:run("logout", {}, function(ok, _, output)
                if not ok then
                    state.online.status = "退出登录失败：" .. truncate(output, state.fonts.small, 300)
                    return
                end
                state.online.loggedIn, state.online.nickname, state.online.uid = false, "", 0
                state.online.vipType, state.online.redVipLevel, state.online.vipLevel, state.online.member = 0, 0, 0, false
                state.online.view = "menu"
                state.online.selected, state.online.scroll = 1, 1
                state.online.menu = {{kind = "action", action = "login", title = "扫码登录网易云", subtitle = "使用手机网易云音乐扫码"}}
                state.online.status = "已退出登录，请重新扫码"
                apply_online_view()
            end)
        elseif item.action == "daily" then
            state.online.status = "正在读取每日推荐..."
            state.online.client:run("playlist", {"daily"}, function(ok, rows, output)
                if not ok then state.online.status = "每日推荐读取失败：" .. truncate(output, state.fonts.small, 500); return end
                local tracks = {}
                for _, row in ipairs(rows) do
                    if row[1] == "track" then
                        tracks[#tracks + 1] = {kind = "track", source = "netease", id = row[2], title = row[3], artist = row[4], album = row[5], duration = tonumber(row[6]) or 0, coverURL = row[7], available = row[8] ~= "0"}
                    end
                end
                state.online.tracks, state.online.view = tracks, "tracks"
                state.online.selected, state.online.scroll = 1, 1
                state.online.status = string.format("每日推荐 · %d 首", #tracks)
                apply_online_view()
                if tracks[1] then prefetch_online_url(tracks[1]) end
            end)
        end
        return
    end
    if item.kind == "playlist" then
        state.online.status = "正在读取歌单..."
        state.online.client:run("playlist", {tostring(item.id)}, function(ok, rows, output)
            if not ok then state.online.status = "歌单读取失败：" .. truncate(output, state.fonts.small, 500); return end
            local tracks = {}
            for _, row in ipairs(rows) do
                if row[1] == "track" then
                    tracks[#tracks + 1] = {kind = "track", source = "netease", id = row[2], title = row[3], artist = row[4], album = row[5], duration = tonumber(row[6]) or 0, coverURL = row[7], available = row[8] ~= "0"}
                end
            end
            state.online.tracks, state.online.view = tracks, "tracks"
            state.online.selected, state.online.scroll = 1, 1
            state.online.status = string.format("%s · %d 首", item.title, #tracks)
            apply_online_view()
            if tracks[1] then prefetch_online_url(tracks[1]) end
        end)
        return
    end
    if item.kind == "track" then prepare_online_track(item) end
end

local URL_CACHE_TTL = 90

local function cached_stream(track)
    if not track or not state.online then return nil end
    local item = state.online.urlCache[tostring(track.id)]
    if item and love.timer.getTime() - item.at < URL_CACHE_TTL then return item end
    return nil
end

local function next_online_track()
    if not state.online or state.online.view ~= "tracks" or #state.online.tracks == 0 then return nil end
    local index = state.selected + 1
    if index > #state.online.tracks then index = 1 end
    return state.online.tracks[index]
end

local function cached_asset_paths(track)
    if not track or not state.online then return "", "" end
    local cacheDir = state.online.client.data_dir .. "/cache"
    local coverPath = cacheDir .. "/" .. tostring(track.id) .. "-cover.jpg"
    local lyricsPath = cacheDir .. "/" .. tostring(track.id) .. ".lrc"
    local function exists(path)
        local file = io.open(path, "rb")
        if file then file:close(); return true end
        return false
    end
    return exists(coverPath) and coverPath or "", exists(lyricsPath) and lyricsPath or ""
end

local function update_online_assets(id, coverPath, lyricsPath)
    local idText = tostring(id)
    for _, item in ipairs(state.online.tracks or {}) do
        if tostring(item.id) == idText then
            if coverPath and coverPath ~= "" then item.coverPath = coverPath end
            if lyricsPath and lyricsPath ~= "" then item.lyricsPath = lyricsPath end
        end
    end
    if state.nowPlaying and tostring(state.nowPlaying.id) == idText then
        if coverPath and coverPath ~= "" then state.nowPlaying.coverPath = coverPath; load_cover(state.nowPlaying) end
        if lyricsPath and lyricsPath ~= "" then state.nowPlaying.lyricsPath = lyricsPath; load_lyrics(state.nowPlaying) end
    end
end

start_stream_ready = function(track, url, quality, kind)
    if not track or not url or url == "" then return end
    set_playback_state("starting", track, "正在启动播放：" .. tostring(track.title or ""))
    state.online.pendingTrack = nil
    state.online.prepareID = nil; state.online.requestStartedAt = 0; state.online.requestStreaming = false
    state.online.streamRetryCount = 0
    state.online.urlCache[tostring(track.id)] = {url = url, quality = quality, kind = kind, at = love.timer.getTime()}
    local cachedCover, cachedLyrics = cached_asset_paths(track)
    if track.coverPath and track.coverPath ~= "" then cachedCover = track.coverPath end
    if track.lyricsPath and track.lyricsPath ~= "" then cachedLyrics = track.lyricsPath end
    local ready = {
        kind = "track", source = "netease", online = true, available = true, id = track.id,
        title = track.title, artist = track.artist, album = track.album, duration = track.duration,
        coverPath = cachedCover, lyricsPath = cachedLyrics,
        streamURL = url, path = "", filename = tostring(track.id) .. ".mp3", extension = "mp3",
        palette = track.palette,
    }
    log_line("online", "ready mode=stream id=" .. tostring(track.id))
    local playOk, playErr = pcall(load_source_for_track, ready)
    if not playOk then
        set_playback_state("failed", ready, tostring(playErr))
        state.status = "播放失败：" .. tostring(playErr)
        return
    end
    state.online.status = "正在启动播放：" .. tostring(track.title)
    queue_online_art(track)
    local nextTrack = next_online_track()
    if nextTrack then prefetch_online_url(nextTrack) end
end

queue_online_art = function(track)
    if not track or not state.online or not state.online.artClient then return end
    local id = tostring(track.id)
    local cachedCover, cachedLyrics = cached_asset_paths(track)
    if cachedCover ~= "" then
        update_online_assets(id, cachedCover, cachedLyrics)
        if cachedLyrics == "" then queue_online_lyrics(track) end
        return
    end
    if state.online.artSeen[id] then
        state.online.artSeen[id] = nil
    end
    state.online.artPending = track
    if state.online.artClient:is_busy() then return end
    local function run()
        local current = state.online.artPending
        if not current then return end
        state.online.artPending = nil
        local currentID = tostring(current.id)
        state.online.artClient:run("art", {currentID, current.coverURL or ""}, function(ok, rows, output)
            if ok then
                local row = rows[1] or {}
                if row[2] and row[2] ~= "" then
                    state.online.artSeen[currentID] = true
                    update_online_assets(currentID, row[2], "")
                end
            else
                state.online.artSeen[currentID] = nil
            end
            queue_online_lyrics(current)
            if state.online.artPending then run() end
        end)
    end
    run()
end

queue_online_lyrics = function(track)
    if not track or not state.online or not state.online.lyricClient then return end
    local id = tostring(track.id)
    local _, cachedLyrics = cached_asset_paths(track)
    if cachedLyrics ~= "" then update_online_assets(id, "", cachedLyrics); return end
    state.online.lyricPending = track
    if state.online.lyricClient:is_busy() then return end
    local function run()
        local current = state.online.lyricPending
        if not current then return end
        state.online.lyricPending = nil
        local currentID = tostring(current.id)
        state.online.lyricClient:run("lyric", {currentID}, function(ok, rows, output)
            if ok then
                local row = rows[1] or {}
                if row[2] and row[2] ~= "" then update_online_assets(currentID, "", row[2]) end
            end
            if state.online.lyricPending then run() end
        end)
    end
    run()
end

prefetch_online_url = function(track)
    if not track or not state.online or not state.online.prefetchClient then return end
    if not state.mpv then return end
    local id = tostring(track.id)
    if state.online.unplayable[id] then return end
    if cached_stream(track) then return end
    state.online.prefetchPending = track
    if state.online.prefetchClient:is_busy() then return end
    local function run()
        local current = state.online.prefetchPending
        if not current then return end
        state.online.prefetchPending = nil
        local currentID = tostring(current.id)
        state.online.prefetchInFlight = currentID
        state.online.prefetchClient:run("stream", {currentID, "exhigh"}, function(ok, rows, output)
            state.online.prefetchInFlight = nil
            state.online.prefetchWaitUntil = 0
            state.online.prefetchWaitTrack = nil
            if ok then
                local row = rows[1] or {}
                if row[2] and row[2] ~= "" then
                    state.online.urlCache[currentID] = {url = row[2], quality = row[3], kind = row[4], at = love.timer.getTime()}
                    log_line("online", "prefetch id=" .. currentID)
                    queue_online_art(current)
                    if state.online.pendingTrack and tostring(state.online.pendingTrack.id) == currentID and not state.online.client:is_busy() then
                        start_stream_ready(state.online.pendingTrack, row[2], row[3], row[4])
                    end
                end
            end
            if state.online.prefetchPending then run() end
        end)
    end
    run()
end

function prepare_online_track(track, forceRefresh)
    if not track or not state.online then return end
    if not track.available then set_playback_state("failed", track, "歌曲当前不可播放"); state.online.status = "歌曲当前不可播放"; return end
    state.online.wantedGeneration = (state.online.wantedGeneration or 0) + 1
    local generation = state.online.wantedGeneration
    state.online.pendingTrack = track
    state.online.prepareID = tostring(track.id)
    local trackID = tostring(track.id)
    if not forceRefresh and state.online.unplayable[trackID] then
        state.online.pendingTrack = nil
        state.online.prepareID = nil
        set_playback_state("failed", track, STREAM_UNAVAILABLE_MESSAGE)
        state.online.status = STREAM_UNAVAILABLE_MESSAGE
        state.status = STREAM_UNAVAILABLE_MESSAGE
        return
    end
    if forceRefresh then state.online.unplayable[trackID] = nil end
    if not state.online.requestTrack or tostring(state.online.requestTrack.id) ~= trackID then
        state.online.streamRetryCount = 0
    end
    state.online.requestTrack = track
    if forceRefresh then state.online.urlCache[trackID] = nil end

    local streaming = state.mpv and state.mpv:available()
    if not streaming then
        set_playback_state("failed", track, "在线播放不可用：未检测到 mpv")
        state.online.prepareID = nil
        state.online.pendingTrack = nil
        state.online.requestStartedAt = 0
        state.online.requestStreaming = false
        state.online.status = "未检测到 mpv，在线播放不可用"
        return
    end

    local cached = nil
    if not forceRefresh then cached = cached_stream(track) end
    if cached then start_stream_ready(track, cached.url, cached.quality, cached.kind); return end
    if not forceRefresh and state.online.prefetchInFlight == trackID then
        state.online.prefetchWaitUntil = love.timer.getTime() + 1.5
        state.online.prefetchWaitTrack = track
        state.online.status = "正在获取播放地址：" .. track.title
        return
    end

    if state.online.client:is_busy() then
        log_line("online", "cancel in-flight request; latest id=" .. trackID)
        state.online.client:cancel()
    end
    log_line("online", "request stream id=" .. trackID .. " generation=" .. tostring(generation))
    state.online.status = "正在获取播放地址：" .. track.title
    set_playback_state("resolving", track, "正在获取播放地址：" .. tostring(track.title or ""))
    state.online.requestStartedAt = love.timer.getTime()
    state.online.requestStreaming = true
    state.online.client:run("stream", {trackID, "exhigh"}, function(ok, rows, output)
        if generation ~= state.online.wantedGeneration then
            local latest = state.online.pendingTrack
            state.online.prepareID = latest and tostring(latest.id) or nil
            log_line("online", "discard stale result id=" .. trackID .. " generation=" .. tostring(generation))
            if latest and not state.online.client:is_busy() then prepare_online_track(latest, true) end
            return
        end
        state.online.prepareID = nil; state.online.requestStartedAt = 0; state.online.requestStreaming = false
        state.online.pendingTrack = nil
        if not ok then
            set_playback_state("failed", track, "获取播放地址失败")
            log_line("online", "request failed: " .. tostring(output))
            local errorText = tostring(output)
            local lowerError = errorText:lower()
            if lowerError:find("requires a valid netease membership", 1, true) or lowerError:find("song is unavailable", 1, true) then
                state.online.unplayable[trackID] = true
                set_playback_state("failed", track, STREAM_UNAVAILABLE_MESSAGE)
                state.online.status = STREAM_UNAVAILABLE_MESSAGE
                state.status = STREAM_UNAVAILABLE_MESSAGE
                return
            end
            retry_stream_playback("获取播放地址失败：" .. truncate(errorText, state.fonts.small, 240))
            return
        end
        local row = rows[1] or {}
        if row[2] and row[2] ~= "" then
            start_stream_ready(track, row[2], row[3], row[4])
        else
            retry_stream_playback("播放地址为空")
        end
    end)
end

retry_stream_playback = function(reason)
    if not state.online then return end
    local track = state.online.requestTrack or state.online.pendingTrack or state.nowPlaying
    if not track or not track.online then
        state.online.status = reason or "无法播放"
        return
    end
    local id = tostring(track.id)
    state.online.urlCache[id] = nil
    local targetPlaying = state.nowPlaying and tostring(state.nowPlaying.id) == id
    if targetPlaying and state.mpv then state.mpv:stop() end
    if targetPlaying then
        state.streaming, state.playing, state.audioReady, state.playbackConfirmed = false, false, false, false
    end
    local count = state.online.streamRetryCount or 0
    if count >= 1 then
        set_playback_state("failed", track, reason or "播放失败")
        state.online.status = (reason or "播放失败") .. "，重试后仍然无法播放"
        state.status = state.online.status
        return
    end
    state.online.streamRetryCount = count + 1
    set_playback_state("resolving", track, reason or "重新获取播放地址")
    state.online.status = (reason or "播放失败") .. string.format("，正在重新获取播放地址（%d/2）", count + 1)
    prepare_online_track(track, true)
end

function poll_login()
    if not state.online or state.online.view ~= "login" or state.online.client:is_busy() then return end
    state.online.client:run("login-poll", {}, function(ok, rows, output)
        if not ok then
            state.online.loginState, state.online.loginMessage = "error", truncate(output, state.fonts.small, 300)
            state.online.pollAt = love.timer.getTime() + 3
            return
        end
        local row = rows[1] or {}
        state.online.loginState = row[1] or "waiting"
        local messageMap = {waiting = "等待扫码", scanned = "已扫码，请在手机上确认", expired = "二维码已过期", error = "登录失败"}
        state.online.loginMessage = messageMap[state.online.loginState] or row[2] or "等待扫码"
        if state.online.loginState == "success" then
            state.online.loggedIn, state.online.nickname, state.online.uid = true, row[3] or "", tonumber(row[4]) or 0
            state.online.vipType = tonumber(row[5]) or 0
            state.online.redVipLevel = tonumber(row[6]) or 0
            state.online.vipLevel = tonumber(row[7]) or 0
            state.online.member = state.online.vipType > 0 or state.online.redVipLevel > 0
            state.online.qrImage = nil
            state.online.view = "menu"
            state.online.status = "已登录：" .. state.online.nickname .. (state.online.member and " | 会员权益已识别" or " | 当前账号未检测到会员权益")
            refresh_playlists()
        elseif state.online.loginState ~= "expired" then
            state.online.pollAt = love.timer.getTime() + 1.5
        end
    end)
end

local function online_back()
    if not state.online then set_section("local"); return true end
    if state.online.view == "login" then
        state.online.view = state.online.loggedIn and "menu" or "home"
        apply_online_view()
    elseif state.online.view == "tracks" then
        state.online.view = "menu"
        state.online.selected, state.online.scroll = 1, 1
        apply_online_view()
    else
        set_section("local")
    end
    return true
end

local function select_track(index, autoplay)
    if #state.tracks == 0 then return end
    state.selected = ((index - 1) % #state.tracks) + 1
    ensure_selected_visible()
    if state.section == "online" then
        save_online_ui()
        if autoplay and state.online.view ~= "tracks" then activate_online_item(); return end
        if autoplay then prepare_online_track(state.tracks[state.selected]) end
        return
    end
    if autoplay then start_track(state.tracks[state.selected] or state.tracks[1]) end
end
local function selected_matches_playing()
    local selected, playing = state.tracks[state.selected], state.nowPlaying
    if not selected or not playing then return false end
    if selected.id and playing.id then return tostring(selected.id) == tostring(playing.id) end
    if selected.path and playing.path then return selected.path == playing.path end
    return false
end

local play_selected
local toggle_play

local function loading_active()
    return state.playbackState == "resolving" or state.playbackState == "loading" or state.playbackState == "starting" or state.playbackState == "buffering"
end

local function cancel_loading()
    if state.online then
        state.online.wantedGeneration = (state.online.wantedGeneration or 0) + 1
    end
    if state.online and state.online.client and state.online.client:is_busy() then
        state.online.client:cancel()
    end
    if state.online then
        state.online.pendingTrack = nil
        state.online.prepareID = nil
        state.online.requestStartedAt = 0
        state.online.requestStreaming = false
    end
    local target = state.playbackTrack
    if target then set_track_status(target, "idle", nil) end
    if state.streaming and state.mpv and state.mpv:is_active() and not state.audioReady then
        state.mpv:stop()
        state.streaming = false
    end
    if state.streaming and state.mpv and state.mpv:is_active() and state.audioReady then
        set_playback_state(state.playing and "playing" or "paused", state.nowPlaying, nil)
    else
        state.streaming, state.playing, state.audioReady = false, false, false
        state.playbackState, state.playbackTrack, state.playbackError = "idle", nil, nil
    end
    set_user_status("已取消加载")
end

play_selected = function()
    local selected = state.tracks[state.selected]
    if not selected then return end
    if same_track(selected, state.nowPlaying) and state.audioReady then
        if not state.playing then toggle_play() end
        return
    end
    if state.section == "online" and state.online.view == "tracks" then
        if state.playbackState == "failed" then state.online.streamRetryCount = 0 end
        prepare_online_track(selected, state.playbackState == "failed")
    elseif state.section == "local" then
        start_track(selected)
    end
end

toggle_play = function()
    if loading_active() then cancel_loading(); return end
    local selected = state.tracks[state.selected]
    if selected and selected.kind ~= "action" and selected.kind ~= "playlist" and not same_track(selected, state.nowPlaying) then
        play_selected()
        return
    end
    if state.streaming and state.mpv and state.mpv:is_active() and state.audioReady then
        state.playing = not state.mpv:toggle_pause()
        set_playback_state(state.playing and "playing" or "paused", state.nowPlaying, nil)
        return
    end
    if state.source then
        state.playing = not state.playing
        if state.playing then state.source:play() else state.source:pause() end
        set_playback_state(state.playing and "playing" or "paused", state.nowPlaying, nil)
        return
    end
    play_selected()
end

local function activate_selected()
    if state.section == "online" and state.online.view ~= "tracks" then
        activate_online_item()
        return
    end
    select_track(state.selected, false)
    local selected = state.tracks[state.selected]
    if selected and selected.kind ~= "action" and selected.kind ~= "playlist" then
        local message = "已选择：" .. tostring(selected.title or selected.name or "") .. "  按 Start 播放"
        if state.section == "online" then state.online.status = message else state.status = message end
    end
end

local function next_track(delta)
    if #state.tracks == 0 then return end
    if state.section == "online" and state.online.view == "tracks" then
        state.selected = ((state.selected + delta - 1) % #state.tracks) + 1
        ensure_selected_visible(); save_online_ui()
        prepare_online_track(state.tracks[state.selected])
        return
    end
    if state.shuffle and delta == 1 then
        local next_index = state.selected
        if #state.tracks > 1 then repeat next_index = math.random(#state.tracks) until next_index ~= state.selected end
        select_track(next_index, true)
    else select_track(state.selected + delta, true) end
end
local function current_output()
    if state.audioRoute and state.audioRoute.is_headphones then
        return state.audioRoute:is_headphones() and "headphone" or "speaker"
    end
    return state.output or "speaker"
end

local function volume_for_output(output)
    return output == "headphone" and state.headphoneVolume or state.speakerVolume
end

local function store_current_volume()
    if state.output == "headphone" then
        state.headphoneVolume = state.masterVolume
    else
        state.speakerVolume = state.masterVolume
    end
end

local save_settings

local function sync_output_volume()
    local output = current_output()
    if output == state.output then return end
    store_current_volume()
    state.output = output
    state.masterVolume = volume_for_output(output)
    apply_source_volume()
    save_settings()
end

local function load_settings()
    local data = love.filesystem.read("settings.txt")
    state.output = current_output()
    if not data then
        state.masterVolume = volume_for_output(state.output)
        return
    end
    local speaker, headphone, volume, muted = data:match("speaker=([%d%.]+)%s*headphone=([%d%.]+)%s*master=([%d%.]+)%s*muted=(%d+)")
    if not speaker then volume, muted = data:match("master=([%d%.]+)%s*muted=(%d+)") end
    local fallback = quantize_volume(tonumber(volume) or 0.5)
    state.speakerVolume = quantize_volume(tonumber(speaker) or fallback)
    state.headphoneVolume = quantize_volume(tonumber(headphone) or fallback)
    state.masterVolume = volume_for_output(state.output)
    if muted then state.muted = muted == "1" end
    apply_source_volume()
end

save_settings = function()
    store_current_volume()
    love.filesystem.write("settings.txt", string.format("speaker=%.4f\nheadphone=%.4f\nmaster=%.4f\nmuted=%d\n", state.speakerVolume, state.headphoneVolume, state.masterVolume, state.muted and 1 or 0))
end

local function set_master_volume(value)
    state.masterVolume = quantize_volume(value)
    apply_source_volume()
    save_settings()
end

local function adjust_master_volume(delta)
    set_master_volume(state.masterVolume + delta)
end

local function toggle_mute() state.muted = not state.muted; apply_source_volume(); save_settings() end

local function seek_fraction(frac)
    if state.duration <= 0 then return end
    local seconds = state.duration * clamp(frac, 0, 1)
    if state.streaming and state.mpv and state.mpv:is_active() then
        state.position = seconds
        state.mpv:seek(seconds)
        return
    end
    if not state.source then return end
    state.position = seconds
    state.source:seek(state.position)
end
local function split_paths(value)
    local result = {}
    for item in string.gmatch(value or "", "[^:]+") do
        item = item:gsub("^%s+", ""):gsub("%s+$", "")
        if item ~= "" then result[#result + 1] = item end
    end
    return result
end
local function unique_paths(paths)
    local seen, result = {}, {}
    for _, path in ipairs(paths) do
        if path and path ~= "" and not seen[path] then seen[path] = true; result[#result + 1] = path end
    end
    return result
end
local function app_root() return os.getenv("RGMUSIC_ROOT") or love.filesystem.getSource() end
log_path = function()
    return (os.getenv("RGMUSIC_LOG_DIR") or (app_root() .. "/logs")) .. "/online.log"
end

log_line = function(tag, message)
end

log_tail = function(path, count)
    local file = io.open(path, "rb")
    if not file then return "" end
    local size = file:seek("end") or 0
    local read_size = math.min(size, count or 4096)
    file:seek("set", math.max(0, size - read_size))
    local data = file:read("*a") or ""
    file:close()
    return data
end

local function netease_binary()
    local override = os.getenv("RGMUSIC_NETEASE_BIN")
    if override and override ~= "" then return override end
    if love.system.getOS() == "Windows" then return app_root() .. "/bin/rgmusic-netease.exe" end
    return app_root() .. "/bin/rgmusic-netease.aarch64"
end
local function music_paths()
    local result = split_paths(os.getenv("RGMUSIC_PATHS"))
    local config = io.open(app_root() .. "/music_paths.txt", "r")
    if config then
        for line in config:lines() do
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" and line:sub(1, 1) ~= "#" then result[#result + 1] = line end
        end
        config:close()
    end
    result[#result + 1] = app_root() .. "/music"
    return unique_paths(result)
end
local function start_scan()
    state.scanActive, state.scanTracks, state.scanCount, state.scanRoot = true, {}, 0, ""
    state.status = "正在扫描音乐..."
    state.scanCoroutine = Library.scan(state.paths)
end
local function finish_scan()
    state.scanActive = false
    local tracks = #state.scanTracks > 0 and state.scanTracks or {}
    if state.section == "local" then
        local previous = current_track()
        state.tracks, state.selected, state.scroll = tracks, 1, 1
        if previous and previous.path then
            for index, track in ipairs(state.tracks) do if track.path == previous.path then state.selected = index; break end end
        end
        ensure_selected_visible()
    end
    if state.localUI then
        state.localUI.tracks = tracks
        state.localUI.selected, state.localUI.scroll = 1, 1
    end
    if state.section == "local" then
        state.status = #state.scanTracks > 0 and string.format("音乐库已更新：%d 首", #state.scanTracks) or "未找到音乐，使用内置试听音"
    end
end
local function process_scan(budget)
    if not state.scanActive or not state.scanCoroutine then return end
    local started = love.timer.getTime()
    while state.scanActive and love.timer.getTime() - started < budget do
        local ok, result = coroutine.resume(state.scanCoroutine)
        if not ok then state.scanActive = false; state.status = "扫描失败：" .. tostring(result); break end
        if coroutine.status(state.scanCoroutine) == "dead" then finish_scan(); break
        elseif type(result) == "table" and result.track then
            state.scanTracks[#state.scanTracks + 1] = result.track
            state.scanCount = result.count or #state.scanTracks
            state.scanRoot = result.root or state.scanRoot
            state.status = string.format("正在扫描：%d 首", state.scanCount)
        end
    end
end
local function load_font_data()
    local bundled = {
        "assets/fonts/wqy-microhei.ttf",
        "assets/fonts/wqy-microhei.ttc",
        "assets/fonts/NotoSansCJKsc-Regular.otf",
    }
    for _, path in ipairs(bundled) do
        if love.filesystem.getInfo(path, "file") then
            local ok = pcall(love.graphics.newFont, path, 16)
            if ok then
                state.fontPath = path
                print("[font] bundled", path)
                return nil
            end
        end
        local data = love.filesystem.read(path)
        if data and #data > 0 then
            local ok, fileData = pcall(love.filesystem.newFileData, data, path:match("([^/\\]+)$") or "font")
            if ok then return fileData end
        end
    end
    local candidates = {os.getenv("RGMUSIC_FONT"),
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJKsc-Regular.otf",
        "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
        "C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"}
    for _, path in ipairs(candidates) do
        if path and path ~= "" then
            local file = io.open(path, "rb")
            if file then
                local data = file:read("*a"); file:close()
                local ok, result = pcall(love.filesystem.newFileData, data, path:match("([^/\\]+)$") or "font")
                if ok then return result end
            end
        end
    end
end
local function make_font(size)
    if state.fontPath then
        local ok, font = pcall(love.graphics.newFont, state.fontPath, size)
        if ok then return font end
    end
    if state.fontData then
        local ok, font = pcall(love.graphics.newFont, state.fontData, size)
        if ok then return font end
    end
    return love.graphics.newFont(size)
end
local function draw_cover_image(image, x, y, w, h, radius)
    radius = radius or 0
    love.graphics.stencil(function()
        love.graphics.rectangle("fill", x, y, w, h, radius, radius)
    end, "replace", 1)
    love.graphics.setStencilTest("greater", 0)
    love.graphics.setColor(1, 1, 1, 1)
    local iw, ih = image:getDimensions()
    local scale = math.max(w / iw, h / ih)
    local dw, dh = iw * scale, ih * scale
    local previous_scissor = {love.graphics.getScissor()}
    love.graphics.setScissor(x, y, w, h)
    love.graphics.draw(image, x + (w - dw) / 2, y + (h - dh) / 2, 0, scale, scale)
    love.graphics.setScissor()
    if previous_scissor[1] then love.graphics.setScissor(unpack(previous_scissor)) end
    love.graphics.setStencilTest()
end
local function draw_fallback_cover(track, x, y, size, radius)
    radius = radius or 0
    local p = track.palette or {{0.16,0.22,0.38},{0.35,0.58,0.96},{0.95,0.45,0.48}}
    color(p[1]); love.graphics.rectangle("fill", x, y, size, size, radius or 18, radius or 18)
    color(p[2], 0.24); love.graphics.rectangle("fill", x + size * 0.12, y + size * 0.16, size * 0.34, size * 0.045, size * 0.02, size * 0.02)
    color(p[3], 0.20); love.graphics.rectangle("fill", x + size * 0.12, y + size * 0.69, size * 0.76, size * 0.045, size * 0.02, size * 0.02)
    color(p[2], 0.28); love.graphics.rectangle("fill", x + size * 0.12, y + size * 0.79, size * 0.48, size * 0.035, size * 0.018, size * 0.018)
end

local function draw_cover(track, x, y, size, radius)
    radius = radius or 0
    if state.coverImage then draw_cover_image(state.coverImage, x, y, size, size, radius)
    else draw_fallback_cover(track, x, y, size, radius) end
end
local function draw_cover_mood(x, y, w, h, alpha)
    if not state.coverMood then return false end
    local iw, ih = state.coverMood:getDimensions()
    local scale = math.max(w / iw, h / ih)
    local dw, dh = iw * scale, ih * scale
    love.graphics.setColor(1, 1, 1, alpha or 0.28)
    love.graphics.draw(state.coverMood, x + (w - dw) / 2, y + (h - dh) / 2, 0, scale, scale)
    return true
end

local function draw_upper_background()
    color(C.upper); love.graphics.rectangle("fill", 0, 0, SCREEN_W, SCREEN_H)
    local a = accent()
    if draw_cover_mood(0, 0, SCREEN_W, SCREEN_H, 0.50) then
        color(C.upper, 0.45); love.graphics.rectangle("fill", 0, 0, SCREEN_W, SCREEN_H)
    end
    color(a, 0.070); love.graphics.rectangle("fill", 0, 0, SCREEN_W, SCREEN_H)
end

local function draw_volume_slider(x, y, width, height, frac)
    frac = clamp(frac or 0, 0, 1)
    local a = accent()
    rounded_panel(x, y, width, height, C.card3, height / 2)
    color(a, 0.72)
    love.graphics.rectangle("fill", x, y, width * frac, height, height / 2, height / 2)
    local knob_x, knob_y = x + width * frac, y + height / 2
    color(C.card)
    love.graphics.circle("fill", knob_x, knob_y, height * 1.18)
end
local function draw_progress(x, y, width, height, frac, active)
    frac = clamp(frac or 0, 0, 1)
    local a = active or accent()
    rounded_panel(x, y, width, height, C.card3, height / 2)
    color(a); love.graphics.rectangle("fill", x, y, width * frac, height, height / 2, height / 2)
    local knob_x, knob_y = x + width * frac, y + height / 2
    color(a); love.graphics.circle("fill", knob_x, knob_y, height * 1.25)
end
local function draw_upper()
    draw_upper_background()
    local track, a = current_track(), accent()
    color(C.muted)
    love.graphics.setFont(state.fonts.small)
    local playbackHeading = ({
        idle = "等待播放",
        resolving = "正在获取播放地址",
        loading = "正在加载",
        starting = "正在启动播放",
        buffering = "正在缓冲",
        playing = "正在播放",
        paused = "已暂停",
        failed = "播放失败"
    })[state.playbackState] or "等待播放"
    local chip_width = state.fonts.small:getWidth(playbackHeading) + 34
    rounded_panel(42, 34, chip_width, 38, {a[1], a[2], a[3], 0.16}, 19)
    color(a); love.graphics.print(playbackHeading, 58, 43)
    if state.playbackState == "failed" and state.playbackError then
        love.graphics.setFont(state.fonts.tiny)
        love.graphics.printf(truncate(state.playbackError, state.fonts.tiny, 900), 54, 78, 900)
        love.graphics.setFont(state.fonts.small)
    end
    local formatText = tostring(track.extension or "audio"):upper()
    local formatWidth = state.fonts.tiny:getWidth(formatText) + 28
    rounded_panel(982 - formatWidth, 34, formatWidth, 38, C.card2, 19)
    color(C.muted); love.graphics.setFont(state.fonts.tiny)
    love.graphics.printf(formatText, 982 - formatWidth, 45, formatWidth, "center")

    draw_cover(track, 64, 190, 330, 0)

    local x, width = 438, 522
    color(C.text)
    love.graphics.setFont(state.fonts.title)
    love.graphics.print(truncate(track.title, state.fonts.title, width), x, 132)
    color(C.muted)
    love.graphics.setFont(state.fonts.body)
    love.graphics.print(truncate(track.artist, state.fonts.body, width), x, 194)
    love.graphics.setFont(state.fonts.small)
    love.graphics.print(truncate(track.album, state.fonts.small, width), x, 228)

    glass_panel(x, 268, width, 340, 24, C.card, 0.48)
    color(a)
    love.graphics.setFont(state.fonts.label)
    love.graphics.print("歌詞", x + 24, 276)
    color(C.text)
    love.graphics.setFont(state.fonts.body)
    local current_lyric = current_lyric_index()
    if state.lyrics.available and current_lyric then
        local first = math.max(1, current_lyric - 1)
        for offset = 0, 3 do
            local index = first + offset
            local entry = state.lyrics.lines[index]
            if entry then
                local active = index == current_lyric
                local line_y = 326 + offset * 56
                if active then
                    color(a, 0.11)
                    love.graphics.rectangle("fill", x + 18, line_y - 6, width - 36, 36, 12, 12)

                end
                local text_x = active and x + 34 or x + 24
                color(active and a or C.muted, active and 1 or 0.60)
                love.graphics.setFont(active and state.fonts.body or state.fonts.small)
                love.graphics.printf(entry.text, text_x, line_y, width - (text_x - x) - 24)
            end
        end
    else
        color(C.muted)
        love.graphics.setFont(state.fonts.body)
        love.graphics.print("暂无歌词", x + 24, 316)
        love.graphics.setFont(state.fonts.small)
        love.graphics.print("请放置同名 .lrc 文件", x + 24, 356)
    end

    color(C.muted)
    love.graphics.setFont(state.fonts.small)
    love.graphics.print(fmt_time(state.position), x, 624)
    love.graphics.printf(fmt_time(state.duration), x, 624, width, "right")
    draw_progress(x, 660, width, 8, state.duration > 0 and state.position / state.duration or 0, a)
end

local function draw_button(r, label, active, font)
    rounded_panel(r.x, r.y, r.w, r.h, active and accent() or C.card2, r.h / 2)
    color(active and C.dark or C.text)
    love.graphics.setFont(font or state.fonts.control)
    love.graphics.printf(label, r.x, r.y + (r.h - (font or state.fonts.control):getHeight()) / 2 - 1, r.w, "center")
end
local function draw_list_status_icon(cx, cy, status)
    local a = accent()
    if status == "playing" then
        color(a)
        love.graphics.polygon("fill", cx - 7, cy - 9, cx - 7, cy + 9, cx + 8, cy)
    elseif status == "paused" then
        color(C.muted)
        love.graphics.rectangle("fill", cx - 7, cy - 9, 5, 18, 2, 2)
        love.graphics.rectangle("fill", cx + 2, cy - 9, 5, 18, 2, 2)
    elseif status == "failed" then
        color({0.82, 0.22, 0.24, 1})
        love.graphics.circle("fill", cx, cy, 10)
        color({1, 1, 1, 1})
        love.graphics.rectangle("fill", cx - 1.5, cy - 6, 3, 8, 1.5, 1.5)
        love.graphics.circle("fill", cx, cy + 5, 1.8)
    else
        color(a)
        love.graphics.circle("fill", cx - 7, cy, 2.6)
        love.graphics.circle("fill", cx, cy, 2.6)
        love.graphics.circle("fill", cx + 7, cy, 2.6)
    end
end

local function draw_library()
    state.rowHitboxes = {}
    local items = state.tracks
    for slot = 1, VISIBLE_ROWS do
        local index = state.scroll + slot - 1
        local item = items[index]
        if item then
            local y = 124 + (slot - 1) * 84
            local r = {x = 34, y = y, w = 580, h = 70, index = index}
            state.rowHitboxes[#state.rowHitboxes + 1] = r
            local selected = index == state.selected
            soft_panel(r.x, r.y, r.w, r.h, selected and C.card2 or C.card, 18, selected and 0.075 or 0.035)
            local title = item.title or item.name or ""
            local status = get_track_status(item)
            if is_favorite(item) then title = "★ " .. title end
            local subtitle = item.subtitle
            if not subtitle then
                subtitle = tostring(item.artist or "") .. (item.album and item.album ~= "" and ("   ·  " .. item.album) or "")
            end
            color(item.available == false and C.muted or C.text)
            love.graphics.setFont(state.fonts.track)
            love.graphics.print(truncate(title, state.fonts.track, 430), r.x + 28, r.y + 11)
            color(C.muted)
            love.graphics.setFont(state.fonts.small)
            love.graphics.print(truncate(subtitle, state.fonts.small, 416), r.x + 28, r.y + 43)
            local right = nil
            local iconStatus = nil
            if item.kind == "action" then
                right = "A"
            elseif item.kind == "playlist" then
                right = tostring(item.trackCount or 0)
            elseif status == "failed" or status == "loading" or status == "starting" or status == "resolving" or status == "buffering" or status == "playing" or status == "paused" then
                iconStatus = status
            elseif item.duration then
                right = fmt_time(item.duration)
            end
            if right then
                color(C.muted)
                love.graphics.printf(right, r.x, r.y + 25, r.w - 18, "right")
            end
            if iconStatus then
                draw_list_status_icon(r.x + r.w - 36, r.y + r.h / 2, iconStatus)
            end
        end
    end
    if #items > VISIBLE_ROWS then
        local rail_x, rail_y, rail_w, rail_h = 622, 136, 5, 486
        rounded_panel(rail_x, rail_y, rail_w, rail_h, C.card3, rail_w / 2)
        local max_scroll = math.max(1, #items - VISIBLE_ROWS)
        local thumb_h = math.max(42, rail_h * VISIBLE_ROWS / #items)
        local progress = (state.scroll - 1) / max_scroll
        local thumb_y = rail_y + (rail_h - thumb_h) * progress
        color(accent(), 0.62)
        love.graphics.rectangle("fill", rail_x, thumb_y, rail_w, thumb_h, rail_w / 2, rail_w / 2)
    end
end
local function draw_toggle_button(r, kind, active)
    local a = accent()
    rounded_panel(r.x, r.y, r.w, r.h, active and a or C.card2, r.h / 2)
    local fg = active and C.dark or C.text
    color(fg)
    local cx, cy = r.x + r.w / 2, r.y + r.h / 2
    if kind == "shuffle" then
        love.graphics.setLineWidth(2.2)
        love.graphics.line(cx - 11, cy - 7, cx + 7, cy + 7)
        love.graphics.line(cx - 11, cy + 7, cx + 7, cy - 7)
        love.graphics.polygon("fill", cx + 12, cy + 8, cx + 4, cy + 7, cx + 9, cy + 1)
        love.graphics.polygon("fill", cx + 12, cy - 8, cx + 4, cy - 7, cx + 9, cy - 1)
        love.graphics.setLineWidth(1)
    else
        love.graphics.setLineWidth(2.2)
        love.graphics.line(cx - 11, cy - 6, cx + 7, cy - 6)
        love.graphics.polygon("fill", cx + 12, cy - 6, cx + 5, cy - 10, cx + 5, cy - 2)
        love.graphics.line(cx + 11, cy + 6, cx - 7, cy + 6)
        love.graphics.polygon("fill", cx - 12, cy + 6, cx - 5, cy + 2, cx - 5, cy + 10)
        love.graphics.setLineWidth(1)
    end
end

local function draw_transport_button(r, kind, active)
    rounded_panel(r.x, r.y, r.w, r.h, active and accent() or C.card2, r.h / 2)
    local cx, cy = r.x + r.w / 2, r.y + r.h / 2
    color(active and C.dark or C.text)
    if kind == "prev" then
        love.graphics.polygon("fill", cx - 2, cy - 10, cx - 2, cy + 10, cx - 13, cy)
        love.graphics.polygon("fill", cx + 12, cy - 10, cx + 12, cy + 10, cx + 1, cy)
    elseif kind == "next" then
        love.graphics.polygon("fill", cx - 12, cy - 10, cx - 12, cy + 10, cx - 1, cy)
        love.graphics.polygon("fill", cx + 2, cy - 10, cx + 2, cy + 10, cx + 13, cy)
    elseif kind == "pause" then
        love.graphics.rectangle("fill", cx - 9, cy - 11, 7, 22, 2, 2)
        love.graphics.rectangle("fill", cx + 2, cy - 11, 7, 22, 2, 2)
    else
        love.graphics.polygon("fill", cx - 8, cy - 12, cx - 8, cy + 12, cx + 8, cy)
    end
end

local function draw_player_card()
    local x, y, w, h = 666, 112, 318, 560
    if state.section == "online" and state.online.view == "login" then
        glass_panel(x, y, w, h, 24, C.card, 0.42)
        local loginAccent = accent()
        rounded_panel(x + 18, y + 16, w - 36, 42, {loginAccent[1], loginAccent[2], loginAccent[3], 0.10}, 18)
        color(C.text); love.graphics.setFont(state.fonts.track)
        love.graphics.printf("扫码登录网易云", x + 20, y + 26, w - 40, "center")
        color(C.muted); love.graphics.setFont(state.fonts.small)
        love.graphics.printf("使用手机网易云音乐扫描下方二维码", x + 20, y + 70, w - 40, "center")
        rounded_panel(x + 34, y + 120, 250, 252, C.card, 22)
        if state.online.qrImage then
            love.graphics.setColor(1, 1, 1, 1)
            local iw, ih = state.online.qrImage:getDimensions()
            local qs = 240 / math.max(iw, ih)
            love.graphics.draw(state.online.qrImage, x + 39 + (240 - iw * qs) / 2, y + 126 + (240 - ih * qs) / 2, 0, qs, qs)
        else
            rounded_panel(x + 39, y + 126, 240, 240, C.card2, 18)
            color(C.muted); love.graphics.setFont(state.fonts.body)
            love.graphics.printf("二维码加载中...", x + 39, y + 226, 240, "center")
        end
        rounded_panel(x + 18, y + 416, w - 36, 48, C.card2, 18)
        color(accent()); love.graphics.setFont(state.fonts.label)
        love.graphics.printf(state.online.loginMessage or "等待扫码", x + 20, y + 392, w - 40, "center")
        color(C.muted); love.graphics.setFont(state.fonts.small)
        love.graphics.printf("扫码后在手机上确认登录", x + 20, y + 430, w - 40, "center")
        local a = accent()
            local vx, vy, vw = x + 26, y + 492, w - 52
        color(C.text); love.graphics.setFont(state.fonts.control); love.graphics.print("音量", vx, y + 446)
        color(accent()); love.graphics.setFont(state.fonts.control); love.graphics.printf(string.format("%d%%", math.floor(state.masterVolume * 100 + 0.5)), vx, y + 446, vw, "right")
        state.quickVolumeRect = {x = vx - 20, y = y + 438, w = vw + 40, h = 78}
        draw_volume_slider(vx, vy, vw, 16, state.masterVolume)
        state.buttonRects, state.progressRect = {}, nil
        return
    end
    glass_panel(x, y, w, h, 24, C.card, 0.42)
    local track = current_track()
    local statusLabel = ({
        idle = "等待播放", resolving = "获取地址", loading = "正在加载", starting = "启动播放",
        buffering = "正在缓冲", playing = "正在播放", paused = "已暂停", failed = "播放失败"
    })[state.playbackState] or "等待播放"
    local sa = accent()
    local statusWidth = state.fonts.tiny:getWidth(statusLabel) + 24
    rounded_panel(x + 18, y + 14, statusWidth, 30, {sa[1], sa[2], sa[3], 0.12}, 15)
    color(sa); love.graphics.setFont(state.fonts.tiny); love.graphics.print(statusLabel, x + 30, y + 21)

    color(C.text)
    love.graphics.setFont(state.fonts.track)
    love.graphics.printf(truncate(track.title, state.fonts.track, w - 44), x + 22, y + 56, w - 44, "center")
    color(C.muted)
    love.graphics.setFont(state.fonts.small)
    love.graphics.printf(truncate(track.artist, state.fonts.small, w - 44), x + 22, y + 94, w - 44, "center")
    love.graphics.printf(truncate(track.album, state.fonts.small, w - 44), x + 22, y + 118, w - 44, "center")

    color(C.line, 0.8)
    love.graphics.line(x + 22, y + 154, x + w - 22, y + 154)
    love.graphics.print(fmt_time(state.position), x + 22, y + 170)
    love.graphics.printf(fmt_time(state.duration), x, y + 170, w - 22, "right")
    state.progressRect = {x = x + 16, y = y + 188, w = w - 32, h = 30}
    draw_progress(x + 22, y + 198, w - 44, 8, state.duration > 0 and state.position / state.duration or 0, accent())

    local buttons = {
        prev = {x = x + 22, y = y + 246, w = 82, h = 56},
        play = {x = x + 112, y = y + 234, w = 94, h = 78},
        next = {x = x + 214, y = y + 246, w = 82, h = 56},
        shuffle = {x = x + 60, y = y + 326, w = 84, h = 36},
        repeatTrack = {x = x + 174, y = y + 326, w = 84, h = 36},
    }
    state.buttonRects = buttons
    draw_transport_button(buttons.prev, "prev", false)
    draw_transport_button(buttons.play, state.playing and "pause" or "play", true)
    draw_transport_button(buttons.next, "next", false)
    -- Volume is controlled by the slider below.
    draw_toggle_button(buttons.shuffle, "shuffle", state.shuffle)
    draw_toggle_button(buttons.repeatTrack, "repeat", state.repeatTrack)

    local a = accent()
    local vx, vy, vw = x + 26, y + 492, w - 52
    color(C.text)
    love.graphics.setFont(state.fonts.control)
    love.graphics.print("音量", vx, y + 446)
    color(accent())
    love.graphics.setFont(state.fonts.control)
    love.graphics.printf(string.format("%d%%", math.floor(state.masterVolume * 100 + 0.5)), vx, y + 446, vw, "right")
    state.quickVolumeRect = {x = vx - 20, y = y + 438, w = vw + 40, h = 78}
    draw_volume_slider(vx, vy, vw, 16, state.masterVolume)
end

local function draw_lower()
    color(C.lower); love.graphics.rectangle("fill", 0, 0, SCREEN_W, SCREEN_H)
    if draw_cover_mood(0, 0, SCREEN_W, SCREEN_H, 0.24) then
        color(C.lower, 0.56); love.graphics.rectangle("fill", 0, 0, SCREEN_W, SCREEN_H)
    end
    local title = "本地音乐"
    if state.section == "online" then
        title = state.online.view == "tracks" and "网易云 · 歌单" or "网易云音乐"
    end
    color(C.text); love.graphics.setFont(state.fonts.header); love.graphics.print(title, 38, 34)
    color(C.muted); love.graphics.setFont(state.fonts.small)
    local count_text
    if state.section == "local" then
        count_text = state.scanActive and string.format("正在扫描 %d 首", state.scanCount) or string.format("%d 首歌曲", #state.tracks)
        count_text = count_text .. "   ·  MP3 / OGG / WAV"
    else
        count_text = state.online.status
    end
    love.graphics.print(truncate(count_text, state.fonts.small, 560), 40, 84)
    rounded_panel(614, 32, 238, 54, C.card2, 27)
    state.sectionRects["local"] = {x = 620, y = 36, w = 108, h = 46}
    state.sectionRects.online = {x = 736, y = 36, w = 110, h = 46}
    draw_button(state.sectionRects["local"], "L 本地", state.section == "local", state.fonts.small)
    draw_button(state.sectionRects.online, "R 网易云", state.section == "online", state.fonts.small)
    state.rescanRect = {x = 854, y = 38, w = 132, h = 42}
    local refresh_label = state.section == "local" and "重新扫描" or (state.online.view == "tracks" and "返回歌单" or "刷新")
    draw_button(state.rescanRect, refresh_label, false, state.fonts.small)
    draw_library(); draw_player_card()
    color(state.audioReady and accent() or C.accent2, 0.92)
    local footerFont = state.fonts.footer or state.fonts.tiny
    local footer = state.section == "online" and state.online.status or state.status
    glass_panel(34, 711, 956, 40, 20, C.card, 0.58)
    color(C.muted); love.graphics.setFont(footerFont)
    love.graphics.print(truncate(footer, footerFont, 500), 52, 719)
    local hints = {{"A", "选择"}, {"B", "返回"}, {"X", "播放"}, {"Y", "重试"}}
    local hint_region_x, hint_region_width = 560, 424
    local widths, hint_total = {}, 0
    for index, hint in ipairs(hints) do
        widths[index] = footerFont:getWidth(hint[1]) + footerFont:getWidth(hint[2]) + 20
        hint_total = hint_total + widths[index]
    end
    local gap = math.max(10, (hint_region_width - hint_total) / (#hints + 1))
    local hint_x = hint_region_x + gap
    for index, hint in ipairs(hints) do
        local key_width = footerFont:getWidth(hint[1]) + 12
        local pill_width = widths[index]
        local text_y = 716 + (30 - footerFont:getHeight()) / 2
        rounded_panel(hint_x, 716, pill_width, 30, C.card2, 15)
        color(accent()); love.graphics.printf(hint[1], hint_x + 5, text_y, key_width - 4, "center")
        color(C.muted); love.graphics.print(hint[2], hint_x + key_width + 2, text_y)
        hint_x = hint_x + pill_width + gap
    end
end
local function point_in(r, x, y) return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h end
local function slider_fraction(r, x) return clamp((x - r.x) / r.w, 0, 1) end
local function handle_tap(x, y)
    if point_in(state.sectionRects["local"], x, y) then set_section("local"); return end
    if point_in(state.sectionRects.online, x, y) then set_section("online"); return end
    if point_in(state.rescanRect, x, y) then
        if state.section == "local" then start_scan()
        elseif state.online.view == "tracks" then online_back()
        elseif state.online.loggedIn then refresh_playlists()
        else
            state.online.started = false; set_section("local"); set_section("online")
        end
        return
    end
    for _, row in ipairs(state.rowHitboxes or {}) do
        if point_in(row, x, y) then select_track(row.index, false); return end
    end
    local buttons = state.buttonRects
    if point_in(buttons.play, x, y) then toggle_play()
    elseif point_in(buttons.prev, x, y) then next_track(-1)
    elseif point_in(buttons.next, x, y) then next_track(1)
    elseif point_in(buttons.shuffle, x, y) then state.shuffle = not state.shuffle
    elseif point_in(buttons.repeatTrack, x, y) then state.repeatTrack = not state.repeatTrack
    elseif point_in(state.quickVolumeRect, x, y) then set_master_volume(slider_fraction(state.quickVolumeRect, x))
    elseif point_in(state.progressRect, x, y) then seek_fraction(slider_fraction(state.progressRect, x))
    end
end
local function lower_down(x, y)
    state.pointer.active, state.pointer.downX, state.pointer.downY = true, x, y
    state.pointer.lastX, state.pointer.lastY = x, y
    state.pointer.startScroll, state.pointer.drag, state.pointer.scrubTarget = state.scroll, false, nil
    if point_in(state.progressRect, x, y) then
        state.pointer.scrubTarget = "progress"
        seek_fraction(slider_fraction(state.progressRect, x))
    elseif point_in(state.quickVolumeRect, x, y) then
        state.pointer.scrubTarget = "quick"
        set_master_volume(slider_fraction(state.quickVolumeRect, x))
    end
end
local function lower_move(x, y)
    if not state.pointer.active then return end
    state.pointer.lastX, state.pointer.lastY = x, y
    if math.abs(y - state.pointer.downY) > 12 or math.abs(x - state.pointer.downX) > 12 then state.pointer.drag = true end
    local target = state.pointer.scrubTarget
    if target == "progress" then seek_fraction(slider_fraction(state.progressRect, x))
    elseif target == "quick" then set_master_volume(slider_fraction(state.quickVolumeRect, x))
    elseif state.pointer.drag and state.pointer.downY >= 116 and state.pointer.downY <= 650 and state.pointer.downX <= 690 then
        local delta = math.floor((state.pointer.downY - y) / 62)
        state.scroll = clamp(state.pointer.startScroll + delta, 1, math.max(1, #state.tracks - VISIBLE_ROWS + 1))
    end
end
local function lower_up(x, y)
    if not state.pointer.active then return end
    state.pointer.lastX, state.pointer.lastY = x, y
    if not state.pointer.drag and not state.pointer.scrubTarget then handle_tap(x, y) end
    state.pointer.active, state.pointer.drag, state.pointer.scrubTarget = false, false, nil
end
local function native_touch_down(x, y)
    local origin = x >= LOWER_X and LOWER_X or 0
    state.touchOrigin = origin; lower_down(x - origin, y)
end
local function native_touch_move(x, y) if state.touchOrigin ~= nil then lower_move(x - state.touchOrigin, y) end end
local function native_touch_up(x, y)
    if state.touchOrigin == nil then return end
    lower_up(x - state.touchOrigin, y); state.touchOrigin = nil
end
local function install_gamepad_mapping()
    for _, joystick in ipairs(love.joystick.getJoysticks()) do
        if joystick:getName() == "ANBERNIC-rk3568-keys" then
            love.joystick.loadGamepadMappings(joystick:getGUID() ..
                ",ANBERNIC-rk3568-keys,a:b0,b:b1,x:b3,y:b2," ..
                "leftshoulder:b4,rightshoulder:b5,back:b6,start:b7,guide:b8," ..
                "lefttrigger:b10,righttrigger:b11,dpup:h0.1,dpdown:h0.4," ..
                "dpleft:h0.8,dpright:h0.2,leftx:a1,lefty:a2,platform:Linux,")
            print("[gamepad] mapped ANBERNIC-rk3568-keys")
        end
    end
end

local function init_evdev()
    state.touch = Touch.open(function(kind, x, y)
        state.evdevActive = true
        if kind == "down" then lower_down(x, y)
        elseif kind == "move" then lower_move(x, y)
        elseif kind == "up" then lower_up(x, y) end
    end, function() state.pointer.active, state.pointer.drag, state.pointer.scrubTarget = false, false, nil end)
    state.evdevActive = state.touch ~= nil
end
local function action_for(map, input)
    if not map then return nil end
    local value = map[input] or map[tostring(input)]
    if type(value) == "string" then return value end
    if type(value) == "table" then return value[1] end
    return nil
end

local function perform_action(action)
    if action == "play_pause" then toggle_play()
    elseif action == "previous" then next_track(-1)
    elseif action == "next" then next_track(1)
    elseif action == "volume_down" then adjust_master_volume(-0.05)
    elseif action == "volume_up" then adjust_master_volume(0.05)
    elseif action == "shuffle" then state.shuffle = not state.shuffle
    elseif action == "repeat_track" then state.repeatTrack = not state.repeatTrack
    elseif action == "scroll_up" then state.scroll = clamp(state.scroll - 1, 1, math.max(1, #state.tracks - VISIBLE_ROWS + 1))
    elseif action == "scroll_down" then state.scroll = clamp(state.scroll + 1, 1, math.max(1, #state.tracks - VISIBLE_ROWS + 1))
    elseif action == "select_previous" then select_track(state.selected - 1, false)
    elseif action == "select_next" then select_track(state.selected + 1, false)
    elseif action == "activate" then activate_selected()
    elseif action == "play_selected" then play_selected()
    elseif action == "favorite" then toggle_favorite()
    elseif action == "more" then
        if loading_active() then cancel_loading()
        elseif state.playbackState == "failed" then play_selected()
        else set_user_status("Y：当前没有可重试或取消的播放任务") end
    elseif action == "rescan" then
        if state.section == "local" then start_scan()
        elseif state.online.loggedIn then refresh_playlists()
        else state.online.started = false; set_section("local"); set_section("online") end
    elseif action == "toggle_section" then set_section(state.section == "local" and "online" or "local")
    elseif action == "section_local" then set_section("local")
    elseif action == "section_online" then set_section("online")
    elseif action == "back" then
        if loading_active() then cancel_loading()
        elseif state.section == "online" then online_back() end
    elseif action == "quit" then
        love.event.quit()
    end
end

local function keep_device_awake()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return end
    pcall(ffi.cdef, "int SDL_DisableScreenSaver(void);")
    if pcall(function() ffi.C.SDL_DisableScreenSaver() end) then return end
    for _, name in ipairs({"SDL2", "SDL2-2.0.so.0", "libSDL2-2.0.so.0"}) do
        local loaded, sdl = pcall(ffi.load, name)
        if loaded and pcall(function() sdl.SDL_DisableScreenSaver() end) then return end
    end
end

function love.load()
    math.randomseed(os.time())
    keep_device_awake()
    love.graphics.setDefaultFilter("linear", "linear", 4)
    local okIcon, iconData = pcall(love.image.newImageData, "assets/RG Music.png")
    if okIcon and iconData and love.window.setIcon then
        pcall(love.window.setIcon, iconData)
    end
    love.graphics.setBackgroundColor(C.bg)
    state.fontData = load_font_data()
    state.fonts.small, state.fonts.tiny = make_font(16), make_font(13)
    state.fonts.micro = make_font(11)
    state.fonts.footer = make_font(14)
    state.fonts.label, state.fonts.control = make_font(18), make_font(20)
    state.fonts.body, state.fonts.track = make_font(22), make_font(24)
    state.fonts.header, state.fonts.title = make_font(38), make_font(46)
    state.controls = require("controls")
    load_favorites()
    state.audioRoute = AudioRoute.open()
    load_settings()
    if state.audioRoute and state.audioRoute.set_output_change_callback then
        state.audioRoute:set_output_change_callback(function(inserted)
            store_current_volume()
            state.output = inserted and "headphone" or "speaker"
            state.masterVolume = volume_for_output(state.output)
            apply_source_volume()
            save_settings()
        end)
    end
    state.paths = music_paths(); state.tracks = {}
    state.localUI = {tracks = state.tracks, selected = 1, scroll = 1}
    local saveDir = love.filesystem.getSaveDirectory() or (app_root() .. "/saves")
    love.filesystem.createDirectory("netease")
    local dataDir = saveDir .. "/netease"
    local runtimeDir = love.system.getOS() == "Linux" and "/tmp/rgmusic-runtime" or (dataDir .. "/runtime")
    state.mpv = nil
    local mpvBinary = Mpv.detect(app_root())
    if mpvBinary then
        state.mpv = Mpv.new({binary = mpvBinary, socket = "/tmp/rgmusic-mpv.sock", pid_path = runtimeDir .. "/mpv.pid", log_path = "/dev/null"})
        state.mpv:stop()
    end
    log_line("session", "start version=" .. APP_VERSION .. "; mpv=" .. tostring(mpvBinary or "not-found"))
    state.online = {
        client = Netease.new({binary = netease_binary(), data_dir = dataDir, output_dir = runtimeDir}),
        artClient = Netease.new({binary = netease_binary(), data_dir = dataDir, output_dir = runtimeDir .. "/art"}),
        prefetchClient = Netease.new({binary = netease_binary(), data_dir = dataDir, output_dir = runtimeDir .. "/prefetch"}),
        lyricClient = Netease.new({binary = netease_binary(), data_dir = dataDir, output_dir = runtimeDir .. "/lyrics"}),
        urlCache = {}, unplayable = {}, artPending = nil, artSeen = {}, lyricPending = nil, lyricSeen = {}, prefetchPending = nil, prefetchInFlight = nil, prefetchWaitUntil = 0, prefetchWaitTrack = nil,
        view = "home", menu = {}, tracks = {}, selected = 1, scroll = 1,
        loggedIn = false, nickname = "", uid = 0, vipType = 0, redVipLevel = 0, vipLevel = 0, member = false, status = state.mpv and "在线直连播放已启用" or "未检测到 mpv，在线播放不可用",
        qrImage = nil, qrPath = "", loginState = "idle", loginMessage = "等待扫码", pollAt = 0,
        prepareID = nil, pendingTrack = nil, wantedGeneration = 0, progressAt = 0, started = false, requestStartedAt = 0, requestTrack = nil, requestStreaming = false, streamRetryCount = 0,
    }
    state.online.menu = {{kind = "action", action = "login", title = "扫码登录网易云", subtitle = "使用手机网易云音乐扫码"}}
    start_scan(); install_gamepad_mapping(); init_evdev(); love.window.setPosition(0, 0, 1)
end
function love.update(dt)
    state.time = state.time + dt
    if state.audioRoute then
        state.audioRoute:poll()
        sync_output_volume()
    end
    process_scan(0.008)
    if state.online and state.online.client then
        state.online.client:update()
        if state.online.prefetchInFlight and state.online.prefetchWaitUntil and state.online.prefetchWaitUntil > 0 and state.time >= state.online.prefetchWaitUntil then
            local waiting = state.online.prefetchWaitTrack
            state.online.prefetchClient:cancel()
            state.online.prefetchInFlight = nil
            state.online.prefetchPending = nil
            state.online.prefetchWaitUntil = 0
            state.online.prefetchWaitTrack = nil
            if waiting and state.online.pendingTrack and tostring(state.online.pendingTrack.id) == tostring(waiting.id) then
                prepare_online_track(waiting)
            end
        end
        if state.online.client:is_busy() and state.online.requestStartedAt and state.online.requestStartedAt > 0 and state.time - state.online.requestStartedAt > 10 then
            local pending = state.online.requestTrack or state.online.pendingTrack
            state.online.client:cancel()
            state.online.requestStartedAt = 0
            if pending then
                retry_stream_playback("获取播放地址超时")
            else
                state.online.status = "在线请求超时，请重试"
            end
        end
        if state.online.artClient then state.online.artClient:update() end
        if state.online.prefetchClient then state.online.prefetchClient:update() end
        if state.online.lyricClient then state.online.lyricClient:update() end
        if state.section == "online" and state.online.view == "login" and not state.online.client:is_busy() and state.time >= (state.online.pollAt or 0) then
            poll_login()
        end
    end
    if state.touch and not state.touch:poll(love.window.hasFocus()) then state.touch, state.evdevActive = nil, false end
    if state.streaming and state.mpv and state.mpv:is_active() and state.time >= state.mpvStatusAt then
        state.mpvStatusAt = state.time + 0.25
        if state.mpv:update_status() then
            local status = state.mpv:get_status()
            local currentPosition = tonumber(status.time)
            if currentPosition ~= nil then state.position = currentPosition end
            if tonumber(status.duration) and status.duration > 0 then state.duration = status.duration end

            local confirmedNow = status.loaded and currentPosition ~= nil and currentPosition > 0.15 and not status.buffering
            if (confirmedNow or status.eof) and not state.playbackConfirmed then
                state.playbackConfirmed = true
                state.audioReady = true
                state.mpvProgressAt = state.time
                state.mpvLastPosition = currentPosition or 0
            end
            if state.playbackConfirmed then state.playing = not status.paused else state.playing = false end

            if not status.eof then
                local title = state.nowPlaying and tostring(state.nowPlaying.title) or ""
                if not state.playbackConfirmed then set_playback_state(status.buffering and "buffering" or "starting", state.nowPlaying, title)
                elseif status.paused then set_playback_state("paused", state.nowPlaying, nil)
                else set_playback_state("playing", state.nowPlaying, nil) end
                if not state.playbackConfirmed then
                    if status.buffering then
                        state.online.status = "缓冲中：" .. title
                    else
                        state.online.status = "正在启动播放：" .. title
                    end
                elseif status.paused then
                    state.online.status = "已暂停：" .. title
                else
                    state.online.status = "正在播放：" .. title
                end
            end

            if status.eof and not state.mpvEofHandled then
                state.mpvEofHandled = true
                set_playback_state("idle", state.nowPlaying, nil)
                if state.time >= (state.advanceGuardUntil or 0) then
                    state.advanceGuardUntil = state.time + 2
                    if state.repeatTrack and state.nowPlaying then
                        load_source_for_track(state.nowPlaying)
                    else
                        if state.mpv then state.mpv:stop() end
                        state.streaming, state.playing, state.audioReady, state.playbackConfirmed = false, false, false, false
                        next_track(1)
                    end
                end
            elseif not status.eof then
                state.mpvEofHandled = false
            end

            local positionMoved = currentPosition ~= nil and math.abs(currentPosition - (state.mpvLastPosition or 0)) >= 0.05
            if state.playbackConfirmed and positionMoved and not status.paused then
                state.mpvLastPosition = currentPosition
                state.mpvProgressAt = state.time
            end

            if not status.eof and not state.playbackConfirmed and state.time - state.mpvStartedAt > 18 then
                retry_stream_playback("mpv 长时间没有开始播放")
            elseif state.playbackConfirmed and not status.paused and not positionMoved and state.time - (state.mpvProgressAt or state.time) > 15 then
                retry_stream_playback("播放进度长时间未变化")
            end
        elseif state.time - state.mpvStartedAt > 8 then
            log_line("mpv", "startup failed; tail=\n" .. log_tail(state.mpv and state.mpv.log_path or "", 4096))
            retry_stream_playback("mpv 启动失败")
        end
    end
    if state.online and state.online.requestStreaming and state.online.requestStartedAt and state.online.requestStartedAt > 0 and state.time - state.online.requestStartedAt > 10 then
        state.online.requestStartedAt = 0
        retry_stream_playback("获取播放地址超时")
    end
    if state.playing and state.source then
        state.position = state.position + dt
        if state.duration > 0 and state.position >= state.duration then
            if state.repeatTrack then
                state.position = 0; state.source:seek(0); state.source:play()
            elseif state.time >= (state.advanceGuardUntil or 0) then
                state.advanceGuardUntil = state.time + 2
                state.source:stop()
                state.playing, state.audioReady = false, false
                set_playback_state("idle", state.nowPlaying, nil)
                next_track(1)
            end
        end
    end
end
function love.draw()
    local scale = math.min(love.graphics.getWidth() / WINDOW_W, love.graphics.getHeight() / WINDOW_H)
    love.graphics.push(); love.graphics.scale(scale, scale)
    draw_upper()
    love.graphics.push(); love.graphics.translate(LOWER_X, 0); draw_lower(); love.graphics.pop()
    color(C.line, 0.92); love.graphics.rectangle("fill", LOWER_X - 2, 0, 4, WINDOW_H)
    love.graphics.pop()
end
function love.mousepressed(x, y, button, istouch)
    if istouch then return end
    local scale = math.min(love.graphics.getWidth() / WINDOW_W, love.graphics.getHeight() / WINDOW_H)
    x, y = x / scale, y / scale
    if button == 1 and x >= LOWER_X and not state.evdevActive then lower_down(x - LOWER_X, y) end
end
function love.mousemoved(x, y, dx, dy, istouch)
    if istouch then return end
    local scale = math.min(love.graphics.getWidth() / WINDOW_W, love.graphics.getHeight() / WINDOW_H)
    x, y = x / scale, y / scale
    if x >= LOWER_X and not state.evdevActive then lower_move(x - LOWER_X, y) end
end
function love.mousereleased(x, y, button, istouch)
    if istouch then return end
    local scale = math.min(love.graphics.getWidth() / WINDOW_W, love.graphics.getHeight() / WINDOW_H)
    x, y = x / scale, y / scale
    if button == 1 and x >= LOWER_X and not state.evdevActive then lower_up(x - LOWER_X, y) end
end
function love.wheelmoved(_, dy)
    if dy ~= 0 then state.scroll = clamp(state.scroll - dy, 1, math.max(1, #state.tracks - VISIBLE_ROWS + 1)) end
end
function love.touchpressed(id, x, y) if not state.evdevActive then native_touch_down(x, y) end end
function love.touchmoved(id, x, y) if not state.evdevActive then native_touch_move(x, y) end end
function love.touchreleased(id, x, y) if not state.evdevActive then native_touch_up(x, y) end end
function love.keypressed(key)
    perform_action(action_for(state.controls.keyboard, key))
end
function love.joystickpressed(joystick, button)
    if joystick and joystick.isGamepad and joystick:isGamepad() then return end
    perform_action(action_for(state.controls.joystick, button))
end
function love.gamepadpressed(joystick, button)
    perform_action(action_for(state.controls.gamepad, button))
end
function love.quit()
    save_settings()
    if state.audioRoute then state.audioRoute:close() end
    if state.touch then state.touch:close() end
    if state.online then
        for _, key in ipairs({"client", "artClient", "prefetchClient", "lyricClient"}) do
            local client = state.online[key]
            if client and client.cancel then client:cancel() end
        end
    end
    stop_source(); release_cover()
end
