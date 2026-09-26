# 项目架构

RG Music 分为客户端和 Go 后端两部分。

## LÖVE 客户端

源码位于 `source/RGMusic/app`。

- `main.lua`：应用状态、界面绘制、播放调度、音乐扫描和输入处理。
- `controls.lua`：按键映射。
- `library.lua`：本地音乐扫描和元数据辅助函数。
- `netease.lua`：管理异步 Go 后端进程。
- `mpv.lua`：管理系统 `mpv` 进程、IPC socket 和 PID。
- `touch_evdev.lua`：当 SDL 无法完整处理双屏触控时，通过 evdev 读取触摸事件。

## Go 后端

源码位于 `source/RGMusicNetease`。

后端负责网易云登录、账号状态、歌单、歌曲信息、封面、歌词和在线播放地址解析。客户端通过临时 TSV 文件和命令名与后端通信。Cookie 和缓存目录不进入源码仓库。

## 播放流程

1. 客户端向后端请求可播放的在线直链。
2. 后端验证直链，并尝试合适的 CDN 节点。
3. 客户端使用独立 IPC socket 和 PID 启动 `mpv`。
4. 状态轮询负责播放进度、缓冲、EOF 和错误恢复。
5. mpv 进入 idle 状态时视为播放结束，进入下一首。

## 发布结构

安装包遵循掌机 APPS 目录结构：

```text
APPS/应用名称.sh
APPS/应用目录/
Imgs/应用图标.png
```

发布脚本使用允许列表复制运行文件，并排除账号、Cookie、缓存、日志、音乐和测试文件。