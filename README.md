# RG Music

[简体中文](README.zh-CN.md) | English

RG Music is a lightweight dual-screen music player developed and tested **only on the Anbernic RGDS Plus**. Compatibility with other handhelds has not been verified.

## Compatibility

- Verified device: Anbernic RGDS Plus
- Other ARM64 Linux handhelds: unverified
- Do not assume that display order, input devices, audio sockets, suspend behavior, or launcher paths are identical on another device.

The upper screen shows cover art and synchronized lyrics. The lower screen provides the local library, online playlists, playback controls, progress, and volume controls.

## Features

- Local playback: MP3, OGG Vorbis, WAV
- NetEase Cloud Music QR login using the user's own account
- User playlists and daily recommendations
- Direct online playback through system `mpv`
- Embedded and external cover art
- UTF-8 LRC and embedded USLTP lyrics
- Touchscreen, gamepad, keyboard, and volume-slider input
- Shuffle, repeat-track, and playback-position persistence
- No runtime log files by default
- Account membership status display and re-login/account switching

The project is unofficial and is not affiliated with NetEase Cloud Music. It does not provide music content or bypass VIP, region, purchase, or copyright restrictions. Online playback depends on the account and on the service returning a playable URL.

## Installation

Download a release package and extract it into the `Roms` directory of the handheld's SD card. The final layout should be:

```text
Roms/APPS/RG Music.sh
Roms/APPS/RGMusic/app/main.lua
Roms/APPS/RGMusic/runtime/love.aarch64
Roms/APPS/RGMusic/app/bin/rgmusic-netease.aarch64
Roms/Imgs/RG Music.png
```

Online playback requires `mpv` on the device. Local playback does not.

See [INSTALL.txt](INSTALL.txt) for detailed Chinese installation instructions.

## Local music

Scanned directories:

```text
/mnt/sdcard/Music
/mnt/mmc/Music
Roms/APPS/RGMusic/music
```

Supported formats:

- MP3
- OGG Vorbis
- WAV
- Maximum file size: 32 MB

Cover lookup order:

1. Embedded MP3 cover
2. `cover.jpg` or `cover.png`
3. Image with the same base name as the track
4. `folder.jpg`, `front.jpg`, or `album.jpg`
5. Built-in placeholder

Lyrics lookup:

- UTF-8 LRC file with the same base name as the track
- Embedded USLT lyrics in MP3 files

## Controls

| Button | Action |
|---|---|
| A | Confirm, select, enter |
| X | Same as Start: play selected track, pause/resume, cancel loading |
| Start | Same as X: play selected track, pause/resume, cancel loading |
| D-pad up/down | Move selection |
| D-pad left/right | Volume down/up by 10% |
| L1 | Local library |
| R1 | NetEase Cloud Music |
| L2 | Previous track |
| R2 | Next track |
| B | Back; cancel loading |
| Y | Retry failed playback; cancel loading |
| Home | Exit |

## Building from source

Requirements:

- PowerShell 7+ or Windows PowerShell 5.1
- Go 1.25 or newer
- `tar.exe`
- `mpv` only at runtime on the target device

Build the backend and create an APPS package:

```powershell
.\tools\build_apps_package.ps1 -Version r0.76
```

The script automatically builds the ARM64 backend when it is missing.

The package is written to:

```text
dist/RGMusic-APPS-r0.76.zip
```

Build the full distribution archive, which also includes the installation guide and licenses:

```powershell
.\tools\build_distribution.ps1 -Version r0.76
```

Output:

```text
dist/RGMusic-r0.76-Distribution.zip
```

Development directories and generated files are excluded by `.gitignore`.

## Project layout

```text
assets/                         Public icons and launch documentation
docs/                           Architecture and maintenance notes
source/RGMusic/app/             LÖVE client source
source/RGMusic/runtime/         ARM64 runtime and libraries
source/RGMusicNetease/          Go NetEase sidecar source
tools/                          Build and icon-generation scripts
LICENSES/                       Third-party license texts
```

## Developer resources

- [RGDS Plus development notes](docs/RGDS_PLUS_DEVELOPMENT_NOTES.md)
- [AI reference guide for building other applications](docs/AI_ASSISTED_DEVELOPMENT.md)
- [Device quirks and practical fixes](docs/DEVICE_QUIRKS_AND_FIXES.md)
- [Architecture overview](docs/ARCHITECTURE.md)

These documents collect practical findings from the target device, including
display layout, input handling, mpv lifecycle, network behavior, packaging,
and AI-assisted debugging. Chinese versions use the `.zh-CN.md` suffix.

## Status

Current version: `r0.76`

The online API implementation can change or break when the upstream service changes. Contributions and compatibility fixes are welcome.

## License

RG Music source code is available under the MIT License. Third-party components retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).