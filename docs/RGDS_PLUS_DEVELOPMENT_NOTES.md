# RGDS Plus Development Notes

This document records practical observations from developing a native dual-screen application for the Anbernic RGDS Plus. Treat the exact paths, devices, and firmware behavior as a starting point, and always verify them on the target device.

## Target profile

- Architecture: `aarch64`
- Kernel line observed during development: Linux 6.1
- Primary display: `1024x768`
- Secondary display: `1024x768`
- Display server: Wayland
- Audio: PulseAudio
- Runtime used by RG Music: LÖVE 11.5 with LuaJIT
- Control input: SDL gamepad events plus Linux evdev input devices

## Application layout

The RG Music launcher follows the common APPS-style layout:

```text
Roms/APPS/Application Name.sh
Roms/APPS/ApplicationName/
Roms/Imgs/Application Name.png
```

The launcher should set all runtime paths itself instead of relying on the desktop shell environment. Important variables include:

```sh
XDG_RUNTIME_DIR=/var/run
WAYLAND_DISPLAY=wayland-0
SDL_VIDEODRIVER=wayland
SDL_AUDIODRIVER=pulse
PULSE_SERVER=unix:/tmp/pulse-socket
```

Use absolute paths based on the launcher location. Do not assume the current working directory is the application directory.

## Dual-screen rendering

One practical approach is to create a single logical canvas containing both displays. RG Music uses a `2048x768` logical window and scales it to the actual compositor surface:

```text
0..1023      upper display
1024..2047   lower display
```

Keep all layout coordinates in the fixed logical coordinate system, then apply one global scale at draw time. This makes screenshots, touch coordinates, and layout calculations much easier to reason about.

The physical screen order and orientation can differ between firmware versions. Verify both displays before hard-coding coordinate offsets.

## Input devices

Input devices should be discovered at runtime rather than assuming a fixed event number. Useful commands:

```sh
cat /proc/bus/input/devices
ls -l /dev/input/event*
ls -l /dev/input/by-path 2>/dev/null
```

RG Music uses SDL gamepad events for controller buttons and an evdev touch fallback for the lower screen. This is useful when the compositor or SDL does not report a touch event that the application needs.

Keep button mappings in a separate file so ports and custom builds can change them without editing the main application logic.

## Audio

Verify the active audio server and socket:

```sh
ps aux | grep pulseaudio
echo "$PULSE_SERVER"
pactl info 2>/dev/null
```

For `mpv`, test both PulseAudio and ALSA fallback:

```sh
mpv --no-video --ao=pulse,alsa --idle=yes --input-ipc-server=/tmp/test-mpv.sock URL
```

Use a per-playback socket and PID file. Do not reuse one socket across concurrent or rapidly changing playback sessions.

## Network reliability

Embedded Wi-Fi stacks can behave differently from desktop systems. Two useful checks are:

```sh
iw dev
iw dev wlan0 get power_save
nmcli device status
```

If long HTTP operations intermittently hang while SSH remains healthy, test IPv4-only and HTTP/1.1 transport settings in sidecar tools. This was useful for the Go NetEase helper used by RG Music.

If a network request can hang, give it a hard timeout and terminate the actual sidecar process on cancellation. Do not only stop reading its output file.

## Idle sleep and screen saver

A handheld may suspend or disconnect Wi-Fi after a period without physical input. Applications that play audio or maintain a network session should request that the screen saver/idle timeout be inhibited while active.

For LÖVE/SDL applications, `SDL_DisableScreenSaver()` can be called through LuaJIT FFI when the symbol is available. Test the actual device compositor because Wayland and X11 implement idle inhibition differently.

## mpv process lifecycle

Recommended rules learned from this project:

- Use a unique IPC socket and PID file for each playback.
- Stop and reap the old process before starting a new one.
- Do not declare "playing" until the media is loaded and the position advances.
- With `--idle=yes`, the properties `eof-reached`, `time-pos`, and `duration` may become unavailable at the end of a file.
- Query `idle-active` as an additional end-of-stream signal.

This avoids both overlapping audio and a player that appears to be "playing" while sitting in mpv's idle state.

## Storage discipline

Avoid writing logs or caches to the SD card unless there is a strong reason. Use `/tmp` for runtime sockets, PID files, progress files, and diagnostics. This reduces filesystem churn and makes it less likely that an unclean shutdown leaves the FAT32 card dirty.

Always safely eject removable media before removing it from the PC.

## Cross-compiling Go for the device

A small sidecar can be built on Windows or Linux with Go:

```powershell
$env:CGO_ENABLED = "0"
$env:GOOS = "linux"
$env:GOARCH = "arm64"
go build -trimpath -ldflags="-s -w" -o rgmusic-netease.aarch64 .
```

Use `CGO_ENABLED=0` unless the sidecar genuinely needs native libraries. A static sidecar is easier to deploy because it does not depend on the device's C library version.