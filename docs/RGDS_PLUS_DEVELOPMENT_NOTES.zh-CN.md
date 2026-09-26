# RGDS Plus 开发笔记

本文记录为 Anbernic RGDS Plus 开发原生双屏应用时得到的实际经验。具体路径、输入设备和固件行为应以目标设备实测为准。

> 兼容范围：下面的经验仅来自 RGDS Plus。它们不代表其他掌机模型具有相同的硬件、固件、输入设备、音频栈或启动器行为。

## 目标设备概况

- 架构：`aarch64`
- 开发时观察到的内核：Linux 6.1
- 主屏：`1024x768`
- 副屏：`1024x768`
- 显示服务：Wayland
- 音频：PulseAudio
- RG Music 使用的运行环境：LÖVE 11.5 + LuaJIT
- 控制输入：SDL 手柄事件 + Linux evdev

## APPS 目录结构

RG Music 使用常见掌机 APPS 目录结构：

```text
Roms/APPS/应用名称.sh
Roms/APPS/应用名称/
Roms/Imgs/应用名称.png
```

启动脚本应自行设置运行环境，不要依赖桌面 Shell：

```sh
XDG_RUNTIME_DIR=/var/run
WAYLAND_DISPLAY=wayland-0
SDL_VIDEODRIVER=wayland
SDL_AUDIODRIVER=pulse
PULSE_SERVER=unix:/tmp/pulse-socket
```

所有路径最好根据启动脚本所在目录自动计算，不要假设当前工作目录就是应用目录。

## 双屏绘制

一个实用方案是把两块屏幕当成一张逻辑画布。RG Music 使用 `2048x768`：

```text
0..1023      上屏
1024..2047   下屏
```

布局坐标全部使用固定的逻辑坐标系，绘制时统一缩放。这样处理触屏坐标、截图和窗口适配会简单很多。

不同固件的屏幕顺序和方向可能不同，必须先实机确认，再固定坐标偏移。

## 输入设备

不要假设固定的 `/dev/input/eventN` 编号，应在运行时发现设备：

```sh
cat /proc/bus/input/devices
ls -l /dev/input/event*
ls -l /dev/input/by-path 2>/dev/null
```

RG Music 使用 SDL 处理手柄按键，并在 SDL 无法完整上报下屏触摸时使用 evdev 备用方案。

按键映射最好单独放在一个文件里，方便其他项目或移植版本修改，不必动主程序。

## 音频

检查当前音频服务：

```sh
ps aux | grep pulseaudio
echo "$PULSE_SERVER"
pactl info 2>/dev/null
```

测试 mpv：

```sh
mpv --no-video --ao=pulse,alsa --idle=yes --input-ipc-server=/tmp/test-mpv.sock URL
```

每次播放使用独立的 socket 和 PID 文件，不要让快速切歌的多个播放进程共享同一个 socket。

## 网络

嵌入式 Wi-Fi 和桌面环境差异较大，常用检查命令：

```sh
iw dev
iw dev wlan0 get power_save
nmcli device status
```

如果 HTTP 请求偶尔长时间卡住，可以尝试只使用 IPv4 和 HTTP/1.1。RG Music 的 Go 网易云后端就使用了这个策略。

任何可能卡住的网络请求都要设置硬超时。取消请求时不仅要停止读输出，还要真正结束对应进程。

## 空闲休眠与屏幕保护

掌机在一段时间没有实体输入后可能休眠或断开 Wi-Fi。持续播放音频或保持网络连接的应用应主动请求禁止空闲休眠。

LÖVE/SDL 环境可以尝试通过 LuaJIT FFI 调用 `SDL_DisableScreenSaver()`，但必须在目标 Wayland 合成器上实测。

## mpv 生命周期

本项目总结出的规则：

- 每次播放使用独立的 IPC socket 和 PID 文件。
- 启动新播放器前，先停止并确认旧进程退出。
- 媒体真正加载并开始推进前，不要显示“正在播放”。
- 使用 `--idle=yes` 时，文件结束后 `eof-reached`、`time-pos`、`duration` 可能变成不可用。
- 同时查询 `idle-active`，把它作为播放结束信号。

这样可以避免音频重叠，也能避免播放器已经进入 idle，界面却仍显示“正在播放”。

## 存储

除非必要，不要把日志和缓存写到 SD 卡。socket、PID、进度和临时诊断文件应写入 `/tmp`。

拔卡前必须安全弹出。异常断电很容易让 FAT32 分区变脏，甚至临时变成只读。

## Go 后端交叉编译

```powershell
$env:CGO_ENABLED = "0"
$env:GOOS = "linux"
$env:GOARCH = "arm64"
go build -trimpath -ldflags="-s -w" -o rgmusic-netease.aarch64 .
```

除非确实需要本地库，否则保持 `CGO_ENABLED=0`。静态后端更容易部署，也不会受设备 C 库版本影响。