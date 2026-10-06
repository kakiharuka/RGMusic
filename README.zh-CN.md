# RG Music

[English](README.md) | 简体中文

RG Music 是专为 Anbernic RGDS Plus 开发的轻量双屏音乐播放器，**目前仅在 RGDS Plus 上实机开发和测试**。

## 兼容性说明

- 已验证设备：Anbernic RGDS Plus
- 其他 ARM64 Linux 掌机：未验证
- 不要假定其他设备的屏幕顺序、输入设备、音频 socket、休眠行为或 APPS 路径与本项目相同。

上屏用于显示专辑封面和同步歌词，下屏用于本地曲库、在线歌单、播放控制、进度和音量调节。

## 功能

- 本地播放：MP3、OGG Vorbis、WAV
- 使用用户自己的网易云账号扫码登录
- 浏览用户歌单和每日推荐
- 使用系统 `mpv` 直接在线播放
- 支持内嵌封面和外部封面
- 支持 UTF-8 LRC 和 MP3 内嵌 USLT 歌词
- 支持触屏、手柄、键盘和音量滑块
- 支持随机播放、单曲循环和播放位置恢复
- 默认不写运行日志
- 显示会员状态并支持退出当前账号重新登录

本项目是非官方客户端，与网易云音乐没有隶属或背书关系。软件不提供音乐内容，也不绕过 VIP、地区、购买或版权限制。在线播放是否成功取决于用户账号及服务端是否返回可播放地址。

## 安装

下载 Release 压缩包，解压到掌机 TF 卡的 `Roms` 目录。最终目录结构应为：

```text
Roms/APPS/RG Music.sh
Roms/APPS/RGMusic/app/main.lua
Roms/APPS/RGMusic/runtime/love.aarch64
Roms/APPS/RGMusic/app/bin/rgmusic-netease.aarch64
Roms/Imgs/RG Music.png
```

在线播放需要设备已安装 `mpv`，本地播放不需要。

详细安装步骤见 [INSTALL.txt](INSTALL.txt)。

## 本地音乐

扫描目录：

```text
/mnt/sdcard/Music
/mnt/mmc/Music
Roms/APPS/RGMusic/music
```

支持格式：

- MP3
- OGG Vorbis
- WAV
- 单个文件最大 32 MB

封面查找顺序：

1. MP3 内嵌封面
2. `cover.jpg` 或 `cover.png`
3. 与歌曲同名的图片
4. `folder.jpg`、`front.jpg` 或 `album.jpg`
5. 默认占位封面

歌词查找顺序：

- 与歌曲同名的 UTF-8 LRC 文件
- MP3 内嵌 USLT 歌词

## 按键

| 按键 | 功能 |
|---|---|
| A | 确认、选择、进入 |
| X | 与 X 完全一致：播放选中歌曲；暂停/继续；加载时取消 |
| Start | 与 X 完全一致：播放选中歌曲；暂停/继续；加载时取消 |
| 十字键上/下 | 移动列表选择 |
| 十字键左/右 | 音量减/加 10% |
| L1 | 切换到本地音乐 |
| R1 | 切换到网易云音乐 |
| L2 | 上一首 |
| R2 | 下一首 |
| B | 返回；加载时取消 |
| Y | 重试失败播放；加载时取消 |
| Home | 退出 |

## 从源码构建

需要：

- PowerShell 7+ 或 Windows PowerShell 5.1
- Go 1.25 或更新版本
- `tar.exe`
- 目标设备运行在线播放时需要 `mpv`

构建后端并生成 APPS 包：

```powershell
.\tools\build_apps_package.ps1 -Version r0.76
```

缺少 ARM64 后端时，脚本会自动编译。

输出目录：

```text
dist/RGMusic-APPS-r0.76.zip
```

生成包含安装说明和许可证的完整分发包：

```powershell
.\tools\build_distribution.ps1 -Version r0.76
```

输出：

```text
dist/RGMusic-r0.76-Distribution.zip
```

开发目录、构建产物、账号、缓存和日志默认由 `.gitignore` 排除。

## 项目结构

```text
assets/                         公共图标和启动说明
docs/                           架构与开发经验
source/RGMusic/app/             LÖVE 客户端源码
source/RGMusic/runtime/         ARM64 运行库
source/RGMusicNetease/          Go 网易云后端源码
tools/                          构建和图标生成脚本
LICENSES/                       第三方许可证
```

## 开发者文档

- [RGDS Plus 开发笔记](docs/RGDS_PLUS_DEVELOPMENT_NOTES.zh-CN.md)
- [借鉴本项目开发其他软件的 AI 指南](docs/AI_ASSISTED_DEVELOPMENT.zh-CN.md)
- [设备坑点与解决方法](docs/DEVICE_QUIRKS_AND_FIXES.zh-CN.md)
- [项目架构说明](docs/ARCHITECTURE.zh-CN.md)

英文版本保存在对应的无 `.zh-CN` 文件中。

## 版本状态

当前版本：`r0.76`

在线接口可能随服务端变化而失效，欢迎提交兼容性修复和功能改进。

## 许可证

RG Music 自有代码使用 MIT License。第三方组件继续使用各自许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。