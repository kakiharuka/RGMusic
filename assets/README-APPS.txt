RG Music - APPS 安装说明

把压缩包解压到 TF 卡的 Roms 目录。合并后应当是这样：

Roms/APPS/RG Music.sh
Roms/APPS/RGMusic/app/main.lua
Roms/APPS/RGMusic/runtime/love.aarch64
Roms/APPS/RGMusic/app/bin/rgmusic-netease.aarch64
Roms/Imgs/RG Music.png

网易云功能：
- 在掌机“网易云”页面选择“扫码登录网易云”。
- 使用手机网易云音乐扫描二维码并确认。
- 登录后可浏览账号歌单和每日推荐。
- 检测到 mpv 时，在线歌曲使用 HTTP 流式播放，播放过程中持续缓冲。
- 必须安装 mpv；未检测到 mpv 时无法在线播放。
- 便携 mpv 可放到 Roms/APPS/RGMusic/app/bin/mpv.aarch64，也可以使用系统自带 mpv。
- 为减少 TF 卡写入，当前版本不写日志文件。
- 不提供灰色歌曲解锁，不绕过会员或版权限制。

按键：
- A：只确认/选择，或进入选中的歌单。
- X：收藏/取消收藏当前选中歌曲。
- Start：播放选中歌曲；暂停/继续当前歌曲。
- B：返回；加载时取消。
- 十字键上 / 下：移动列表选择，不会自动播放。
- 十字键左 / 右：调整音量 10%。
- L1：切换到本地音乐。
- R1：切换到网易云音乐。
- L2 / R2：上一首 / 下一首。
- Y：重试失败播放；加载时取消。
- Home：退出。

音乐目录：
/mnt/sdcard/Music
/mnt/mmc/Music
Roms/APPS/RGMusic/music
