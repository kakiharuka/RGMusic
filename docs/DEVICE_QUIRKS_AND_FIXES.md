# Device Quirks and Practical Fixes

This page records symptoms and fixes that were useful while porting RG Music to the RGDS Plus.

## Wi-Fi periodically stops responding

Symptoms:

- Online requests hang for tens of seconds.
- SSH to the device times out at the same time.
- The interface returns only after waiting or waking the device.

Checks:

```sh
iw dev wlan0 get power_save
nmcli device status
```

Fixes used during development:

```sh
iw dev wlan0 set power_save off
nmcli connection modify CONNECTION_NAME 802-11-wireless.powersave 2
```

Verify the interface after reconnecting. Do not blindly change another user's active connection without checking its name.

## The device suspends while an app is open

If the screen or Wi-Fi disappears after a period without physical input, request an idle inhibitor from the application. For SDL/LÖVE, try `SDL_DisableScreenSaver()` through FFI and verify the effect on the actual Wayland compositor.

## mpv finishes but the app does not advance

With `--idle=yes`, `eof-reached` may become unavailable when mpv enters idle mode. Query `idle-active` and treat it as an end-of-file condition. This was the fix for a player that stayed on "playing" after the audio had finished.

## The first track fails but later tracks work

This can be a process-cleanup race. If the cleanup logic waits on a generic PID file while the new process writes to the same file, it may kill the new process. Use unique per-play sockets/PIDs and do not clean a generic PID file after launching a new process.

## The app claims to be playing before audio starts

Track a separate confirmed-playback state. Set it only after `time-pos` advances or another reliable playback signal arrives. Show "loading" or "buffering" before that point.

## Online API hangs on an embedded network

Try HTTP/1.1 and IPv4 first, then add hard timeouts. If a helper process is cancelled, terminate it by PID; simply deleting its output file or callback does not stop the network request.

## A launcher path contains spaces

Use a wrapper script or shell quoting. Do not pass an unquoted path such as `Roms/APPS/My App.sh` through multiple shells. Verify that the launcher computes its own absolute directory.

## Touch input works only sometimes

SDL may not receive every touch event on a device running a compositor. Check `/proc/bus/input/devices` and implement an evdev fallback if necessary. Keep touch coordinates in the same logical coordinate system as the rendered canvas.

## The FAT32 card becomes read-only or dirty

- Avoid writing logs and runtime state to the card.
- Prefer `/tmp` for sockets, PID files, progress files, and transient data.
- Safely eject the card before removing it.
- If it becomes dirty, back up important data before repairing or reformatting.

## Packaging still contains local data

Use a release script that copies an explicit allowlist of files. Never package the whole working directory. Audit the archive for:

```text
saves/ cache/ logs/ cookies.json account.json *.mp3 *.flac *.m4a *.lrc
```