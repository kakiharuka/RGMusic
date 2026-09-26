# 设备坑点与解决方法

本文记录将 RG Music 适配到 RGDS Plus 时遇到的实际问题。

> 这些经验仅来自实测的 RGDS Plus。其他掌机可能使用不同的输入设备、音频服务、休眠策略、网络栈或文件系统。所有修复都应先在目标设备上验证。

## Wi-Fi 偶尔完全没有响应

现象：

- 在线请求会卡住几十秒。
- 同时 SSH 也会超时。
- 等待或唤醒设备后才恢复。

检查：

```sh
iw dev wlan0 get power_save
nmcli device status
```

开发时使用的处理方式：

```sh
iw dev wlan0 set power_save off
nmcli connection modify 连接名称 802-11-wireless.powersave 2
```

修改后重新连接并验证。不要直接套用连接名称，应先确认当前实际连接。

## 应用运行时设备自动休眠

如果一段时间没有实体输入后屏幕或 Wi-Fi 消失，应用应主动申请禁止空闲休眠。

LÖVE/SDL 环境可以尝试通过 LuaJIT FFI 调用 `SDL_DisableScreenSaver()`，并在目标 Wayland 合成器中实测。

## mpv 播放结束但应用不切歌

使用 `--idle=yes` 时，文件结束后 `eof-reached` 可能变成不可用。此时需要查询 `idle-active`，将它视为播放结束信号。

这就是 RG Music 中“进度长时间未变化”问题的根因之一。

## 第一首歌失败，后面正常

这可能是进程清理竞态。如果新进程和旧进程共用 PID 文件，异步清理可能误杀新进程。

解决方法：

- 每次播放使用独立的 socket 和 PID。
- 不要在新进程启动后再清理通用 PID 文件。
- 启动新播放器前，先确认旧进程退出。

## 界面已经显示“正在播放”，但声音还没开始

单独维护“播放已确认”状态。只有 `time-pos` 真正推进后才显示“正在播放”，之前显示“正在加载”或“缓冲中”。

## 嵌入式网络下接口偶尔挂起

可以优先测试：

- 强制 IPv4。
- 使用 HTTP/1.1。
- 设置硬超时。
- 取消请求时按 PID 结束整个后端进程。

只删除输出文件或清空回调并不会结束网络请求。

## 启动脚本路径包含空格

不要通过多层 Shell 传递未加引号的 `Roms/APPS/My App.sh`。建议使用固定位置的包装脚本，或确保每一层都正确引用路径。

## 触摸只有时有效

Wayland 合成器可能无法通过 SDL 上报全部触摸事件。可以检查 `/proc/bus/input/devices`，并增加 evdev 备用读取逻辑。触摸坐标应与逻辑画布使用同一坐标系。

## FAT32 卡变成只读或 Dirty

- 不要频繁向 TF 卡写日志。
- socket、PID、进度和临时文件放 `/tmp`。
- 拔卡前安全弹出。
- 卡变脏后先备份，再修复或格式化。

## 发布包仍包含本机数据

发布脚本必须使用明确的允许列表，不能直接打包整个工作目录。至少检查：

```text
saves/ cache/ logs/ cookies.json account.json *.mp3 *.flac *.m4a *.lrc
```