# Architecture

RG Music is split into two parts.

> Compatibility scope: this architecture was developed and tested only on RGDS Plus. It is not a claim that the same layout or runtime behavior applies to other handhelds.

## LÖVE client

The client lives in `source/RGMusic/app`.

- `main.lua` contains application state, UI rendering, playback orchestration, scanning, and input handling.
- `controls.lua` contains the button mapping.
- `library.lua` contains local-library scanning and metadata helpers.
- `netease.lua` manages the asynchronous Go sidecar process.
- `mpv.lua` manages the lifetime and IPC socket of the system `mpv` process.
- `touch_evdev.lua` reads the dual-screen touch device when SDL input is insufficient.

## Go sidecar

The sidecar lives in `source/RGMusicNetease`.

It handles NetEase login, account state, playlists, metadata, cover art, lyrics, and online URL resolution. The client communicates with it through temporary TSV files and ASCII command names. Cookie and cache data remain outside the source tree.

## Playback flow

1. The client asks the sidecar for a playable direct-stream URL.
2. The sidecar validates the URL and tries suitable CDN hosts.
3. The client starts `mpv` with an isolated IPC socket and PID file.
4. Status polling drives progress, buffering, EOF, and error recovery.
5. At EOF, idle state is treated as completion and the next track is selected.